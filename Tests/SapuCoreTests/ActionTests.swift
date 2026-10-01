import Darwin
import Foundation
import Testing
@testable import SapuCore

@Suite struct PlannerTests {
    @Test func recognisesCopyNames() {
        #expect(DupePlanner.copyScore("/x/Report.pdf") == 0)
        #expect(DupePlanner.copyScore("/x/Report copy.pdf") == 2)
        #expect(DupePlanner.copyScore("/x/Report copy 3.pdf") == 2)
        #expect(DupePlanner.copyScore("/x/Report (1).pdf") == 2)
        #expect(DupePlanner.copyScore("/x/Copy of Report.pdf") == 2)
        #expect(DupePlanner.copyScore("/x/Report salinan.pdf") == 2)
        #expect(DupePlanner.copyScore("/x/Project copy/src/main.c") == 2)
        #expect(DupePlanner.copyScore("/x/backup/Report.pdf") == 1)
        #expect(DupePlanner.copyScore("/x/Report.bak") == 1)
        #expect(DupePlanner.hasCopyPattern("Report copy.pdf"))
        #expect(!DupePlanner.hasCopyPattern("Report.pdf"))
        #expect(DupePlanner.isVariantName("Report 2.pdf", of: "Report.pdf"))
        #expect(DupePlanner.isVariantName("Raw backup", of: "Raw"))
        #expect(DupePlanner.isVariantName("libclient.1", of: "libclient"))
        #expect(DupePlanner.isVariantName("Old Report.pdf", of: "Report.pdf"))
        #expect(DupePlanner.inSameSeries("Draft 5", "Draft 7"))
        #expect(!DupePlanner.inSameSeries("Draft 5", "Final 7"))
        #expect(!DupePlanner.isVariantName("en-US.json", of: "en-GB.json"))
        #expect(!DupePlanner.isVariantName("icon@2x.png", of: "icon.png"))
        // Words that merely contain "copy" or "old" are not copies.
        #expect(DupePlanner.copyScore("/x/Photocopy.pdf") == 0)
        #expect(DupePlanner.copyScore("/x/Goldfish.jpg") == 0)
    }

    private func keptPath(_ box: Sandbox, policy: KeepPolicy = KeepPolicy()) -> String {
        let tree = box.scan()
        var options = DupeOptions()
        options.minSize = 1
        let group = DupeFinder(tree: tree, options: options).run(policy: policy).groups[0]
        let kept = Set(group.members.indices).subtracting(group.suggested)
        #expect(kept.count == 1)
        return String(group.members[kept.first!].path.dropFirst(box.root.count + 1))
    }

    @Test func keepsTheOriginalLookingName() {
        let box = Sandbox()
        box.write("Notes 2.txt", seed: 1)
        box.write("Notes.txt", seed: 1)
        box.write("Notes (1).txt", seed: 1)
        #expect(keptPath(box) == "Notes.txt")
    }

    @Test func prefersShallowerThenFollowsExplicitRules() {
        let box = Sandbox()
        box.write("deep/er/file.bin", seed: 2)
        box.write("file.bin", seed: 2)
        #expect(keptPath(box) == "file.bin")

        var policy = KeepPolicy()
        policy.prefer = [box.path("deep")]
        #expect(keptPath(box, policy: policy) == "deep/er/file.bin")

        // Make the deep one clearly older, then ask for newest/oldest.
        var times = [timeval(tv_sec: 1_000_000_000, tv_usec: 0), timeval(tv_sec: 1_000_000_000, tv_usec: 0)]
        utimes(box.path("deep/er/file.bin"), &times)
        policy = KeepPolicy()
        policy.rule = .oldest
        #expect(keptPath(box, policy: policy) == "deep/er/file.bin")
        policy.rule = .newest
        #expect(keptPath(box, policy: policy) == "file.bin")
    }

    @Test func detectsSelectionsThatLeaveNothing() {
        let box = Sandbox()
        box.write("a.bin", seed: 3)
        box.write("b.bin", seed: 3)
        let groups = box.dupes().result.groups
        #expect(DupePlanner.groupsWithoutSurvivor(groups, selections: [0: [0]]).isEmpty)
        #expect(DupePlanner.groupsWithoutSurvivor(groups, selections: [0: [0, 1]]) == [0])
    }
}

@Suite struct ExecutorTests {
    private func suggestions(_ groups: [DupGroup]) -> [Int: Set<Int>] {
        var selections: [Int: Set<Int>] = [:]
        for (index, group) in groups.enumerated() where !group.suggested.isEmpty {
            selections[index] = Set(group.suggested)
        }
        return selections
    }

