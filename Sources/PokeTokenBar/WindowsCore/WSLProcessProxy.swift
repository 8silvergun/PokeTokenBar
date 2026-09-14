#if os(Windows)
import Foundation

/// `wsl.exe` does not reliably start when it is itself created with
/// `PROC_THREAD_ATTRIBUTE_HANDLE_LIST`. Keep that strict inheritance policy in the long-lived tray
/// process, but add one short-lived trusted hop: PokeTokenBar starts Windows PowerShell through the
/// hardened `WindowsProcess.capture`; PowerShell then launches the fixed System32 `wsl.exe` with
/// ordinary process inheritance. The helper receives only the bounded stdio pipes from the parent,
/// so this restores WSL compatibility without weakening normal child-process spawning.
enum WSLProcessProxy {
    static func capture(arguments: [String], timeout: Double = 20,
                        maxOutputBytes: Int = 64 * 1024) -> WindowsProcess.CaptureResult {
        guard allowed(arguments: arguments),
              let wsl = WindowsProcess.systemExecutable("wsl.exe"),
              let powerShellDirectory = WindowsProcess.systemExecutable("WindowsPowerShell") else {
            return WindowsProcess.CaptureResult(stdout: Data(), exitCode: nil,
                                                failure: .launch, processStopped: true)
        }

        let powerShell = powerShellDirectory + "\\v1.0\\powershell.exe"
        let script = proxyScript(wsl: wsl, arguments: arguments)
        guard let encoded = script.data(using: .utf16LittleEndian)?.base64EncodedString() else {
            return WindowsProcess.CaptureResult(stdout: Data(), exitCode: nil,
                                                failure: .launch, processStopped: true)
        }

        return WindowsProcess.capture(
            executable: powerShell,
            arguments: ["-NoLogo", "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded],
            timeout: timeout,
            maxOutputBytes: maxOutputBytes)
    }

    /// Run only the two fixed control queries used by `WSLUsage`. Keeping the allowlist narrow
    /// prevents this compatibility path from becoming a general-purpose shell bridge.
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

    private static func proxyScript(wsl: String, arguments: [String]) -> String {
        let prefix = """
        $ErrorActionPreference = 'Stop'
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $OutputEncoding = [Console]::OutputEncoding
        $wsl = \(psLiteral(wsl))
        """

        if arguments == ["--list", "--quiet"] {
            return prefix + "\n& $wsl --list --quiet\nexit $LASTEXITCODE\n"
        }

        let distribution = psLiteral(arguments[1])
        return prefix + "\n& $wsl --distribution \(distribution) --exec /usr/bin/printenv HOME\nexit $LASTEXITCODE\n"
    }

    private static func psLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
#endif
