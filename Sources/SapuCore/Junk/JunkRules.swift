import Foundation

public enum JunkSafety: String {
    /// Rebuilt or re-downloaded automatically; nothing of yours is lost.
    case safe
    /// Regenerable, but at a cost (long download, lost simulator state, ...). Never removed unless asked.
    case review
    /// Only reported. sapu never removes it; the note says how to reclaim the space properly.
    case info
}

public enum JunkCategory: String, CaseIterable {
    case projects = "Project build artifacts"
    case developer = "Developer tools"
    case packages = "Package manager caches"
    case system = "App caches & logs"
    case large = "Large app data"
    case trash = "Trash"
}

/// A folder inside a project that its build tool can recreate.
public struct ArtifactRule {
    public let id: String
    public let title: String
    /// Folder names this rule applies to.
    public let names: [String]
    /// Alternative to `names`: any folder starting with this.
    public var namePrefix: String?
    /// At least one of these must sit next to the folder (exact names).
    public var siblings: [String] = []
    /// ... or one entry next to it must end with one of these.
    public var siblingSuffixes: [String] = []
    /// Every one of these must sit next to the folder.
    public var allSiblings: [String] = []
    /// At least one of these must exist inside the folder.
    public var inside: [String] = []
    /// Files that pin exact versions. Without one nearby, a reinstall may not reproduce the folder.
    public var lockfiles: [String] = []
    /// Set when the folder may hold things its tool cannot recreate; the finding is then always
    /// marked "review", with this as the reason.
    public var caution: String?
    /// How the folder comes back.
    public let restore: String

    /// Set on a node's tag when the rule has lockfiles and none was found.
    static let unpinnedBit: UInt8 = 0x80

    /// True if one of the rule's lockfiles sits next to the folder or up to four levels above it
    /// (monorepos keep a single lockfile at the workspace root).
    func isPinned(in listing: DirListing) -> Bool {
        if lockfiles.isEmpty || lockfiles.contains(where: { listing.contains($0) }) { return true }
        var folder = listing.path
        for _ in 0..<4 {
            let parent = PathUtil.parent(folder)
            if parent == folder || parent == PathUtil.home { break }
            folder = parent
            if lockfiles.contains(where: { access(folder + "/" + $0, F_OK) == 0 }) { return true }
        }
        return false
    }

    func matches(index: Int, in listing: DirListing) -> Bool {
        if !allSiblings.allSatisfy({ listing.contains($0) }) { return false }
        if !siblings.isEmpty || !siblingSuffixes.isEmpty {
            let found = siblings.contains { listing.contains($0) } || siblingSuffixes.contains { listing.containsSuffix($0) }
            if !found { return false }
        }
        if !inside.isEmpty {
            let folder = listing.path + "/" + listing.name(index)
            if !inside.contains(where: { access(folder + "/" + $0, F_OK) == 0 }) { return false }
        }
        return true
    }

