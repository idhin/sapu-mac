import Darwin
import Foundation

extension FileTree {
    /// Compares what is on disk now with what the scan saw. Returns nil when nothing changed,
    /// otherwise the first difference found.
    ///
    /// Every destructive action runs this first: a duplicate verdict only holds for the bytes
    /// that were hashed, so anything touched since the scan is left alone.
    public func changeSinceScan(_ index: Int32) -> String? {
        var stack: [(node: Int32, path: String)] = [(index, path(index))]
        while let (nodeIndex, nodePath) = stack.popLast() {
            let node = nodes[Int(nodeIndex)]
            var info = stat()
            guard lstat(nodePath, &info) == 0 else { return "no longer exists: \(nodePath)" }
            guard Walker.kind(mode: info.st_mode) == node.kind else { return "changed type: \(nodePath)" }

            switch node.kind {
            case .file:
                if Int64(info.st_size) != node.size || Int64(info.st_mtimespec.tv_sec) != node.mtime
                    || UInt32(truncatingIfNeeded: info.st_mtimespec.tv_nsec) != node.mtimeNanos || UInt64(info.st_ino) != node.inode {
                    return "modified: \(nodePath)"
                }
            case .symlink:
                // A link cannot be edited in place; pointing it elsewhere makes a new one.
                if Int64(info.st_size) != node.size || UInt64(info.st_ino) != node.inode { return "modified: \(nodePath)" }
            case .other:
                break
            case .dir:
                guard let found = FileTree.entryNames(nodePath) else { return "cannot be read: \(nodePath)" }
                let expected = children(nodeIndex).filter { !(nodes[Int($0)].kind == .file && nameEquals($0, ".DS_Store")) }
                guard found.count == expected.count else { return "entries were added or removed: \(nodePath)" }
                // Both lists are in byte order, so they must match position by position.
                for (name, child) in zip(found, expected) {
                    let same = withNameBytes(child) { $0.elementsEqual(name) }
                    guard same else { return "entries were added or removed: \(nodePath)" }
                    stack.append((child, nodePath + "/" + String(decoding: name, as: UTF8.self)))
                }
            }
        }
        return nil
    }

    /// Entry names of a directory in byte order, without Finder's `.DS_Store` file.
    /// Nil if it cannot be listed.
    static func entryNames(_ path: String) -> [[UInt8]]? {
        guard let dir = opendir(path) else { return nil }
        defer { closedir(dir) }
        let finderFile = Array(".DS_Store".utf8)
        var names: [[UInt8]] = []
        while let entry = readdir(dir) {
            let length = Int(entry.pointee.d_namlen)
            let name: [UInt8] = withUnsafeBytes(of: &entry.pointee.d_name) { Array($0.prefix(length)) }
            if name == [0x2e] || name == [0x2e, 0x2e] { continue }
            if name == finderFile {
                // Only the regular file is ignorable; a folder of that name holds real content.
                var isFile = entry.pointee.d_type == DT_REG
                if entry.pointee.d_type == DT_UNKNOWN {
                    var info = stat()
                    isFile = lstat(path + "/.DS_Store", &info) == 0 && info.st_mode & S_IFMT == S_IFREG
                }
                if isFile { continue }
            }
            names.append(name)
        }
        names.sort { $0.lexicographicallyPrecedes($1) }
        return names
    }
}
