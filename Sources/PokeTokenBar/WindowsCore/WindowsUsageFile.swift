#if os(Windows)
import Foundation
import WinSDK

/// Defensive reads of user-selected log trees. This is not a sandbox for an
/// adversarial WSL filesystem; provider metadata and the local account are trusted.
enum WindowsUsageFile {
    struct ScannedFile {
        let url: URL
        let modificationDate: Date
        let size: Int
    }

    // A changing/appending file is read only up to its initial length. Very large
    // sessions are skipped, never silently parsed as a truncated whole JSON file.
    static let maxLogBytes = 256 * 1024 * 1024

    /// Include every directory between the drive/share and the leaf. Checking only
    /// `.codex/sessions` misses a redirected `.codex` or an ancestor of HOME.
    /// GetFileAttributesW cannot query a bare UNC share, so stop below that boundary.
    static func pathPrefixes(_ rawPath: String) -> [String]? {
        let path = comparablePath(rawPath)
        var prefix: String
        var components: [String]
        if path.hasPrefix("\\\\") {
            let parts = path.dropFirst(2).split(separator: "\\", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3, parts.allSatisfy(WSLUsage.isSafePathComponent) else { return nil }
            prefix = "\\\\\(parts[0])\\\(parts[1])"
            components = Array(parts.dropFirst(2))
        } else {
            let chars = Array(path)
            guard chars.count >= 3, chars[0].isASCII, chars[0].isLetter,
                  chars[1] == ":", chars[2] == "\\" else { return nil }
            prefix = String(chars.prefix(3))
            components = String(chars.dropFirst(3)).split(separator: "\\", omittingEmptySubsequences: false).map(String.init)
            guard components.allSatisfy(WSLUsage.isSafePathComponent) else { return nil }
        }
        var paths: [String] = []
        for component in components {
            if !prefix.hasSuffix("\\") { prefix += "\\" }
            prefix += component
            paths.append(prefix)
        }
        return paths
    }

    static func isUnsafe(_ url: URL) -> Bool {
        guard url.isFileURL, let paths = pathPrefixes(url.path), !paths.isEmpty else { return true }
        return paths.contains { path in
            let wide = win32Path(path)
            let attributes = wide.withUnsafeBufferPointer { GetFileAttributesW($0.baseAddress) }
            // Unreadable/disappearing metadata must not be mistaken for a safe file.
            return attributes == INVALID_FILE_ATTRIBUTES ||
                (attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT)) != 0
        }
    }

    /// Recursively enumerate JSONL files with Win32 APIs. Foundation's directory
    /// enumerator can return an empty sequence for WSL's `\\wsl.localhost` provider
    /// even when the same path is readable from PowerShell. Keep this walker narrow:
    /// it validates every path component and never follows reparse points.
    static func nativeJSONLFiles(in root: URL, modifiedSince: Date,
                                 allowJSON: Bool = false) -> [ScannedFile] {
        guard root.isFileURL, !isUnsafe(root) else { return [] }
        var stack = [comparablePath(root.path)]
        var result: [ScannedFile] = []

        while let directory = stack.popLast() {
            let patternPath = directory + (directory.hasSuffix("\\") ? "*" : "\\*")
            let pattern = win32Path(patternPath)
            var data = WIN32_FIND_DATAW()
            let first = pattern.withUnsafeBufferPointer {
                FindFirstFileW($0.baseAddress, &data)
            }
            guard let handle = first, handle != INVALID_HANDLE_VALUE else { continue }

            repeat {
                let name = fileName(from: &data)
                if name == "." || name == ".." { continue }
                guard WSLUsage.isSafePathComponent(name) else { continue }

                let attributes = data.dwFileAttributes
                if (attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT)) != 0 { continue }

                let childPath = directory + (directory.hasSuffix("\\") ? "" : "\\") + name
                if (attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY)) != 0 {
                    stack.append(childPath)
                    continue
                }

                let lower = name.lowercased()
                guard lower.hasSuffix(".jsonl") || (allowJSON && lower.hasSuffix(".json")) else { continue }
                let mtime = date(from: data.ftLastWriteTime)
                guard mtime >= modifiedSince else { continue }

                let size64 = (UInt64(data.nFileSizeHigh) << 32) | UInt64(data.nFileSizeLow)
                guard size64 <= UInt64(Int.max) else { continue }
                result.append(ScannedFile(
                    url: URL(fileURLWithPath: childPath),
                    modificationDate: mtime,
                    size: Int(size64)))
            } while FindNextFileW(handle, &data) != 0

