import Darwin
import Foundation
import SapuCore

enum Term {
    static let stdoutIsTTY = isatty(STDOUT_FILENO) == 1
    static let stderrIsTTY = isatty(STDERR_FILENO) == 1
    static let stdinIsTTY = isatty(STDIN_FILENO) == 1

    static var colorEnabled: Bool = {
        let environment = ProcessInfo.processInfo.environment
        if environment["NO_COLOR"] != nil { return false }
        if environment["TERM"] == "dumb" { return false }
        return stdoutIsTTY
    }()

    /// Width of the terminal, or a sensible default when output is piped.
    static func width(fd: Int32 = STDOUT_FILENO) -> Int {
        var size = winsize()
        for candidate in [fd, STDERR_FILENO, STDIN_FILENO] {
            if ioctl(candidate, TIOCGWINSZ, &size) == 0 && size.ws_col > 0 { return Int(size.ws_col) }
        }
        return 100
    }

    static func height(fd: Int32) -> Int {
        var size = winsize()
        return ioctl(fd, TIOCGWINSZ, &size) == 0 && size.ws_row > 0 ? Int(size.ws_row) : 24
    }

    static func error(_ message: String) {
        FileHandle.standardError.write(Data(("sapu: " + message + "\n").utf8))
    }

    /// Asks a yes/no question on the terminal. Anything but "y" or "yes" is a no.
    static func confirm(_ question: String) -> Bool {
        guard stdinIsTTY else { return false }
        print(question + " [y/N] ", terminator: "")
        fflush(stdout)
        guard let answer = readLine() else { return false }
        return ["y", "yes"].contains(answer.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// Asks the user to pick one of several single-letter choices. Returns nil on anything else.
    static func choose(_ question: String, among choices: [Character]) -> Character? {
        guard stdinIsTTY else { return nil }
        print(question + " ", terminator: "")
        fflush(stdout)
        guard let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased(), let first = answer.first, answer.count == 1 else { return nil }
        return choices.contains(first) ? first : nil
    }
}

extension String {
    private func wrapped(_ code: String) -> String {
        Term.colorEnabled ? "\u{1B}[\(code)m\(self)\u{1B}[0m" : self
    }

    var bold: String { wrapped("1") }
    var dim: String { wrapped("2") }
    var red: String { wrapped("31") }
    var green: String { wrapped("32") }
    var yellow: String { wrapped("33") }
    var blue: String { wrapped("34") }
    var cyan: String { wrapped("36") }

    /// Pads on the left to `width` visible characters.
    func leftPadded(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }

    func rightPadded(_ width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }

    /// Shortens to `width` characters by cutting out the middle: `~/Projects/…/src/main.c`.
    func middleTruncated(_ width: Int) -> String {
        guard count > width, width > 4 else { return self }
        let head = (width - 1) / 3
        let tail = width - 1 - head
        return String(prefix(head)) + "…" + String(suffix(tail))
    }
}

enum Format {
    private static let grouping: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        formatter.usesGroupingSeparator = true
        return formatter
    }()

    static func count(_ value: Int) -> String {
        grouping.string(from: NSNumber(value: value)) ?? String(value)
    }

    static func size(_ bytes: Int64) -> String { ByteSize.format(bytes) }

    static func path(_ path: String) -> String { PathUtil.abbreviate(path) }

    static func seconds(_ interval: TimeInterval) -> String {
        interval < 10 ? String(format: "%.1fs", interval) : interval < 90 ? "\(Int(interval))s" : "\(Int(interval) / 60)m \(Int(interval) % 60)s"
    }

    static func plural(_ value: Int, _ noun: String) -> String {
        "\(count(value)) \(noun)\(value == 1 ? "" : "s")"
    }

    /// A fixed-width bar such as `████████░░░░`.
    static func bar(fraction: Double, width: Int) -> String {
        let filled = max(0, min(width, Int((fraction * Double(width)).rounded())))
        return String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
    }

    static func json(_ object: Any) -> String {
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: options) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// A one-line live status on stderr while a scan runs. Silent when stderr is not a terminal.
final class Spinner {
    private let progress: ScanProgress
    private let lock = NSLock()
    private var running = false
    private var thread: Thread?
    private let done = DispatchSemaphore(value: 0)
    private static let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    init(_ progress: ScanProgress) {
        self.progress = progress
    }

    private static func describe(_ state: ScanProgress.Snapshot) -> String {
        switch state.phase {
        case "scan", "":
            return "Scanning  \(Format.count(state.items)) items  \(Format.path(state.path))"
        case "structure": return "Comparing folder structures"
        case "select": return "Choosing what needs a closer look"
        case "sample": return "Sampling files  \(Format.count(Int(state.done))) / \(Format.count(Int(state.total)))"
        case "hash": return "Comparing contents  \(Format.size(state.done)) / \(Format.size(state.total))"
        case "folders": return "Matching folders"
        case "group": return "Grouping duplicates"
        case "measure": return "Measuring what can be freed  \(state.done) / \(state.total)"
        default: return state.phase
        }
    }

    func start() {
        guard Term.stderrIsTTY else { return }
        running = true
        let thread = Thread { [self] in
            var frame = 0
            while true {
                lock.lock()
                let active = running
                lock.unlock()
                if !active { break }
                let width = Term.width(fd: STDERR_FILENO)
                let text = Spinner.describe(progress.snapshot).middleTruncated(max(20, width - 4))
                FileHandle.standardError.write(Data("\r\u{1B}[2K\(Spinner.frames[frame % Spinner.frames.count]) \(text)".utf8))
                frame += 1
                Thread.sleep(forTimeInterval: 0.1)
            }
            FileHandle.standardError.write(Data("\r\u{1B}[2K".utf8))
            done.signal()
        }
        self.thread = thread
        thread.start()
    }

    func stop() {
        guard thread != nil else { return }
        lock.lock()
        running = false
        lock.unlock()
        done.wait()
        thread = nil
    }
}
