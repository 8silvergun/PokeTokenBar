#if os(Windows)
import Foundation
import WinSDK

/// Spawn a child process with **no console window** (`CREATE_NO_WINDOW`), stdio redirected to
/// files + a stdin pipe. `Foundation.Process` pops a console for console-subsystem children
/// (`codex.cmd`, `where.exe`) — that flashes a terminal AND steals focus, which dismissed the
/// popover. This Win32 spawn avoids the window entirely.
final class WindowsProcess {
    private var pi = PROCESS_INFORMATION()
    private var hStdinWrite: HANDLE?
    private(set) var launched = false

    /// `commandLine`: full command line (already quoted). stdout/stderr are created/truncated at the
    /// given paths; a stdin pipe is opened for `writeStdin`. Child inherits the parent environment.
    init?(commandLine: String, stdoutPath: String, stderrPath: String, createNewOutputFiles: Bool = false) {
        var sa = SECURITY_ATTRIBUTES()
        sa.nLength = DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size)
        sa.bInheritHandle = true

        guard let out = Self.createFile(stdoutPath, sa: &sa, createNew: createNewOutputFiles) else { return nil }
        defer { CloseHandle(out) }
        guard let err = Self.createFile(stderrPath, sa: &sa, createNew: createNewOutputFiles) else { return nil }
        defer { CloseHandle(err) }

