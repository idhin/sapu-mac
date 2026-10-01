import Darwin
import Foundation

struct PickerRow {
    enum Kind {
        /// Section title; not selectable.
        case header
        /// Something the user can tick.
        case item
        /// Extra information under an item or header; not selectable.
        case note
    }

    var kind: Kind
    var text: String
    /// Right-aligned on the row, typically a size.
    var trailing = ""
    var checked = false
    /// Rows of one section share a group number.
    var group = -1
    /// Added to the running total while the row is ticked.
    var bytes: Int64 = 0
}

/// A full-screen checklist: arrows to move, space to tick, return to confirm.
final class Picker {
    private let title: String
    private var rows: [PickerRow]
    private let initial: [Bool]
    private let verb: String
    /// Returns a message when ticking the row at this index is not allowed.
    private let veto: ((Int, [PickerRow]) -> String?)?
    /// Bytes the ticked rows stand for; defaults to the sum of their `bytes`.
    private let total: (([PickerRow]) -> Int64)?

    private var cursor = 0
    private var top = 0
    private var message = ""
    private var tty: Int32 = -1
    private var saved = termios()

    init(title: String, rows: [PickerRow], verb: String, veto: ((Int, [PickerRow]) -> String?)? = nil, total: (([PickerRow]) -> Int64)? = nil) {
        self.title = title
        self.rows = rows
        self.initial = rows.map(\.checked)
        self.verb = verb
        self.veto = veto
        self.total = total
    }

    /// Runs the picker. Returns the rows with their final ticks, or nil if the user backed out.
    func run() -> [PickerRow]? {
        guard let first = rows.firstIndex(where: { $0.kind == .item }) else { return rows }
        cursor = first
        tty = open("/dev/tty", O_RDWR)
        guard tty >= 0, tcgetattr(tty, &saved) == 0 else { return nil }

        var raw = saved
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG)
        withUnsafeMutableBytes(of: &raw.c_cc) { cc in
            cc[Int(VMIN)] = 0
            cc[Int(VTIME)] = 1
        }
        tcsetattr(tty, TCSAFLUSH, &raw)
        emit("\u{1B}[?1049h\u{1B}[?25l\u{1B}[?7l")
        defer {
            emit("\u{1B}[?7h\u{1B}[?25h\u{1B}[?1049l")
            tcsetattr(tty, TCSAFLUSH, &saved)
            close(tty)
        }

