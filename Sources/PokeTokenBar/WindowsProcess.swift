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
    init?(commandLine: String, stdoutPath: String, stderrPath: String) {
        // The in-place updater is a detached .cmd file that eventually executes a downloaded Setup.exe.
        // Validate the Authenticode signer *before* we let cmd.exe start. This is deliberately fail-closed:
        // until WindowsUpdate.trustedInstallerSignerThumbprint is configured, auto-update falls back to
        // the browser rather than silently executing bytes supplied by a GitHub release.
        if let updaterScript = Self.updaterScriptPath(in: commandLine) {
            guard Self.updaterScriptHasTrustedInstaller(updaterScript) else {
                AppLog.write("blocked unattended update: installer signature is missing or untrusted")
                return nil
            }
        }

        var sa = SECURITY_ATTRIBUTES()
        sa.nLength = DWORD(MemoryLayout<SECURITY_ATTRIBUTES>.size)
        sa.bInheritHandle = true

        guard let out = Self.createFile(stdoutPath, sa: &sa),
              let err = Self.createFile(stderrPath, sa: &sa) else { return nil }
        defer { CloseHandle(out); CloseHandle(err) }

        var readEnd: HANDLE?
        var writeEnd: HANDLE?
        guard CreatePipe(&readEnd, &writeEnd, &sa, 0), let readEnd, let writeEnd else { return nil }
        SetHandleInformation(writeEnd, DWORD(HANDLE_FLAG_INHERIT), 0)   // parent's write end: not inherited
        defer { CloseHandle(readEnd) }

        var si = STARTUPINFOW()
        si.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
        si.dwFlags = DWORD(STARTF_USESTDHANDLES)
        si.hStdInput = readEnd
        si.hStdOutput = out
        si.hStdError = err

        var cmd = Array(commandLine.utf16) + [0]
        let ok = cmd.withUnsafeMutableBufferPointer { buf in
            CreateProcessW(nil, buf.baseAddress, nil, nil, true,
                           DWORD(CREATE_NO_WINDOW), nil, nil, &si, &pi)
        }
        guard ok else { CloseHandle(writeEnd); return nil }
        hStdinWrite = writeEnd
        launched = true
    }

    func writeStdin(_ data: Data) {
        guard let h = hStdinWrite else { return }
        var written: DWORD = 0
        _ = data.withUnsafeBytes { WriteFile(h, $0.baseAddress, DWORD($0.count), &written, nil) }
    }

    func closeStdin() {
        if let h = hStdinWrite { CloseHandle(h); hStdinWrite = nil }
    }

    var isRunning: Bool {
        var code: DWORD = 0
        guard GetExitCodeProcess(pi.hProcess, &code) else { return false }
        return code == 259   // STILL_ACTIVE
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
        if pi.hProcess != nil { CloseHandle(pi.hProcess) }
        if pi.hThread != nil { CloseHandle(pi.hThread) }
    }

    /// Extract only our own detached updater script from a command line. Other `.cmd` processes (for
    /// example npm-installed codex.cmd) are intentionally unaffected by the signature gate.
    static func updaterScriptPath(in commandLine: String) -> String? {
        let pattern = #"(?i)\"([^\"]*ptb-apply-[0-9]+\.cmd)\""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: commandLine, range: NSRange(commandLine.startIndex..., in: commandLine)),
              let range = Range(match.range(at: 1), in: commandLine) else { return nil }
        return String(commandLine[range])
    }

    private static func updaterScriptHasTrustedInstaller(_ scriptPath: String) -> Bool {
        guard let script = try? String(contentsOfFile: scriptPath, encoding: .utf8), script.count <= 32_768 else {
            return false
        }
        guard let installLine = script.split(whereSeparator: \.isNewline)
            .map(String.init)
            .first(where: { $0.contains("/VERYSILENT") }),
              installLine.first == "\"" else { return false }
        let afterOpenQuote = installLine.dropFirst()
        guard let closeQuote = afterOpenQuote.firstIndex(of: "\"") else { return false }
        let installerPath = String(afterOpenQuote[..<closeQuote])
        guard installerPath.lowercased().hasSuffix(".exe") else { return false }

        // The app itself writes updates under the user's temp directory. Constrain verification to
        // that location so this special path cannot become a generic signed-binary launcher.
        let tempPrefix = FileManager.default.temporaryDirectory.standardizedFileURL.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "\\/"))
            .lowercased()
        let candidate = URL(fileURLWithPath: installerPath).standardizedFileURL.path.lowercased()
        guard candidate.hasPrefix(tempPrefix + "\\") || candidate.hasPrefix(tempPrefix + "/") else { return false }
        return isTrustedAuthenticodeFile(installerPath)
    }

    /// Ask the OS Authenticode provider for the signer and require both a valid chain/signature and
    /// the certificate thumbprint baked into the app. The PowerShell executable is addressed by its
    /// absolute System32 path and passed as lpApplicationName, avoiding PATH/executable hijacking.
    private static func isTrustedAuthenticodeFile(_ path: String) -> Bool {
        let expected = WindowsUpdate.trustedInstallerSignerThumbprint
            .replacingOccurrences(of: " ", with: "")
            .uppercased()
        guard expected.range(of: #"^[0-9A-F]{40}$"#, options: .regularExpression) != nil else {
            return false
        }

        var sysDir = [WCHAR](repeating: 0, count: 32_768)
        let n: UINT = sysDir.withUnsafeMutableBufferPointer { buffer in
            GetSystemDirectoryW(buffer.baseAddress, UINT(buffer.count))
        }
        guard n > 0, Int(n) < sysDir.count else { return false }
        let system32 = String(decoding: sysDir.prefix(Int(n)), as: UTF16.self)
        let powershell = system32 + "\\WindowsPowerShell\\v1.0\\powershell.exe"
        guard FileManager.default.fileExists(atPath: powershell) else { return false }

        let escapedPath = path.replacingOccurrences(of: "'", with: "''")
        let ps = "$s=Get-AuthenticodeSignature -LiteralPath '\(escapedPath)'; "
            + "if ($s.Status -eq 'Valid' -and $null -ne $s.SignerCertificate -and "
            + "$s.SignerCertificate.Thumbprint.ToUpperInvariant() -eq '\(expected)') { exit 0 } else { exit 1 }"
        let commandLine = "\"\(powershell)\" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command \"\(ps)\""

        var app = Array(powershell.utf16) + [0]
        var cmd = Array(commandLine.utf16) + [0]
        var si = STARTUPINFOW()
        si.cb = DWORD(MemoryLayout<STARTUPINFOW>.size)
        var processInfo = PROCESS_INFORMATION()
        let launched = app.withUnsafeMutableBufferPointer { appBuf in
            cmd.withUnsafeMutableBufferPointer { cmdBuf in
                CreateProcessW(appBuf.baseAddress, cmdBuf.baseAddress, nil, nil, false,
                               DWORD(CREATE_NO_WINDOW), nil, nil, &si, &processInfo)
            }
        }
        guard launched else { return false }
        defer {
            if processInfo.hProcess != nil { CloseHandle(processInfo.hProcess) }
            if processInfo.hThread != nil { CloseHandle(processInfo.hThread) }
        }
        guard WaitForSingleObject(processInfo.hProcess, 15_000) == WAIT_OBJECT_0 else {
            _ = TerminateProcess(processInfo.hProcess, 1)
            return false
        }
        var code: DWORD = 1
        return GetExitCodeProcess(processInfo.hProcess, &code) && code == 0
    }

    private static func createFile(_ path: String, sa: inout SECURITY_ATTRIBUTES) -> HANDLE? {
        var wpath = Array(path.utf16) + [0]
        let h = wpath.withUnsafeBufferPointer {
            CreateFileW($0.baseAddress, DWORD(GENERIC_WRITE),
                        DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE), &sa,
                        DWORD(CREATE_ALWAYS), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
        }
        if h == INVALID_HANDLE_VALUE { return nil }
        return h
    }
}
#endif
