import Darwin
import Foundation
import Testing
@testable import SapuCore

@Suite struct JunkTests {
    /// Runs the finder against a sandbox acting as the home folder.
    private func find(_ box: Sandbox, configure: (inout JunkOptions) -> Void = { _ in }) -> [JunkItem] {
        var options = JunkOptions()
        options.minSize = 1
        options.projectRoots = [box.root]
        options.activeWindow = 0
        configure(&options)
        // Installers in the real /Applications are the one thing found outside the sandbox.
        return JunkFinder(options: options, home: box.root).run().items.filter { $0.targets[0].hasPrefix(box.root) }
    }

    private func relative(_ box: Sandbox, _ item: JunkItem) -> String {
        String(item.targets[0].dropFirst(box.root.count + 1))
    }

    @Test func findsBuildArtifactsOnlyNextToTheirMarkers() {
        let box = Sandbox()
        box.write("Code/web/package.json", text: "{}")
        box.write("Code/web/package-lock.json", text: "{}")
        box.write("Code/web/node_modules/left-pad/index.js", seed: 1, size: 20_000)
        box.write("Code/web/.next/cache/blob", seed: 2, size: 20_000)
        box.write("Code/tool/Cargo.toml", text: "[package]")
        box.write("Code/tool/target/debug/tool", seed: 3, size: 20_000)
        box.write("Code/lib/Package.swift", text: "// swift-tools-version:5.9")
        box.write("Code/lib/.build/debug/lib.o", seed: 4, size: 20_000)
        // Same folder names without the marker file are just folders.
        box.write("Archive/target/notes.txt", seed: 5, size: 20_000)
        box.write("Archive/build/drawing.png", seed: 6, size: 20_000)
        box.write("Archive/node_modules/orphan/index.js", seed: 7, size: 20_000)

        let items = find(box).filter { $0.category == .projects }
        #expect(Set(items.map { relative(box, $0) }) == [
            "Code/web/node_modules", "Code/web/.next", "Code/tool/target", "Code/lib/.build",
        ])
        #expect(items.allSatisfy { $0.safety == .safe })
        #expect(items.first { $0.id == "rust-target" }?.note == "Restore: cargo build")
    }

    @Test func dependenciesWithoutALockfileNeedReview() {
        let box = Sandbox()
        box.write("pinned/package.json", text: "{}")
        box.write("pinned/yarn.lock", text: "")
        box.write("pinned/node_modules/a/index.js", seed: 1, size: 20_000)
        box.write("loose/package.json", text: "{}")
        box.write("loose/node_modules/a/index.js", seed: 1, size: 20_000)
        // A workspace package relies on the lockfile at the workspace root.
        box.write("mono/pnpm-lock.yaml", text: "")
        box.write("mono/packages/ui/package.json", text: "{}")
        box.write("mono/packages/ui/node_modules/a/index.js", seed: 1, size: 20_000)

        let safety = Dictionary(uniqueKeysWithValues: find(box).map { (relative(box, $0), $0.safety) })
        #expect(safety["pinned/node_modules"] == .safe)
        #expect(safety["loose/node_modules"] == .review)
        #expect(safety["mono/packages/ui/node_modules"] == .safe)
    }

    @Test func recentlyTouchedProjectsNeedReview() {
        let box = Sandbox()
        box.write("fresh/Cargo.toml", text: "[package]")
        box.write("fresh/target/debug/app", seed: 1, size: 20_000)
        box.write("stale/Cargo.toml", text: "[package]")
        box.write("stale/target/debug/app", seed: 1, size: 20_000)
        var old = [timeval(tv_sec: 1_500_000_000, tv_usec: 0), timeval(tv_sec: 1_500_000_000, tv_usec: 0)]
        utimes(box.path("stale/Cargo.toml"), &old)
        utimes(box.path("stale"), &old)

        let items = find(box) { $0.activeWindow = 7 * 86400 }
        #expect(items.first { relative(box, $0) == "fresh/target" }?.safety == .review)
        #expect(items.first { relative(box, $0) == "stale/target" }?.safety == .safe)

        let onlyOld = find(box) { $0.olderThan = 30 * 86400 }
        #expect(onlyOld.map { relative(box, $0) } == ["stale/target"])
    }

    @Test func reportsKnownCacheLocationsPerApp() {
        let box = Sandbox()
        box.write("Library/Caches/com.example.editor/data", seed: 1, size: 30_000)
        box.write("Library/Caches/Homebrew/downloads/pkg.tar.gz", seed: 2, size: 40_000)
        box.write("Library/Caches/com.apple.Safari/data", seed: 3, size: 50_000)
        box.write("Library/Developer/Xcode/DerivedData/App-abc/Build/app.o", seed: 4, size: 60_000)
        box.write("Library/Developer/Xcode/Archives/2024/App.xcarchive/Info.plist", seed: 5, size: 20_000)
        box.write(".npm/_cacache/content/blob", seed: 6, size: 20_000)
        box.write(".Trash/old.zip", seed: 7, size: 20_000)
        // Lives in Library, so the project search must not pick it up a second time.
        box.write("Library/Application Support/Tool/package.json", text: "{}")
        box.write("Library/Application Support/Tool/node_modules/x/index.js", seed: 8, size: 20_000)

        let items = find(box)
        let byTitle = Dictionary(uniqueKeysWithValues: items.map { ($0.title, $0) })
        #expect(byTitle["Homebrew downloads"]?.size ?? 0 >= 40_000)
        #expect(byTitle["Cache · com.example.editor"]?.safety == .safe)
        #expect(byTitle["Xcode DerivedData"]?.contentsOnly == true)
        #expect(byTitle["Xcode archives"]?.safety == .review)
        #expect(byTitle["npm cache"] != nil)
        #expect(byTitle["Trash"]?.safety == .review)
        // Apple's own caches are left to the system.
        #expect(!items.contains { $0.targets[0].contains("com.apple.Safari") })
        #expect(!items.contains { $0.category == .projects })
    }

    @Test func cleaningRemovesContentsButKeepsTheLocation() {
        let box = Sandbox()
        box.write("Library/Developer/Xcode/DerivedData/App-abc/Build/app.o", seed: 1, size: 60_000)
        box.write("Library/Developer/Xcode/DerivedData/Other-def/Build/app.o", seed: 2, size: 60_000)
        box.write("Code/tool/Cargo.toml", text: "[package]")
        box.write("Code/tool/target/debug/tool", seed: 3, size: 20_000)
        let items = find(box)
        let derived = items.first { $0.id == "xcode-derived-data" }!
        let target = items.first { $0.id == "rust-target" }!

        let preview = JunkCleaner.clean(derived, mode: .delete, dryRun: true)
        #expect(preview.removed == 2)
        #expect(box.exists("Library/Developer/Xcode/DerivedData/App-abc"))

        #expect(JunkCleaner.clean(derived, mode: .delete, dryRun: false).failures.isEmpty)
        #expect(box.exists("Library/Developer/Xcode/DerivedData"))
        #expect(!box.exists("Library/Developer/Xcode/DerivedData/App-abc"))

        #expect(JunkCleaner.clean(target, mode: .delete, dryRun: false).failures.isEmpty)
        #expect(!box.exists("Code/tool/target"))
        #expect(box.exists("Code/tool/Cargo.toml"))
    }

    @Test func reportOnlyItemsAreNeverRemoved() {
        let item = JunkItem(id: "docker", category: .large, title: "Docker", targets: ["/nonexistent"], contentsOnly: true,
                            size: 1, fileCount: 1, safety: .info, note: nil, lastUsed: nil, partial: false)
        #expect(JunkCleaner.clean(item, mode: .delete, dryRun: false).failures == ["report only"])
    }
}

@Suite struct BigTests {
    @Test func breaksDownByFolderAndListsLargestFiles() {
        let box = Sandbox()
        box.write("videos/a.mov", seed: 1, size: 800_000)
        box.write("videos/b.mov", seed: 2, size: 400_000)
        box.write("docs/report.pdf", seed: 3, size: 100_000)
        for index in 0..<5 { box.write("misc/tiny\(index).txt", seed: UInt64(10 + index), size: 100) }

        let tree = box.scan()
        let root = BigFinder.breakdown(tree, root: tree.roots[0], depth: 2, limit: 2)
        #expect(root.children.map(\.name) == ["videos", "docs"])
        #expect(root.omittedCount == 1)
        #expect(root.children[0].children.map(\.name) == ["a.mov", "b.mov"])
        #expect(root.size == root.children.reduce(0) { $0 + $1.size } + root.omittedSize)

        let files = BigFinder.largestFiles(tree, limit: 2)
        #expect(files.map(\.path) == [box.path("videos/a.mov"), box.path("videos/b.mov")])
    }
}
