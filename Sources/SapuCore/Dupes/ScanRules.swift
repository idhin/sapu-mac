import Darwin
import Foundation

public enum ScanRules {
    private static let insideArtifact: UInt8 = 1

    /// Classifier for duplicate scans: leaves out the places where identical files are normal and
    /// must not be touched, plus anything the user excluded.
    ///
    /// - Parameter excludes: entry names or glob patterns (`*.iso`, `Archive`), or absolute paths.
    public static func dupes(home: String = PathUtil.home, excludes: [String] = []) -> Walker.Classifier {
        let patterns = excludes.filter { !$0.hasPrefix("/") }
        let paths = Set(excludes.filter { $0.hasPrefix("/") })
        return { listing in
            // Inside build output nothing is reported on its own; no decisions left to make.
            guard listing.context != insideArtifact else { return }
            if listing.path == home || (listing.path.hasPrefix("/Users/") && PathUtil.parent(listing.path) == "/Users") {
                // App data and the Trash: copies in there are either intentional or already discarded.
                for name in ["Library", ".Trash"] {
                    if let index = listing.indexOf(name) { listing.prune(index) }
                }
            }
            let prefix = listing.path == "/" ? "/" : listing.path + "/"
            let hasExcludes = !patterns.isEmpty || !paths.isEmpty
            for index in 0..<listing.count where hasExcludes || listing.kind(index) == .dir {
                let name = listing.name(index)
                if patterns.contains(where: { fnmatch($0, name, 0) == 0 }) || paths.contains(prefix + name) {
                    listing.prune(index)
                } else if listing.kind(index) == .dir, let tag = ArtifactRule.tag(index: index, name: name, in: listing) {
                    // Build output and installed dependencies are `sapu junk` territory. They still
                    // count when whole projects are compared, but are never reported piecemeal.
                    listing.setTag(index, tag)
                    listing.setContext(index, insideArtifact)
                }
            }
        }
    }
}
