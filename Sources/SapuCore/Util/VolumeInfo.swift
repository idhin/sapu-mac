import Darwin
import Foundation

public struct VolumeInfo {
    public let name: String
    public let total: Int64
    /// Free right now.
    public let free: Int64
    /// Free plus what macOS can purge on demand (caches, local snapshots): what Finder calls "available".
    public let available: Int64

    public var used: Int64 { total - free }
    public var purgeable: Int64 { max(0, available - free) }

    public static func of(path: String) -> VolumeInfo? {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys), let total = values.volumeTotalCapacity,
              let free = values.volumeAvailableCapacity else { return nil }
        let important = values.volumeAvailableCapacityForImportantUsage ?? Int64(free)
        return VolumeInfo(name: values.volumeName ?? path, total: Int64(total), free: Int64(free), available: max(important, Int64(free)))
    }

    /// Number of local Time Machine snapshots on the boot volume. They can pin deleted data for a day or so.
    public static func localSnapshotCount() -> Int {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = ["listlocalsnapshots", "/"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return 0
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").filter { $0.contains("com.apple.TimeMachine") }.count
    }

    /// Stops this process from ever downloading cloud-only ("dataless") files as a side effect of reading them.
    public static func neverMaterializeCloudFiles() {
        // IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_OFF
        _ = setiopolicy_np(3, 0, 1)
    }
}
