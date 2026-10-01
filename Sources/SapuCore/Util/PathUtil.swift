import Darwin
import Foundation

public enum PathUtil {
    /// The user's home directory with symlinks resolved, so it compares equal to scanned paths.
    public static let home: String = {
        let raw = NSHomeDirectory()
        return realPath(raw) ?? raw
    }()

    public static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Expands `~`, makes the path absolute and resolves symlinks. Returns nil if it does not exist.
    public static func normalize(_ input: String) -> String? {
        var path = (input as NSString).expandingTildeInPath
        if !path.hasPrefix("/") {
            path = FileManager.default.currentDirectoryPath + "/" + path
        }
        guard let resolved = realPath(path) else { return nil }
        // User data is reachable both as /Users/... and as /System/Volumes/Data/Users/...;
        // settle on the short spelling so one folder never looks like two.
        let dataVolume = "/System/Volumes/Data"
        if resolved.hasPrefix(dataVolume + "/") {
            let short = String(resolved.dropFirst(dataVolume.count))
            if sameObject(short, resolved) { return short }
        }
        return resolved
    }

    static func objectID(_ path: String) -> ObjectID? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return ObjectID(dev: info.st_dev, inode: UInt64(info.st_ino))
    }

    /// True when both paths lead to the very same file or folder (not merely equal contents).
    public static func sameObject(_ a: String, _ b: String) -> Bool {
        guard let first = objectID(a), let second = objectID(b) else { return false }
        return first == second
    }

    private static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    /// `/Users/me/Documents` → `~/Documents`.
    public static func abbreviate(_ path: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// True when `path` is `ancestor` itself or lives somewhere below it.
    public static func isSameOrInside(_ path: String, _ ancestor: String) -> Bool {
        if path == ancestor { return true }
        if ancestor == "/" { return path.hasPrefix("/") }
        return path.hasPrefix(ancestor + "/")
    }

    /// Drops roots that are duplicates of, or nested inside, another root. Besides comparing the
    /// path text, this compares the folders themselves, so a second spelling of a path
    /// (a firmlink, a second mount point) is recognised as the same place.
    public static func dedupeRoots(_ roots: [String]) -> [String] {
        var unique: [String] = []
        for root in roots where !unique.contains(root) { unique.append(root) }

        let folders = unique.map { isDirectory($0) ? objectID($0) : nil }
        return unique.enumerated().filter { index, root in
            // Identities of every folder above this root, up to the top of the disk.
            var above = Set<ObjectID>()
            var current = root
            while current != "/" {
                current = parent(current)
                if let id = objectID(current) { above.insert(id) }
            }
            for (other, otherRoot) in unique.enumerated() where other != index {
                if root != otherRoot && isSameOrInside(root, otherRoot) { return false }
                guard let otherFolder = folders[other] else { continue }
                if above.contains(otherFolder) { return false }
                if folders[index] == otherFolder && other < index { return false }
            }
            return true
        }.map(\.element)
    }

    public static func parent(_ path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    public static func basename(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}