    public static let all: [ArtifactRule] = [
        ArtifactRule(id: "node_modules", title: "Node.js packages", names: ["node_modules"],
                     siblings: ["package.json"],
                     lockfiles: ["package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "bun.lock", "npm-shrinkwrap.json"],
                     restore: "npm / yarn / pnpm install"),
        ArtifactRule(id: "js-build", title: "JavaScript build cache",
                     names: [".next", ".nuxt", ".output", ".svelte-kit", ".turbo", ".parcel-cache", ".angular", ".docusaurus", ".expo"],
                     siblings: ["package.json"], restore: "next build of the project"),
        ArtifactRule(id: "rust-target", title: "Rust build output", names: ["target"],
                     siblings: ["Cargo.toml"], inside: [".rustc_info.json", "CACHEDIR.TAG", "debug", "release"], restore: "cargo build"),
        ArtifactRule(id: "rust-target", title: "Rust build output", names: ["target"],
                     inside: [".rustc_info.json"], restore: "cargo build"),
        ArtifactRule(id: "maven-target", title: "Maven build output", names: ["target"],
                     siblings: ["pom.xml"],
                     inside: ["classes", "test-classes", "maven-status", "maven-archiver", "generated-sources", "surefire-reports"],
                     restore: "mvn package"),
        ArtifactRule(id: "swiftpm-build", title: "SwiftPM build output", names: [".build"],
                     siblings: ["Package.swift"], restore: "swift build"),
        ArtifactRule(id: "xcode-build", title: "Xcode build folder", names: ["build", "DerivedData"],
                     siblingSuffixes: [".xcodeproj", ".xcworkspace"],
                     inside: ["XCBuildData", "Build", "Index.noindex", "ModuleCache.noindex", "SourcePackages", "info.plist",
                              "Debug", "Release", "Debug-iphoneos", "Release-iphoneos", "Debug-iphonesimulator", "Release-iphonesimulator"],
                     restore: "next Xcode build"),
        ArtifactRule(id: "cocoapods", title: "CocoaPods dependencies", names: ["Pods"],
                     siblings: ["Podfile"], lockfiles: ["Podfile.lock"], restore: "pod install"),
        ArtifactRule(id: "carthage", title: "Carthage dependencies", names: ["Carthage"],
                     siblings: ["Cartfile"], lockfiles: ["Cartfile.resolved"], restore: "carthage bootstrap"),
        // A folder merely called "build" could be anything; it has to look like the tool's output too.
        ArtifactRule(id: "gradle-build", title: "Gradle build output", names: ["build"],
                     siblings: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"],
                     inside: ["intermediates", "outputs", "generated", "tmp", "classes", "libs", "kotlin", "reports"],
                     restore: "gradle build"),
        ArtifactRule(id: "gradle-build", title: "Gradle build output", names: [".gradle", ".cxx"],
                     siblings: ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"], restore: "gradle build"),
        ArtifactRule(id: "flutter-build", title: "Flutter build output", names: ["build"],
                     siblings: ["pubspec.yaml"],
                     inside: ["app", "ios", "macos", "web", "linux", "windows", "flutter_assets", "native_assets", ".last_build_id"],
                     restore: "flutter pub get && flutter build"),
        ArtifactRule(id: "flutter-build", title: "Flutter build output", names: [".dart_tool"],
                     siblings: ["pubspec.yaml"], restore: "flutter pub get && flutter build"),
        ArtifactRule(id: "cmake-build", title: "CMake build folder", names: ["build"],
                     siblings: ["CMakeLists.txt"], inside: ["CMakeCache.txt"], restore: "cmake --build"),
        ArtifactRule(id: "cmake-build", title: "CMake build folder", names: [], namePrefix: "cmake-build-",
                     siblings: ["CMakeLists.txt"], restore: "cmake --build"),
        ArtifactRule(id: "python-venv", title: "Python virtual environment", names: [".venv", "venv", "env", "virtualenv"],
                     inside: ["pyvenv.cfg"],
                     caution: "Anything installed or saved in it by hand is not brought back by a reinstall",
                     restore: "python -m venv, then reinstall requirements"),
        ArtifactRule(id: "python-cache", title: "Python tool cache", names: [".mypy_cache", ".pytest_cache", ".ruff_cache", ".tox", ".nox"],
                     restore: "next run of the tool"),
        ArtifactRule(id: "php-vendor", title: "Composer dependencies", names: ["vendor"],
                     siblings: ["composer.json"], inside: ["autoload.php"], lockfiles: ["composer.lock"], restore: "composer install"),
        ArtifactRule(id: "dotnet-build", title: ".NET build output", names: ["obj"],
                     inside: ["project.assets.json"], restore: "dotnet build"),
        ArtifactRule(id: "dotnet-build", title: ".NET build output", names: ["bin"],
                     siblingSuffixes: [".csproj", ".fsproj", ".vbproj"], allSiblings: ["obj"], restore: "dotnet build"),
        ArtifactRule(id: "zig-build", title: "Zig build output", names: ["zig-cache", ".zig-cache", "zig-out"],
                     siblings: ["build.zig"], restore: "zig build"),
        ArtifactRule(id: "elixir-build", title: "Elixir build output", names: ["_build", "deps"],
                     siblings: ["mix.exs"], lockfiles: ["mix.lock"], restore: "mix deps.get && mix compile"),
        ArtifactRule(id: "haskell-build", title: "Haskell build output", names: [".stack-work", "dist-newstyle"],
                     siblings: ["stack.yaml", "cabal.project"], siblingSuffixes: [".cabal"], restore: "stack build / cabal build"),
        ArtifactRule(id: "terraform", title: "Terraform providers", names: [".terraform"],
                     restore: "terraform init"),
        ArtifactRule(id: "unity-cache", title: "Unity project cache", names: ["Library", "Temp", "Obj", "Logs"],
                     allSiblings: ["Assets", "ProjectSettings"], restore: "reopening the project in Unity"),
        ArtifactRule(id: "unreal-cache", title: "Unreal project cache", names: ["Intermediate", "DerivedDataCache"],
                     siblingSuffixes: [".uproject"], restore: "reopening the project in Unreal"),
        ArtifactRule(id: "godot-cache", title: "Godot project cache", names: [".godot"],
                     siblings: ["project.godot"], restore: "reopening the project in Godot"),
    ]

    /// Folder name → indexes of the rules that may apply.
    static let byName: [String: [Int]] = {
        var map: [String: [Int]] = [:]
        for (index, rule) in all.enumerated() {
            for name in rule.names { map[name, default: []].append(index) }
        }
        return map
    }()

    static let prefixed: [(prefix: String, index: Int)] = all.enumerated().compactMap { index, rule in
        rule.namePrefix.map { ($0, index) }
    }

    /// The node tag for entry `index` of `listing` if it is a build artifact: the rule's index
    /// plus one, with `unpinnedBit` set when no lockfile vouches for an identical reinstall.
    static func tag(index: Int, name: String, in listing: DirListing) -> UInt8? {
        var found: Int?
        if let candidates = byName[name] {
            found = candidates.first { all[$0].matches(index: index, in: listing) }
        }
        if found == nil {
            found = prefixed.first { name.hasPrefix($0.prefix) && all[$0.index].matches(index: index, in: listing) }?.index
        }
        guard let rule = found else { return nil }
        return UInt8(rule + 1) | (all[rule].isPinned(in: listing) ? 0 : unpinnedBit)
    }

    /// The rule a node tag stands for, and whether a lockfile was missing.
    static func decode(tag: UInt8) -> (rule: ArtifactRule, unpinned: Bool)? {
        let index = Int(tag & ~unpinnedBit) - 1
        guard all.indices.contains(index) else { return nil }
        return (all[index], tag & unpinnedBit != 0)
    }
}

/// A well-known place where caches and other regenerable data pile up.
struct KnownLocation {
    enum Mode {
        /// One item covering everything inside the listed folders.
        case contents
        /// One item per entry of the folder (per-app caches).
        case children
        /// The paths themselves are the junk (an installer app, say).
        case item
    }

    let id: String
    let category: JunkCategory
    let title: String
    let paths: [String]
    let safety: JunkSafety
    let note: String?
    var mode: Mode = .contents

    struct Label {
        let title: String
        var safety: JunkSafety = .safe
        var note: String?
    }

    /// Friendlier names for the cache folders developers most often find to be huge.
    static let cacheLabels: [String: Label] = [
        "Homebrew": Label(title: "Homebrew downloads", note: "Gentler: brew cleanup -s"),
        "pip": Label(title: "pip cache"),
        "Yarn": Label(title: "Yarn cache"),
        "pnpm": Label(title: "pnpm cache"),
        "CocoaPods": Label(title: "CocoaPods cache"),
        "go-build": Label(title: "Go build cache"),
        "org.swift.swiftpm": Label(title: "SwiftPM cache"),
        "com.apple.dt.Xcode": Label(title: "Xcode cache"),
        "ms-playwright": Label(title: "Playwright browsers", note: "Restore: npx playwright install"),
        "Cypress": Label(title: "Cypress binaries", note: "Restore: npx cypress install"),
        "puppeteer": Label(title: "Puppeteer browsers"),
        "Google": Label(title: "Google Chrome cache"),
        "Firefox": Label(title: "Firefox cache"),
        "BraveSoftware": Label(title: "Brave cache"),
        "com.spotify.client": Label(title: "Spotify cache"),
        "JetBrains": Label(title: "JetBrains IDE caches", safety: .review, note: "Includes the IDEs' Local History"),
        "rclone": Label(title: "rclone cache", safety: .review, note: "May hold files that were not uploaded yet"),
        "pypoetry": Label(title: "Poetry cache"),
        "uv": Label(title: "uv cache"),
        "deno": Label(title: "Deno cache"),
        "node-gyp": Label(title: "node-gyp headers"),
        "electron": Label(title: "Electron downloads"),
        "typescript": Label(title: "TypeScript type cache"),
        "pre-commit": Label(title: "pre-commit environments"),
        "bazel": Label(title: "Bazel cache"),
        "ccache": Label(title: "ccache"),
        "sccache": Label(title: "sccache"),
        "huggingface": Label(title: "Hugging Face models", safety: .review, note: "Downloaded models and datasets"),
        "torch": Label(title: "PyTorch hub models", safety: .review, note: "Downloaded model weights"),
        "whisper": Label(title: "Whisper models", safety: .review, note: "Downloaded model weights"),
        "lm-studio": Label(title: "LM Studio models", safety: .review, note: "Downloaded model weights"),
    ]

    static func all(home: String) -> [KnownLocation] {
        func h(_ relative: String) -> String { home + "/" + relative }
        var locations: [KnownLocation] = [
            // Per-app caches
            KnownLocation(id: "app-cache", category: .system, title: "Cache", paths: [h("Library/Caches")],
                          safety: .safe, note: "Apps rebuild their caches when needed", mode: .children),
            KnownLocation(id: "tool-cache", category: .packages, title: "Cache", paths: [h(".cache")],
                          safety: .safe, note: "Tools rebuild their caches when needed", mode: .children),
            KnownLocation(id: "logs", category: .system, title: "Log files", paths: [h("Library/Logs")],
                          safety: .safe, note: "Old diagnostic logs"),

            // Xcode
            KnownLocation(id: "xcode-derived-data", category: .developer, title: "Xcode DerivedData",
                          paths: [h("Library/Developer/Xcode/DerivedData")], safety: .safe, note: "Rebuilt on the next Xcode build"),
            KnownLocation(id: "xcode-device-support", category: .developer, title: "Xcode device support",
                          paths: ["iOS", "watchOS", "tvOS", "xrOS"].map { h("Library/Developer/Xcode/\($0) DeviceSupport") },
                          safety: .safe, note: "Re-created when a device is connected"),
            KnownLocation(id: "xcode-misc", category: .developer, title: "Xcode previews & documentation cache",
                          paths: [h("Library/Developer/Xcode/UserData/Previews"), h("Library/Developer/Xcode/DocumentationCache"),
                                  h("Library/Developer/XCTestDevices")],
                          safety: .safe, note: "Rebuilt by Xcode"),
            KnownLocation(id: "xcode-archives", category: .developer, title: "Xcode archives",
                          paths: [h("Library/Developer/Xcode/Archives")], safety: .review,
                          note: "Needed to re-export or symbolicate builds you shipped"),
            KnownLocation(id: "simulator-caches", category: .developer, title: "Simulator caches",
                          paths: [h("Library/Developer/CoreSimulator/Caches")], safety: .safe, note: "Rebuilt by the Simulator"),
            KnownLocation(id: "simulator-devices", category: .developer, title: "Simulator devices",
                          paths: [h("Library/Developer/CoreSimulator/Devices")], safety: .review,
                          note: "Simulators with their apps and data. Gentler: xcrun simctl delete unavailable"),
            KnownLocation(id: "simulator-runtimes", category: .developer, title: "Simulator runtimes",
                          paths: ["/Library/Developer/CoreSimulator/Images"], safety: .info,
                          note: "Remove in Xcode › Settings › Components, or: xcrun simctl runtime delete"),

            // Package managers
            KnownLocation(id: "npm-cache", category: .packages, title: "npm cache",
                          paths: [h(".npm/_cacache"), h(".npm/_npx")], safety: .safe, note: "npm re-downloads packages when needed"),
            KnownLocation(id: "yarn-cache", category: .packages, title: "Yarn Berry cache",
                          paths: [h(".yarn/berry/cache")], safety: .safe, note: "Yarn re-downloads packages when needed"),
            KnownLocation(id: "pnpm-store", category: .packages, title: "pnpm store",
                          paths: [h("Library/pnpm/store")], safety: .review,
                          note: "Shared by every pnpm project. Gentler: pnpm store prune"),
            KnownLocation(id: "bun-cache", category: .packages, title: "Bun cache",
                          paths: [h(".bun/install/cache")], safety: .safe, note: "Bun re-downloads packages when needed"),
            KnownLocation(id: "cargo-cache", category: .packages, title: "Cargo registry & git cache",
                          paths: [h(".cargo/registry"), h(".cargo/git")], safety: .safe, note: "Cargo re-downloads crates when needed"),
            KnownLocation(id: "go-modules", category: .packages, title: "Go module cache",
                          paths: [h("go/pkg/mod")], safety: .safe, note: "Go re-downloads modules when needed"),
            KnownLocation(id: "gradle-cache", category: .packages, title: "Gradle caches",
                          paths: [h(".gradle/caches"), h(".gradle/wrapper/dists"), h(".gradle/daemon")],
                          safety: .safe, note: "Gradle re-downloads dependencies when needed"),
            KnownLocation(id: "maven-repo", category: .packages, title: "Maven local repository",
                          paths: [h(".m2/repository")], safety: .review,
                          note: "Re-downloaded when needed, except artifacts you installed locally (mvn install)"),
            KnownLocation(id: "cocoapods-repos", category: .packages, title: "CocoaPods spec repos",
                          paths: [h(".cocoapods/repos")], safety: .safe, note: "Restore: pod repo update"),
            KnownLocation(id: "pub-cache", category: .packages, title: "Dart & Flutter pub cache",
                          paths: [h(".pub-cache")], safety: .review, note: "Includes globally activated Dart tools"),
            KnownLocation(id: "conda-pkgs", category: .packages, title: "Conda package cache",
                          paths: ["miniconda3", "anaconda3", "miniforge3", "mambaforge"].map { h("\($0)/pkgs") },
                          safety: .review, note: "Gentler: conda clean --all"),
            KnownLocation(id: "version-manager-cache", category: .packages, title: "nvm & pyenv download cache",
                          paths: [h(".nvm/.cache"), h(".pyenv/cache")], safety: .safe, note: "Downloaded installers"),

            // Large data worth knowing about
            KnownLocation(id: "android-avd", category: .large, title: "Android emulators",
                          paths: [h(".android/avd")], safety: .review, note: "Virtual devices with their data"),
            KnownLocation(id: "android-system-images", category: .large, title: "Android system images",
                          paths: [h("Library/Android/sdk/system-images")], safety: .review, note: "Re-download in Android Studio's SDK Manager"),
            KnownLocation(id: "ios-backups", category: .large, title: "iPhone & iPad backups",
                          paths: [h("Library/Application Support/MobileSync/Backup")], safety: .review,
                          note: "Local device backups. Manage in Finder › your device › Manage Backups"),
            KnownLocation(id: "ios-updates", category: .large, title: "iOS update files",
                          paths: [h("Library/iTunes/iPhone Software Updates"), h("Library/iTunes/iPad Software Updates")],
                          safety: .safe, note: "Already-installed firmware downloads"),
            KnownLocation(id: "ollama-models", category: .large, title: "Ollama models",
                          paths: [h(".ollama/models")], safety: .review, note: "Gentler: ollama rm <model>"),
            KnownLocation(id: "lmstudio-models", category: .large, title: "LM Studio models",
                          paths: [h(".lmstudio/models")], safety: .review, note: "Downloaded model weights"),
            KnownLocation(id: "docker", category: .large, title: "Docker disk image",
                          paths: [h("Library/Containers/com.docker.docker/Data/vms")], safety: .info,
                          note: "Reclaim with: docker system prune -a --volumes"),
            KnownLocation(id: "orbstack", category: .large, title: "OrbStack data",
                          paths: [h("Library/Group Containers/HUAQ24HBR6.dev.orbstack/data"), h(".orbstack")], safety: .info,
                          note: "Reclaim with: docker system prune -a --volumes"),
            KnownLocation(id: "colima", category: .large, title: "Colima & Lima VMs",
                          paths: [h(".colima"), h(".lima")], safety: .info, note: "Reclaim with: colima delete, or docker system prune"),

            KnownLocation(id: "trash", category: .trash, title: "Trash", paths: [h(".Trash")],
                          safety: .review, note: "Items you already threw away. Emptying it is permanent"),
        ]

        // Chromium-based desktop apps keep sizeable caches next to their settings.
        let electronApps = ["Code": "VS Code", "Cursor": "Cursor", "Windsurf": "Windsurf", "Slack": "Slack", "discord": "Discord",
                            "Microsoft Teams": "Microsoft Teams", "Notion": "Notion", "Figma": "Figma", "Postman": "Postman",
                            "Claude": "Claude", "obsidian": "Obsidian", "Google/Chrome/Default": "Chrome profile"]
        let electronFolders = ["Cache", "Code Cache", "GPUCache", "CachedData", "CachedExtensionVSIXs", "Service Worker/CacheStorage", "logs"]
        for (folder, name) in electronApps.sorted(by: { $0.key < $1.key }) {
            locations.append(KnownLocation(
                id: "app-cache", category: .system, title: "Cache · \(name)",
                paths: electronFolders.map { h("Library/Application Support/\(folder)/\($0)") },
                safety: .safe, note: "Rebuilt by the app; quit it first for a clean result"
            ))
        }
        return locations
    }
}
