import Darwin
import Foundation

public enum RemoveMode: String {
    /// Move to the Trash. Recoverable; space is freed once the Trash is emptied.
    case trash
    /// Delete immediately. Not recoverable.
    case delete
}

public struct ActionFailure: Error, CustomStringConvertible {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
    public var description: String { reason }
}

/// Paths sapu refuses to remove no matter what a scan or a rule says.
public enum Guardrails {
    private static let exact: Set<String> = [
        "/", "/Applications", "/Library", "/System", "/Users", "/Volumes", "/bin", "/cores", "/etc", "/opt",
        "/private", "/private/etc", "/private/tmp", "/private/var", "/sbin", "/tmp", "/usr", "/usr/local", "/var",
        "/opt/homebrew", "/Users/Shared",
    ]

    private static let systemPrefixes = ["/System/", "/bin/", "/sbin/", "/Library/", "/private/etc/", "/private/var/db/"]

    /// Folders that make up a home directory, relative to it. Removing one whole is never a cleanup.
    private static let homeFolders: Set<String> = [
        "", "/Applications", "/Desktop", "/Documents", "/Downloads", "/Library", "/Movies", "/Music", "/Pictures", "/Public",
        "/.Trash", "/.ssh", "/.gnupg", "/Pictures/Photos Library.photoslibrary",
        "/Library/Application Support", "/Library/Caches", "/Library/CloudStorage", "/Library/Containers", "/Library/Developer",
        "/Library/Group Containers", "/Library/Keychains", "/Library/Logs", "/Library/Mail", "/Library/Messages",
        "/Library/Mobile Documents", "/Library/Mobile Documents/com~apple~CloudDocs", "/Library/Preferences",
    ]

    /// Places where nothing inside may be removed either: credentials and mail.
    private static let homeVaults = ["/.ssh/", "/.gnupg/", "/Library/Keychains/", "/Library/Mail/", "/Library/Messages/"]

    /// The part of `path` after a home directory ("" for the home itself), for the current user's
    /// home and for any home under /Users, so the rules also hold when running as another user.
    private static func homeRelative(_ path: String) -> String? {
        let home = PathUtil.home
        if PathUtil.isSameOrInside(path, home) { return String(path.dropFirst(home.count)) }
        guard path.hasPrefix("/Users/") else { return nil }
        let rest = path.dropFirst("/Users/".count)
        guard let slash = rest.firstIndex(of: "/") else { return "" }
        return String(rest[slash...])
    }

    /// Why `path` must not be removed, or nil if it may be.
    public static func refusal(for path: String) -> String? {
        guard path.hasPrefix("/"), !path.contains("/../"), !path.hasSuffix("/.."), !path.contains("//") else {
            return "not an absolute, normalized path"
        }
        if exact.contains(path) { return "system location" }
        if path.hasPrefix("/usr/") && !path.hasPrefix("/usr/local/") { return "system location" }
        if systemPrefixes.contains(where: { path.hasPrefix($0) }) { return "system location" }
        if let relative = homeRelative(path) {
            if relative.isEmpty { return "home directory" }
            if homeFolders.contains(relative) { return "standard home folder" }
            if homeVaults.contains(where: { relative.hasPrefix($0) }) { return "credentials or mail" }
            // The sync roots of cloud storage providers, one level below CloudStorage.
            if relative.hasPrefix("/Library/CloudStorage/") && !relative.dropFirst("/Library/CloudStorage/".count).contains("/") {
                return "cloud storage folder"
            }
        }
        if PathUtil.parent(path) == "/Volumes" { return "volume root" }
        return nil
    }
}

public enum Remover {
    public static func remove(_ path: String, mode: RemoveMode) throws {
        if let reason = Guardrails.refusal(for: path) {
            throw ActionFailure("refused: \(reason)")
        }
        var info = stat()
        guard lstat(path, &info) == 0 else {
            if errno == ENOENT { return }
            throw ActionFailure(String(cString: strerror(errno)))
        }
        switch mode {
        case .trash:
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            } catch {
                throw ActionFailure(describe(error))
            }
        case .delete:
            do {
                try FileManager.default.removeItem(atPath: path)
            } catch {
                // Package managers (Go modules, for one) ship read-only folders; unlock and retry once.
                guard info.st_mode & S_IFMT == S_IFDIR else { throw ActionFailure(describe(error)) }
                makeFoldersWritable(path)
                do {
                    try FileManager.default.removeItem(atPath: path)
                } catch {
                    throw ActionFailure(describe(error))
                }
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return String(cString: strerror(Int32(underlying.code)))
        }
        if nsError.domain == NSPOSIXErrorDomain { return String(cString: strerror(Int32(nsError.code))) }
        return nsError.localizedDescription
    }

    private static func makeFoldersWritable(_ root: String) {
        var stack = [root]
        while let dir = stack.popLast() {
            var info = stat()
            guard lstat(dir, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
            _ = chmod(dir, (info.st_mode & 0o7777) | 0o700)
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries {
                let child = dir + "/" + entry
                var childInfo = stat()
                if lstat(child, &childInfo) == 0, childInfo.st_mode & S_IFMT == S_IFDIR { stack.append(child) }
            }
        }
    }
}