    @Test func deletesSuggestedCopiesAndKeepsOne() {
        let box = Sandbox()
        for name in ["Photos", "Photos copy"] {
            box.write("\(name)/a.jpg", seed: 1, size: 20_000)
            box.write("\(name)/b.jpg", seed: 2, size: 30_000)
        }
        box.write("c.bin", seed: 3, size: 10_000)
        box.write("c (1).bin", seed: 3, size: 10_000)

        let (tree, finder, result) = box.dupes()
        let executor = DupeExecutor(tree: tree, finder: finder, groups: result.groups)

        var outcomes: [DupeOutcome] = []
        let preview = executor.execute(selections: suggestions(result.groups), action: .delete, dryRun: true) { outcomes.append($0) }
        #expect(preview.done == 2)
        #expect(box.exists("Photos copy") && box.exists("c (1).bin"))

        let summary = executor.execute(selections: suggestions(result.groups), action: .delete, dryRun: false) { _ in }
        #expect(summary.done == 2)
        #expect(summary.skipped == 0)
        #expect(summary.bytes == result.reclaimable)
        #expect(box.exists("Photos/a.jpg") && box.exists("c.bin"))
        #expect(!box.exists("Photos copy") && !box.exists("c (1).bin"))
    }

    @Test func leavesAloneAnythingChangedSinceTheScan() {
        let box = Sandbox()
        box.write("A/data.bin", seed: 4, size: 10_000)
        box.write("A copy/data.bin", seed: 4, size: 10_000)
        let (tree, finder, result) = box.dupes()

        // The copy gains a file after the scan: it is no longer a duplicate.
        box.write("A copy/unsaved-work.txt", text: "important")
        var outcomes: [DupeOutcome] = []
        let summary = DupeExecutor(tree: tree, finder: finder, groups: result.groups)
            .execute(selections: suggestions(result.groups), action: .delete, dryRun: false) { outcomes.append($0) }
        #expect(summary.done == 0)
        #expect(summary.skipped == 1)
        #expect(outcomes.first?.detail?.contains("changed since the scan") == true)
        #expect(box.exists("A copy/unsaved-work.txt"))
    }

    @Test func refusesWhenTheSurvivorIsGone() {
        let box = Sandbox()
        box.write("keep.bin", seed: 5, size: 10_000)
        box.write("keep copy.bin", seed: 5, size: 10_000)
        let (tree, finder, result) = box.dupes()

        try! FileManager.default.removeItem(atPath: box.path("keep.bin"))
        let summary = DupeExecutor(tree: tree, finder: finder, groups: result.groups)
            .execute(selections: suggestions(result.groups), action: .delete, dryRun: false) { _ in }
        #expect(summary.done == 0)
        #expect(box.exists("keep copy.bin"))
    }

    @Test func refusesToRemoveEveryCopy() {
        let box = Sandbox()
        box.write("one.bin", seed: 6, size: 10_000)
        box.write("two.bin", seed: 6, size: 10_000)
        let (tree, finder, result) = box.dupes()
        let summary = DupeExecutor(tree: tree, finder: finder, groups: result.groups)
            .execute(selections: [0: [0, 1]], action: .delete, dryRun: false) { _ in }
        #expect(summary.done == 0)
        #expect(summary.skipped == 2)
        #expect(box.exists("one.bin") && box.exists("two.bin"))
    }

    @Test func clonesFoldersInPlace() {
        let box = Sandbox()
        for name in ["Raw", "Raw backup"] {
            box.write("\(name)/shot1.raw", seed: 7, size: 1 << 20)
            box.write("\(name)/sub/shot2.raw", seed: 8, size: 1 << 20)
        }
        let (tree, finder, result) = box.dupes()
        #expect(result.reclaimable == 2 << 20)

        let summary = DupeExecutor(tree: tree, finder: finder, groups: result.groups)
            .execute(selections: suggestions(result.groups), action: .clone, dryRun: false) { _ in }
        #expect(summary.done == 1)
        #expect(summary.bytes == 2 << 20)
        #expect(box.exists("Raw backup/sub/shot2.raw"))

        // A fresh scan sees the same duplicates, now costing nothing.
        let after = box.dupes().result
        #expect(after.groups.count == 1)
        #expect(after.reclaimable == 0)
        #expect(after.shared == 2 << 20)
        #expect(box.scan().nodes[0].alloc == 2 << 20)
    }
}

