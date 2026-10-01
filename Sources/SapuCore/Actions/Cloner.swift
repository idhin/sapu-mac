import Darwin
import Foundation

/// Replaces a duplicate file with an APFS clone of its twin. Both paths keep existing and keep
/// their own metadata, but the bytes are stored once.
public enum Cloner {
    private static let copyACL: UInt32 = 1 << 0
    private static let copyStat: UInt32 = 1 << 1
    private static let copyXattr: UInt32 = 1 << 2
    private static let copyNoFollow: UInt32 = (1 << 18) | (1 << 19)
    private static let cloneNoFollow: UInt32 = 0x0001
    private static let cloneNoOwnerCopy: UInt32 = 0x0002

    /// Returns the bytes that `target` occupied on its own before the swap.
    @discardableResult
    public static func replaceWithClone(source: String, target: String) throws -> Int64 {
        var src = stat(), dst = stat()
        guard lstat(source, &src) == 0, lstat(target, &dst) == 0 else { throw ActionFailure("file disappeared") }
        guard src.st_mode & S_IFMT == S_IFREG, dst.st_mode & S_IFMT == S_IFREG else { throw ActionFailure("not a regular file") }
        guard src.st_dev == dst.st_dev else { throw ActionFailure("copies are on different volumes") }
        guard src.st_ino != dst.st_ino else { throw ActionFailure("already the same file (hard link)") }
        guard dst.st_nlink == 1 else { throw ActionFailure("has other hard links") }
        guard dst.st_uid == geteuid() else { throw ActionFailure("owned by another user") }
        let compressed = UInt32(UF_COMPRESSED)
        guard src.st_flags & compressed == 0, dst.st_flags & compressed == 0 else { throw ActionFailure("uses file system compression") }
        let locked = UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND)
        guard dst.st_flags & locked == 0 else { throw ActionFailure("locked") }
        // A clone inherits the lock and could then neither be finished nor cleaned up.
        guard src.st_flags & locked == 0 else { throw ActionFailure("the copy that stays is locked") }
        guard src.st_size == dst.st_size, src.st_size > 0 else { throw ActionFailure("sizes differ") }

        let folder = PathUtil.parent(target)
        var folderInfo = stat()
        let haveFolderInfo = lstat(folder, &folderInfo) == 0
        let temp = folder + "/.sapu-" + UUID().uuidString

        guard clonefile(source, temp, cloneNoFollow | cloneNoOwnerCopy) == 0 else {
            let code = errno
            if code == ENOTSUP || code == EXDEV { throw ActionFailure("volume does not support clones") }
            throw ActionFailure(String(cString: strerror(code)))
        }
        var committed = false
        defer {
            if !committed {
                _ = lchflags(temp, 0)
                unlink(temp)
            }
        }

        // Compare the clone itself, not the source: the clone is a frozen snapshot, so whatever
        // happens to the source from here on, this is exactly what would take the target's place.
        guard FileHasher.contentsEqual(temp, target) else { throw ActionFailure("contents differ") }

        // The clone starts with the source's metadata; the path must keep the target's.
        stripExtendedAttributes(temp)
        guard copyfile(target, temp, nil, copyACL | copyStat | copyXattr | copyNoFollow) == 0 else {
            throw ActionFailure("could not carry over metadata: " + String(cString: strerror(errno)))
        }
        restoreTimes(temp, from: dst)

        // Last look: the target must still be exactly what was compared.
        var current = stat()
        guard lstat(target, &current) == 0, current.st_ino == dst.st_ino, current.st_size == dst.st_size,
              current.st_mtimespec.tv_sec == dst.st_mtimespec.tv_sec, current.st_mtimespec.tv_nsec == dst.st_mtimespec.tv_nsec else {
            throw ActionFailure("changed while being processed")
        }
        guard rename(temp, target) == 0 else { throw ActionFailure(String(cString: strerror(errno))) }
        committed = true

        if haveFolderInfo {
            var times = [folderInfo.st_atimespec, folderInfo.st_mtimespec]
            _ = utimensat(AT_FDCWD, folder, &times, 0)
        }
        return Int64(dst.st_blocks) * 512
    }

    private static func stripExtendedAttributes(_ path: String) {
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return }
        var buffer = [CChar](repeating: 0, count: size)
        let length = listxattr(path, &buffer, size, XATTR_NOFOLLOW)
        guard length > 0 else { return }
        var start = 0
        for index in 0..<length where buffer[index] == 0 {
            if index > start {
                // Best effort: a few system attributes cannot be removed, and are harmless.
                buffer.withUnsafeBufferPointer { _ = removexattr(path, $0.baseAddress! + start, XATTR_NOFOLLOW) }
            }
            start = index + 1
        }
    }

    private static func restoreTimes(_ path: String, from info: stat) {
        struct Times {
            var created: timespec
            var modified: timespec
        }
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = 0x0000_0200 | 0x0000_0400 // ATTR_CMN_CRTIME | ATTR_CMN_MODTIME
        var times = Times(created: info.st_birthtimespec, modified: info.st_mtimespec)
        _ = setattrlist(path, &attributes, &times, MemoryLayout<Times>.size, 0x0000_0001) // FSOPT_NOFOLLOW
    }
}