        var lastSize = (0, 0)
        var dirty = true
        while true {
            let size = (Term.width(fd: tty), Term.height(fd: tty))
            if size != lastSize {
                lastSize = size
                dirty = true
            }
            if dirty {
                render(width: size.0, height: size.1)
                dirty = false
            }
            guard let key = readKey() else { continue }
            dirty = true
            message = ""
            switch key {
            case .up: move(-1)
            case .down: move(1)
            case .pageUp: move(-(max(1, size.1 - 5)))
            case .pageDown: move(max(1, size.1 - 5))
            case .home: jump(toFirst: true)
            case .end: jump(toFirst: false)
            case .toggle: toggle(cursor)
            case .clear:
                for index in rows.indices where rows[index].kind == .item { rows[index].checked = false }
            case .reset:
                for index in rows.indices { rows[index].checked = initial[index] }
            case .confirm: return rows
            case .cancel: return nil
            case .other: dirty = false
            }
        }
    }

    // MARK: - Input

    private enum Key {
        case up, down, pageUp, pageDown, home, end, toggle, clear, reset, confirm, cancel, other
    }

    private func readByte() -> UInt8? {
        var byte: UInt8 = 0
        return read(tty, &byte, 1) == 1 ? byte : nil
    }

    private func readKey() -> Key? {
        guard let byte = readByte() else { return nil }
        switch byte {
        case 0x03, UInt8(ascii: "q"): return .cancel
        case 0x0d, 0x0a: return .confirm
        case UInt8(ascii: " "), UInt8(ascii: "x"): return .toggle
        case UInt8(ascii: "k"): return .up
        case UInt8(ascii: "j"): return .down
        case UInt8(ascii: "g"): return .home
        case UInt8(ascii: "G"): return .end
        case UInt8(ascii: "n"): return .clear
        case UInt8(ascii: "r"): return .reset
        case 0x1b:
            // A lone escape cancels; otherwise it starts an arrow or paging sequence.
            guard let next = readByte() else { return .cancel }
            guard next == UInt8(ascii: "[") || next == UInt8(ascii: "O"), let code = readByte() else { return .other }
            switch code {
            case UInt8(ascii: "A"): return .up
            case UInt8(ascii: "B"): return .down
            case UInt8(ascii: "H"): return .home
            case UInt8(ascii: "F"): return .end
            case UInt8(ascii: "5"): _ = readByte(); return .pageUp
            case UInt8(ascii: "6"): _ = readByte(); return .pageDown
            default: return .other
            }
        default:
            return .other
        }
    }

    private func move(_ delta: Int) {
        let step = delta < 0 ? -1 : 1
        var remaining = abs(delta)
        var position = cursor
        while remaining > 0 {
            var next = position + step
            while rows.indices.contains(next) && rows[next].kind != .item { next += step }
            guard rows.indices.contains(next) else { break }
            position = next
            remaining -= 1
        }
        cursor = position
    }

    private func jump(toFirst: Bool) {
        let target = toFirst ? rows.firstIndex { $0.kind == .item } : rows.lastIndex { $0.kind == .item }
        if let target { cursor = target }
    }

    private func toggle(_ index: Int) {
        if !rows[index].checked, let reason = veto?(index, rows) {
            message = reason
            return
        }
        rows[index].checked.toggle()
    }

    // MARK: - Drawing

    private func emit(_ text: String) {
        var data = Array(text.utf8)
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeMutableBytes { write(tty, $0.baseAddress! + offset, $0.count - offset) }
            if written <= 0 { break }
            offset += written
        }
    }

    private func render(width: Int, height: Int) {
        let bodyHeight = max(1, height - 4)
        // Keep the cursor in view, and show the section header above it when possible.
        if cursor < top { top = cursor }
        if cursor >= top + bodyHeight { top = cursor - bodyHeight + 1 }
        var header = cursor
        while header > 0 && rows[header].kind != .header { header -= 1 }
        if header < top && cursor - header < bodyHeight { top = header }

        let selected = rows.filter { $0.kind == .item && $0.checked }
        let bytes = total?(rows) ?? selected.reduce(0) { $0 + $1.bytes }
        var out = "\u{1B}[H"
        func line(_ text: String) { out += text + "\u{1B}[K\r\n" }

        line(title.middleTruncated(width).bold)
        line("\(verb): \(Format.plural(selected.count, "item")) · \(Format.size(bytes))".green)
        line("")
        for index in top..<min(rows.count, top + bodyHeight) {
            let row = rows[index]
            let trailing = row.trailing.isEmpty ? "" : "  " + row.trailing
            switch row.kind {
            case .header:
                line((row.text.middleTruncated(max(10, width - trailing.count)) + trailing).bold)
            case .note:
                line(("      " + row.text).middleTruncated(width - 1).dim)
            case .item:
                let pointer = index == cursor ? "❯" : " "
                let box = row.checked ? "[x]" : "[ ]"
                let room = max(10, width - 7 - trailing.count)
                var text = "\(pointer) \(box) " + row.text.middleTruncated(room).rightPadded(room) + trailing
                if row.checked { text = text.yellow }
                if index == cursor { text = text.bold }
                line(text)
            }
        }
        out += "\u{1B}[J"
        // Footer on the last line.
        let help = "↑↓ move · space tick · r reset · n none · return continue · q quit"
        let footer = (message.isEmpty ? help : message).middleTruncated(width - 1)
        out += "\u{1B}[\(height);1H" + (message.isEmpty ? footer.dim : footer.red) + "\u{1B}[K"
        emit(out)
    }
}