            _ = FindClose(handle)
        }

        return result
    }

    static func read(_ url: URL, maxBytes: Int = maxLogBytes) -> Data? {
        guard maxBytes >= 0, maxBytes <= maxLogBytes, !isUnsafe(url) else { return nil }
        let path = win32Path(url.path)
        let handle = path.withUnsafeBufferPointer {
            CreateFileW($0.baseAddress, DWORD(GENERIC_READ), DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE),
                        nil, DWORD(OPEN_EXISTING),
                        DWORD(FILE_FLAG_SEQUENTIAL_SCAN), nil)
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else { return nil }
        defer { CloseHandle(handle) }
        var info = BY_HANDLE_FILE_INFORMATION()
        guard GetFileType(handle) == DWORD(FILE_TYPE_DISK), GetFileInformationByHandle(handle, &info),
              (info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY)) == 0,
              openedPathMatchesRequest(handle, url.path),
              !isUnsafe(url) else { return nil }
        let length = (UInt64(info.nFileSizeHigh) << 32) | UInt64(info.nFileSizeLow)
        guard length <= UInt64(maxBytes) else { return nil }
        var remaining = Int(length)
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: min(64 * 1024, remaining))
        while remaining > 0 {
            let count = min(buffer.count, remaining)
            var received: DWORD = 0
            let ok = buffer.withUnsafeMutableBytes {
                ReadFile(handle, $0.baseAddress, DWORD(count), &received, nil)
            }
            guard ok, received > 0 else { return nil }  // truncated during the read
            result.append(contentsOf: buffer.prefix(Int(received)))
            remaining -= Int(received)
        }
        return result
    }

    /// WSL's UNC provider is a virtual filesystem. On affected Windows/WSL
    /// versions the handle APIs used for a DOS final-path comparison return
    /// `ERROR_INVALID_FUNCTION`, even though CreateFile/ReadFile work normally.
    /// In that case the earlier ancestor and handle attribute checks remain the
    /// safety boundary; if either API does return a path, a mismatch is still
    /// rejected instead of silently trusted.
    private static func openedPathMatchesRequest(_ handle: HANDLE, _ requested: String) -> Bool {
        guard let final = finalPath(handle) else { return isWSLUNCPath(requested) }
        guard let expected = longPath(requested) else { return false }
        return comparablePath(final).caseInsensitiveCompare(comparablePath(expected)) == .orderedSame
    }

    private static func finalPath(_ handle: HANDLE) -> String? {
        var buffer = [WCHAR](repeating: 0, count: 32768)
        let count = buffer.withUnsafeMutableBufferPointer {
            // Zero = FILE_NAME_NORMALIZED | VOLUME_NAME_DOS. No unchecked fallback
            // if a filesystem provider cannot verify the opened file's final path.
            GetFinalPathNameByHandleW(handle, $0.baseAddress, DWORD($0.count), 0)
        }
        guard count > 0, Int(count) < buffer.count else { return nil }
        return String(decoding: buffer.prefix(Int(count)), as: UTF16.self)
    }

    private static func longPath(_ path: String) -> String? {
        let source = win32Path(path)
        var buffer = [WCHAR](repeating: 0, count: 32768)
        let count = source.withUnsafeBufferPointer { input in
            buffer.withUnsafeMutableBufferPointer { output in
                GetLongPathNameW(input.baseAddress, output.baseAddress, DWORD(output.count))
            }
        }
        // GetLongPathNameW is optional for the WSL provider. Returning the
        // already-normalized UNC path still lets a successful final-path query
        // perform an equality check without weakening local-drive validation.
        guard count > 0, Int(count) < buffer.count else {
            return isWSLUNCPath(path) ? comparablePath(path) : nil
        }
        return String(decoding: buffer.prefix(Int(count)), as: UTF16.self)
    }

    private static func fileName(from data: inout WIN32_FIND_DATAW) -> String {
        withUnsafePointer(to: &data.cFileName) { pointer in
            pointer.withMemoryRebound(to: WCHAR.self, capacity: Int(MAX_PATH)) {
                String(decodingCString: $0, as: UTF16.self)
            }
        }
    }

    private static func date(from value: FILETIME) -> Date {
        let ticks = (UInt64(value.dwHighDateTime) << 32) | UInt64(value.dwLowDateTime)
        let unixSeconds = Double(ticks) / 10_000_000.0 - 11_644_473_600.0
        return Date(timeIntervalSince1970: unixSeconds)
    }

    private static func comparablePath(_ path: String) -> String {
        let windows = path.replacingOccurrences(of: "/", with: "\\")
        if windows.hasPrefix("\\\\?\\UNC\\") { return "\\\\" + windows.dropFirst(8) }
        if windows.hasPrefix("\\\\?\\") { return String(windows.dropFirst(4)) }
        return windows
    }

    /// WSL's virtual UNC provider does not consistently support the extended
    /// namespace. Deep Windows paths still use it after component validation.
    private static func win32Path(_ path: String) -> [WCHAR] {
        let normal = comparablePath(path)
        let native = isWSLUNCPath(normal)
            ? normal
            : (normal.hasPrefix("\\\\") ? "\\\\?\\UNC\\" + normal.dropFirst(2) : "\\\\?\\" + normal)
        return Array(native.utf16) + [0]
    }

    /// True only for the WSL localhost projection. Other UNC shares keep the
    /// strict extended-path/final-path behavior used for Windows files.
    static func isWSLUNCPath(_ rawPath: String) -> Bool {
        let path = comparablePath(rawPath)
        guard path.hasPrefix("\\\\") else { return false }
        let components = path.dropFirst(2).split(separator: "\\", omittingEmptySubsequences: true)
        return components.first?.caseInsensitiveCompare("wsl.localhost") == .orderedSame
    }
}
#endif