        var readEnd: HANDLE?
        var writeEnd: HANDLE?
        guard CreatePipe(&readEnd, &writeEnd, &sa, 0), let readEnd, let writeEnd else { return nil }
        defer { CloseHandle(readEnd) }
        guard SetHandleInformation(writeEnd, DWORD(HANDLE_FLAG_INHERIT), 0),
              let child = Self.spawn(commandLine: commandLine, input: readEnd, output: out, error: err)
        else { CloseHandle(writeEnd); return nil }
        pi = child
        hStdinWrite = writeEnd
        launched = true
    }

    private init(child: PROCESS_INFORMATION) {
        pi = child
        launched = true
    }

    deinit { cleanup() }

    func writeStdin(_ data: Data) {
        guard let h = hStdinWrite else { return }
        var written: DWORD = 0
        _ = data.withUnsafeBytes { WriteFile(h, $0.baseAddress, DWORD($0.count), &written, nil) }
    }

    func closeStdin() {
        if let h = hStdinWrite { CloseHandle(h); hStdinWrite = nil }
    }

    var isRunning: Bool {
        WaitForSingleObject(pi.hProcess, 0) == WAIT_TIMEOUT
    }

    var exitCode: Int32 {
        var code: DWORD = 0
        _ = GetExitCodeProcess(pi.hProcess, &code)
        return Int32(bitPattern: code)
    }

    func terminate() { _ = TerminateProcess(pi.hProcess, 1) }

    /// Wait up to `seconds` for exit; returns true if it exited.
    func waitFor(_ seconds: Double) -> Bool {
        WaitForSingleObject(pi.hProcess, DWORD(seconds * 1000)) == WAIT_OBJECT_0
    }

    func cleanup() {
        closeStdin()
        if pi.hProcess != nil { CloseHandle(pi.hProcess); pi.hProcess = nil }
        if pi.hThread != nil { CloseHandle(pi.hThread); pi.hThread = nil }
    }

    enum CaptureFailure: Equatable { case launch, read, timeout, outputLimit }
    struct CaptureResult {
        let stdout: Data
        let exitCode: Int32?
        let failure: CaptureFailure?
        /// Refers to the Windows client, not processes inside a WSL distribution.
        let processStopped: Bool
    }

    /// Small control queries use anonymous pipes, not named temporary files. Both
    /// streams count toward the cap; neither a noisy stderr nor a blocked child can
    /// make capture grow/wait indefinitely. Partial output is never returned on failure.
    static func capture(executable: String, arguments: [String], timeout: Double = 8,
                        maxOutputBytes: Int = 64 * 1024) -> CaptureResult {
        func failed(_ reason: CaptureFailure, stopped: Bool = true) -> CaptureResult {
            CaptureResult(stdout: Data(), exitCode: nil, failure: reason, processStopped: stopped)
        }
        guard timeout.isFinite, timeout > 0, timeout <= 60,
              maxOutputBytes > 0, maxOutputBytes <= 1024 * 1024,
              !executable.contains("\0"), !arguments.contains(where: { $0.contains("\0") }),
              let input = CapturePipe(parentReads: false),
              let output = CapturePipe(parentReads: true),
              let error = CapturePipe(parentReads: true) else { return failed(.launch) }
        let command = ([executable] + arguments).map(quoteArgument).joined(separator: " ")
        guard let child = spawn(commandLine: command, applicationPath: executable,
                                input: input.read!, output: output.write!, error: error.write!)
        else { return failed(.launch) }
        let process = WindowsProcess(child: child)
        input.closeRead(); input.closeWrite()  // immediate EOF on stdin
        output.closeWrite(); error.closeWrite()
        defer { process.cleanup() }
        let started = GetTickCount64()
        let limitMilliseconds = UInt64(timeout * 1000)
        var stdout = Data()
        var totalBytes = 0

        func stop(_ reason: CaptureFailure) -> CaptureResult {
            process.terminate()
            return failed(reason, stopped: process.waitFor(1))
        }

        while true {
            if GetTickCount64() - started >= limitMilliseconds { return stop(.timeout) }
            var received = false
            for (pipe, retain) in [(output, true), (error, false)] {
                var available: DWORD = 0
                guard PeekNamedPipe(pipe.read, nil, 0, nil, &available, nil) else {
                    if GetLastError() == DWORD(ERROR_BROKEN_PIPE) { continue }
                    return stop(.read)
                }
                guard available > 0 else { continue }
                let count = min(Int(available), 8192, maxOutputBytes - totalBytes + 1)
                var buffer = [UInt8](repeating: 0, count: count)
                var read: DWORD = 0
                let ok = buffer.withUnsafeMutableBytes {
                    ReadFile(pipe.read, $0.baseAddress, DWORD(count), &read, nil)
                }
                guard ok, read > 0 else { return stop(.read) }
                totalBytes += Int(read)
                if totalBytes > maxOutputBytes { return stop(.outputLimit) }
                if retain { stdout.append(contentsOf: buffer.prefix(Int(read))) }
                received = true
            }
            if !process.isRunning && !received {
                return CaptureResult(stdout: stdout, exitCode: process.exitCode,
                                     failure: nil, processStopped: true)
            }
            if !received { _ = process.waitFor(0.01) }
        }
    }

    /// Resolve system tools without trusting PATH or a caller-supplied SystemRoot.
    static func systemExecutable(_ name: String) -> String? {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), !name.contains(":"),
              !name.contains("\0") else { return nil }
        var buffer = [WCHAR](repeating: 0, count: 32768)
        let count = buffer.withUnsafeMutableBufferPointer { GetSystemDirectoryW($0.baseAddress, UINT($0.count)) }
        guard count > 0, Int(count) < buffer.count else { return nil }
        return String(decoding: buffer.prefix(Int(count)), as: UTF16.self) + "\\" + name
    }

    /// Explicitly inherit only stdio, including for legacy file-backed callers. This
    /// prevents a concurrent spawn from inheriting another query's pipe/file handles.
    private static func spawn(commandLine: String, applicationPath: String? = nil,
                              input: HANDLE, output: HANDLE, error: HANDLE) -> PROCESS_INFORMATION? {
        var size: SIZE_T = 0
        _ = InitializeProcThreadAttributeList(nil, 1, 0, &size)
        guard size > 0 else { return nil }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { storage.deallocate() }
        let attributes = OpaquePointer(storage)
        guard InitializeProcThreadAttributeList(attributes, 1, 0, &size) else { return nil }
        var handles: [HANDLE?] = [input, output, error]
        return handles.withUnsafeMutableBytes { handleBytes in
            defer { DeleteProcThreadAttributeList(attributes) }
            // WinSDK's function-like ProcThreadAttributeValue macro is unavailable
            // in Swift: HandleList (2) | PROC_THREAD_ATTRIBUTE_INPUT (0x00020000).
            let handleListAttribute = DWORD_PTR(0x00020002)
            guard UpdateProcThreadAttribute(attributes, 0, handleListAttribute,
                                            handleBytes.baseAddress, SIZE_T(handleBytes.count), nil, nil)
            else { return nil }
            var si = STARTUPINFOEXW()
            si.StartupInfo.cb = DWORD(MemoryLayout<STARTUPINFOEXW>.size)
            si.StartupInfo.dwFlags = DWORD(STARTF_USESTDHANDLES)
            si.StartupInfo.hStdInput = input
            si.StartupInfo.hStdOutput = output
            si.StartupInfo.hStdError = error
            si.lpAttributeList = attributes
            var child = PROCESS_INFORMATION()
            var command = Array(commandLine.utf16) + [0]
            let application = applicationPath.map { Array($0.utf16) + [0] } ?? []
            let ok = application.withUnsafeBufferPointer { app in
                command.withUnsafeMutableBufferPointer { cmd in
                    CreateProcessW(application.isEmpty ? nil : app.baseAddress, cmd.baseAddress,
                                   nil, nil, true, DWORD(CREATE_NO_WINDOW | EXTENDED_STARTUPINFO_PRESENT),
                                   nil, nil, &si.StartupInfo, &child)
                }
            }
            return ok ? child : nil
        }
    }

    private final class CapturePipe {
        var read: HANDLE?
        var write: HANDLE?
        init?(parentReads: Bool) {
            var sa = SECURITY_ATTRIBUTES()
            sa.nLength = DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size)
            sa.bInheritHandle = true
            guard CreatePipe(&read, &write, &sa, 0) else { return nil }
            guard SetHandleInformation(parentReads ? read : write, DWORD(HANDLE_FLAG_INHERIT), 0)
            else { closeRead(); closeWrite(); return nil }
        }
        func closeRead() { if let read { CloseHandle(read); self.read = nil } }
        func closeWrite() { if let write { CloseHandle(write); self.write = nil } }
        deinit { closeRead(); closeWrite() }
    }

    /// Windows argv quoting (not shell escaping). `capture` invokes an explicit exe.
    static func quoteArgument(_ value: String) -> String {
        var escaped = ""
        var backslashes = 0
        for character in value {
            if character == "\\" {
                backslashes += 1
            } else if character == "\"" {
                escaped += String(repeating: "\\", count: backslashes * 2 + 1)
                escaped.append("\"")
                backslashes = 0
            } else {
                escaped += String(repeating: "\\", count: backslashes)
                backslashes = 0
                escaped.append(character)
            }
        }
        escaped += String(repeating: "\\", count: backslashes * 2)
        return "\"\(escaped)\""
    }

    private static func createFile(_ path: String, sa: inout SECURITY_ATTRIBUTES, createNew: Bool) -> HANDLE? {
        var wpath = Array(path.utf16) + [0]
        let disposition = createNew ? DWORD(CREATE_NEW) : DWORD(CREATE_ALWAYS)
        let h = wpath.withUnsafeBufferPointer {
            CreateFileW($0.baseAddress, DWORD(GENERIC_WRITE),
                        DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE), &sa,
                        disposition, DWORD(FILE_ATTRIBUTE_NORMAL), nil)
        }
        if h == INVALID_HANDLE_VALUE { return nil }
        return h
    }
}
#endif