@Suite struct ClonerTests {
    @Test func keepsTheTargetsOwnMetadata() throws {
        let box = Sandbox()
        box.write("source.bin", seed: 9, size: 300_000)
        box.write("target.bin", seed: 9, size: 300_000)
        let source = box.path("source.bin"), target = box.path("target.bin")

        chmod(target, 0o640)
        setxattr(target, "user.sapu.test", "tagged", 6, 0, 0)
        setxattr(source, "user.sapu.source-only", "x", 1, 0, 0)
        var times = [timeval(tv_sec: 1_200_000_000, tv_usec: 0), timeval(tv_sec: 1_200_000_000, tv_usec: 0)]
        utimes(target, &times)
        var folderBefore = stat()
        lstat(box.root, &folderBefore)

        let saved = try Cloner.replaceWithClone(source: source, target: target)
        #expect(saved >= 300_000)

        var info = stat()
        lstat(target, &info)
        #expect(info.st_mode & 0o7777 == 0o640)
        #expect(info.st_mtimespec.tv_sec == 1_200_000_000)
        #expect(info.st_birthtimespec.tv_sec == 1_200_000_000)
        #expect(getxattr(target, "user.sapu.test", nil, 0, 0, 0) == 6)
        #expect(getxattr(target, "user.sapu.source-only", nil, 0, 0, 0) == -1)
        #expect(FileHasher.contentsEqual(source, target))

        var folderAfter = stat()
        lstat(box.root, &folderAfter)
        #expect(folderAfter.st_mtimespec.tv_sec == folderBefore.st_mtimespec.tv_sec)
        #expect(folderAfter.st_mtimespec.tv_nsec == folderBefore.st_mtimespec.tv_nsec)

        let tree = box.scan()
        let root = tree.roots[0]
        #expect(tree[tree.child(of: root, named: "source.bin")!].cloneID == tree[tree.child(of: root, named: "target.bin")!].cloneID)
        #expect(tree[root].childCount == 2) // no temporary file left behind
    }

    @Test func refusesFilesThatDiffer() {
        let box = Sandbox()
        box.write("source.bin", seed: 1, size: 50_000)
        box.write("target.bin", seed: 2, size: 50_000)
        #expect(throws: ActionFailure.self) {
            try Cloner.replaceWithClone(source: box.path("source.bin"), target: box.path("target.bin"))
        }
        #expect(FileManager.default.contents(atPath: box.path("target.bin")) == Sandbox.bytes(seed: 2, count: 50_000))
        #expect((try? FileManager.default.contentsOfDirectory(atPath: box.root))?.count == 2)
    }

    @Test func refusesHardLinkedTargets() {
        let box = Sandbox()
        box.write("source.bin", seed: 3, size: 50_000)
        box.write("target.bin", seed: 3, size: 50_000)
        link(box.path("target.bin"), box.path("other-name.bin"))
        #expect(throws: ActionFailure.self) {
            try Cloner.replaceWithClone(source: box.path("source.bin"), target: box.path("target.bin"))
        }
    }
}

@Suite struct GuardrailTests {
    @Test func protectsSystemAndHomeFolders() {
        let home = PathUtil.home
        for path in ["/", "/System/Library/Fonts", "/usr/bin/git", "/Library/Preferences", "/Applications", home,
                     home + "/Documents", home + "/Library", home + "/Library/Caches", "/Users/somebody", "/Volumes/Backup", "relative/path"] {
            #expect(Guardrails.refusal(for: path) != nil, "\(path) should be protected")
        }
        for path in [home + "/Documents/old project", home + "/Library/Caches/com.example.app", "/usr/local/share/thing",
                     "/Applications/Install macOS Sonoma.app", "/Volumes/Backup/folder"] {
            #expect(Guardrails.refusal(for: path) == nil, "\(path) should be removable")
        }
    }

    @Test func deletesReadOnlyTrees() throws {
        let box = Sandbox()
        box.write("cache/mod/file.go", text: "package x")
        chmod(box.path("cache/mod/file.go"), 0o444)
        chmod(box.path("cache/mod"), 0o555)
        chmod(box.path("cache"), 0o555)
        try Remover.remove(box.path("cache"), mode: .delete)
        #expect(!box.exists("cache"))
    }
}

@Suite struct FormatTests {
    @Test func formatsSizes() {
        #expect(ByteSize.format(0) == "0 B")
        #expect(ByteSize.format(999) == "999 B")
        #expect(ByteSize.format(1_000) == "1.00 KB")
        #expect(ByteSize.format(15_300_000) == "15.3 MB")
        #expect(ByteSize.format(413_000_000_000) == "413 GB")
        #expect(ByteSize.format(999_600) == "1.00 MB")
    }

    @Test func parsesSizes() {
        #expect(ByteSize.parse("500") == 500)
        #expect(ByteSize.parse("10k") == 10_000)
        #expect(ByteSize.parse("1.5GB") == 1_500_000_000)
        #expect(ByteSize.parse("2 MiB") == 2_097_152)
        #expect(ByteSize.parse("big") == nil)
        #expect(ByteSize.parse("10 parsecs") == nil)
    }

    @Test func parsesAges() {
        #expect(DurationText.parse("30d") == TimeInterval(2_592_000))
        #expect(DurationText.parse("2w") == TimeInterval(1_209_600))
        #expect(DurationText.parse("soon") == nil)
        #expect(DurationText.ago(3 * 86400) == "3 days ago")
        #expect(DurationText.ago(400 * 86400) == "13 months ago")
    }

    @Test func normalisesRoots() {
        #expect(PathUtil.dedupeRoots(["/a/b", "/a", "/c", "/a/b/c", "/c"]) == ["/a", "/c"])
        #expect(PathUtil.isSameOrInside("/a/bc", "/a/b") == false)
        #expect(PathUtil.isSameOrInside("/a/b/c", "/a/b"))
    }
}
