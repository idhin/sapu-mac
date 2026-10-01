import Foundation

/// How to choose the copy that stays when a group of duplicates is cleaned up.
public struct KeepPolicy {
    public enum Rule: String, CaseIterable {
        /// Keep the copy that looks most like the original (see `DupePlanner.copyScore`).
        case auto
        case oldest
        case newest
    }

    public var rule: Rule = .auto
    /// Copies under these absolute paths are kept ahead of any others.
    public var prefer: [String] = []

    public init() {}
}

public enum DupePlanner {
    /// Fills in `suggested` for every group: which copies could go while one verified copy stays.
    ///
    /// Copies with a `hold` (inside another duplicate folder, a git working tree, or a folder that
    /// resembles its twin's) are never suggested; they stay and serve as the surviving copy.
    public static func suggest(_ groups: inout [DupGroup], policy: KeepPolicy) {
        // Largest first, so enclosing folders are decided before anything inside them.
        let order = groups.indices.sorted { a, b in
            let ga = groups[a], gb = groups[b]
            if ga.size != gb.size { return ga.size > gb.size }
            if ga.kind != gb.kind { return ga.kind == .folder }
            return (ga.members.map(\.depth).min() ?? 0) < (gb.members.map(\.depth).min() ?? 0)
        }
        var removed = Set<String>()
        for index in order {
            let members = groups[index].members
            let live = members.indices.filter { !isGone(members[$0].path, removed: removed) }
            let fixed = live.filter { members[$0].hold != nil }
            let candidates = live.filter { members[$0].hold == nil }

            var removal: [Int] = []
            if !fixed.isEmpty {
                removal = candidates
            } else if candidates.count >= 2 {
                let ranked = rank(candidates, in: members, policy: policy)
                removal = Array(ranked.dropFirst())
            }
            groups[index].suggested = removal.sorted()
            for member in removal { removed.insert(members[member].path) }
        }
    }

    /// True if `path` or one of its ancestors is in `removed`.
    public static func isGone(_ path: String, removed: Set<String>) -> Bool {
        guard !removed.isEmpty else { return false }
        var current = Substring(path)
        while true {
            if removed.contains(String(current)) { return true }
            guard let slash = current.lastIndex(of: "/"), slash != current.startIndex else { return false }
            current = current[..<slash]
        }
    }

    /// Groups where the selection would leave no copy behind. Selections are member indexes per group.
    public static func groupsWithoutSurvivor(_ groups: [DupGroup], selections: [Int: Set<Int>]) -> [Int] {
        var removed = Set<String>()
        for (group, selected) in selections {
            for member in selected { removed.insert(groups[group].members[member].path) }
        }
        return selections.keys.sorted().filter { group in
            guard let selected = selections[group], !selected.isEmpty else { return false }
            let members = groups[group].members
            return !members.indices.contains { !selected.contains($0) && !isGone(members[$0].path, removed: removed) }
        }
    }

    /// Orders member indexes from "best to keep" to "best to remove".
    static func rank(_ candidates: [Int], in members: [DupMember], policy: KeepPolicy) -> [Int] {
        let names = candidates.map { stem(PathUtil.basename(members[$0].path)) }
        var scores: [Int: Int] = [:]
        for (position, member) in candidates.enumerated() {
            var score = copyScore(members[member].path)
            // "Report 2" next to "Report" is Finder's naming for a duplicate.
            if let numbered = numberedBase(names[position]), names.contains(numbered) { score += 2 }
            scores[member] = score
        }
        func preferred(_ member: Int) -> Bool {
            policy.prefer.contains { PathUtil.isSameOrInside(members[member].path, $0) }
        }
        return candidates.sorted { a, b in
            let ma = members[a], mb = members[b]
            let pa = preferred(a), pb = preferred(b)
            if pa != pb { return pa }
            switch policy.rule {
            case .oldest where ma.mtime != mb.mtime: return ma.mtime < mb.mtime
            case .newest where ma.mtime != mb.mtime: return ma.mtime > mb.mtime
            default: break
            }
            if scores[a]! != scores[b]! { return scores[a]! < scores[b]! }
            if ma.depth != mb.depth { return ma.depth < mb.depth }
            if ma.mtime != mb.mtime { return ma.mtime < mb.mtime }
            return ma.path < mb.path
        }
    }

    private static let strongCopyPatterns: [NSRegularExpression] = [
        "[ ._-]copy( ?\\d+)?$",          // "Report copy", "Report copy 2", "report_copy"
        "^copy of ",                     // "Copy of Report"
        " ?\\(\\d+\\)$",                 // "Report (1)", browsers and Windows
        "[ ._-]salinan( ?\\d+)?$",       // Finder in Indonesian
        "^salinan ",
        "[ ._-]kopie( ?\\d+)?$",
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    private static let weakCopyPattern = try! NSRegularExpression(
        pattern: "(^|[ ._-])(backup|backups|bak|old|orig|archive|archived|tmp|temp)($|[ ._-])",
        options: [.caseInsensitive]
    )

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    static func stem(_ name: String) -> String {
        let ext = (name as NSString).pathExtension
        // Only strip real-looking extensions, not "v1.2 final".
        if !ext.isEmpty && ext.count <= 5 && !ext.contains(" ") && name.count > ext.count + 1 {
            return (name as NSString).deletingPathExtension
        }
        return name
    }

    /// True if the name itself says "copy": "Report copy", "Report (1)", "Copy of Report".
    public static func hasCopyPattern(_ name: String) -> Bool {
        let base = stem(name)
        return strongCopyPatterns.contains { matches($0, base) }
    }

    /// True if `name` reads as a variation of `original`: "Report 2", "Report-old", "Raw backup",
    /// "Old Report" or wget's "file.1".
    public static func isVariantName(_ name: String, of original: String) -> Bool {
        guard name != original else { return false }
        let separators: Set<Character> = [" ", "-", "_", ".", "("]
        if name.hasPrefix(original), let next = name.dropFirst(original.count).first, separators.contains(next) { return true }
        let a = stem(name), b = stem(original)
        guard a != b, !b.isEmpty else { return false }
        if a.hasPrefix(b), let next = a.dropFirst(b.count).first, separators.contains(next) { return true }
        if a.hasSuffix(b), let previous = a.dropLast(b.count).last, separators.contains(previous) { return true }
        return false
    }

    /// True for numbered takes of one thing: "Draft 5" and "Draft 7".
    public static func inSameSeries(_ a: String, _ b: String) -> Bool {
        guard let baseA = numberedBase(stem(a)), let baseB = numberedBase(stem(b)) else { return false }
        return baseA == baseB
    }

    /// "Report 2" → "Report"; nil if the name does not end in a small number.
    static func numberedBase(_ stem: String) -> String? {
        guard let space = stem.lastIndex(of: " ") else { return nil }
        let suffix = stem[stem.index(after: space)...]
        guard !suffix.isEmpty, suffix.count <= 2, suffix.allSatisfy(\.isNumber), space != stem.startIndex else { return nil }
        return String(stem[..<space])
    }

    /// Higher means "more likely the copy than the original", judged from every path component.
    public static func copyScore(_ path: String) -> Int {
        var score = 0
        for component in path.split(separator: "/") {
            let name = String(component)
            let base = stem(name)
            if strongCopyPatterns.contains(where: { matches($0, base) }) {
                score += 2
            } else if matches(weakCopyPattern, name) {
                score += 1
            }
        }
        let home = PathUtil.home
        if PathUtil.isSameOrInside(path, home + "/Downloads") { score += 1 }
        return score
    }
}
