#if os(Windows)
import Foundation
import WinSDK

/// `wsl.exe` does not reliably start when it is itself created with
/// `PROC_THREAD_ATTRIBUTE_HANDLE_LIST`. The main process keeps that strict inheritance policy for
/// every ordinary child. WSL control queries take one extra hop instead: the main process starts a
/// second PokeTokenBar process through `WindowsProcess.capture`, so the helper inherits only its
/// three stdio handles; the helper then starts the trusted System32 `wsl.exe` with ordinary stdio
/// inheritance. This gives WSL the CreateProcess shape it expects without making arbitrary app
/// handles inheritable from the long-lived tray process.
enum WSLProcessProxy {
    static let flag = "--internal-wsl-proxy"

    static func capture(arguments: [String], timeout: Double = 20,
                        maxOutputBytes: Int = 64 * 1024) -> WindowsProcess.CaptureResult {
        guard allowed(arguments: arguments), let executable = currentExecutablePath() else {
            return WindowsProcess.CaptureResult(stdout: Data(), exitCode: nil,
                                                failure: .launch, processStopped: true)
        }
        return WindowsProcess.capture(executable: executable,
                                      arguments: [flag] + arguments,
                                      timeout: timeout,
                                      maxOutputBytes: maxOutputBytes)
    }

    /// Run only the two fixed control queries used by `WSLUsage`. Keeping this allowlist narrow
    /// prevents the hidden helper flag from becoming a general-purpose WSL command launcher.
    static func allowed(arguments: [String]) -> Bool {
        if arguments == ["--list", "--quiet"] { return true }
        guard arguments.count == 5,
              arguments[0] == "--distribution",
              WSLUsage.isSafeDistributionName(arguments[1]),
              arguments[2] == "--exec",
              arguments[3] == "/usr/bin/printenv",
              arguments[4] == "HOME" else { return false }
        return true
    }

    /// Entry point used by the short-lived helper process. stdout/stderr are the bounded pipes
    /// inherited from its parent `WindowsProcess.capture` call and are forwarded directly to WSL.
    static func run(arguments: [String]) -> Int32 {
        guard allowed(arguments: arguments),
              let executable = WindowsProcess.systemExecutable("wsl.exe") else { return 2 }

        let commandLine = ([executable] + arguments).map(WindowsProcess.quoteArgument).joined(separator: " ")
        var command = Array(commandLine.utf16) + [0]
        let application = Array(executable.utf16) + [0]

        var startup = STARTUPINFOW()
        startup.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
        startup.dwFlags = DWORD(STARTF_USESTDHANDLES)
        startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE)
        startup.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE)
        startup.hStdError = GetStdHandle(STD_ERROR_HANDLE)

        guard valid(startup.hStdInput), valid(startup.hStdOutput), valid(startup.hStdError) else { return 3 }

        var child = PROCESS_INFORMATION()
        let started = application.withUnsafeBufferPointer { app in
            command.withUnsafeMutableBufferPointer { cmd in
                CreateProcessW(app.baseAddress, cmd.baseAddress, nil, nil, true,
                               DWORD(CREATE_NO_WINDOW), nil, nil, &startup, &child)
            }
        }
        guard started else { return 4 }
        defer {
            if child.hThread != nil { CloseHandle(child.hThread) }
            if child.hProcess != nil { CloseHandle(child.hProcess) }
        }

        guard WaitForSingleObject(child.hProcess, INFINITE) == WAIT_OBJECT_0 else { return 5 }
        var code: DWORD = 0
        guard GetExitCodeProcess(child.hProcess, &code) else { return 6 }
        return Int32(bitPattern: code)
    }

    private static func currentExecutablePath() -> String? {
        var buffer = [WCHAR](repeating: 0, count: 32768)
        let count = buffer.withUnsafeMutableBufferPointer {
            GetModuleFileNameW(nil, $0.baseAddress, DWORD($0.count))
        }
        guard count > 0, Int(count) < buffer.count else { return nil }
        return String(decoding: buffer.prefix(Int(count)), as: UTF16.self)
    }

    private static func valid(_ handle: HANDLE?) -> Bool {
        guard let handle else { return false }
        return handle != INVALID_HANDLE_VALUE
    }
}
#endif
