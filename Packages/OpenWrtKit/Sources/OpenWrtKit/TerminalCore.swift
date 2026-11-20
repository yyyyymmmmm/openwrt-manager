import Foundation

/// The terminal's screen model: a fixed-size character grid with SGR
/// attributes and a bounded scrollback, fed by a VT100/ANSI escape parser.
/// This is the testable core of the phase-3 native terminal (spec 0A:
/// the SSH transport plugs into this; no web terminal anywhere).
public struct TerminalCell: Equatable, Sendable {
    public var character: Character = " "
    public var bold = false
    public var underline = false
    public var inverse = false
    public var foreground: Int? = nil // ANSI 30-37 / 90-97 palette index
    public var background: Int? = nil
    public init() {}
}

public struct TerminalScreen: Sendable {
    public let columns: Int
    public let rows: Int
    public private(set) var grid: [[TerminalCell]]
    public private(set) var scrollback: [[TerminalCell]] = []
    public let scrollbackLimit: Int
    public private(set) var cursorRow = 0
    public private(set) var cursorColumn = 0
    private var current = TerminalCell()
    private var pendingWrap = false

    public init(columns: Int = 80, rows: Int = 24, scrollbackLimit: Int = 1000) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        self.scrollbackLimit = scrollbackLimit
        self.grid = Array(repeating: Array(repeating: TerminalCell(), count: max(1, columns)), count: max(1, rows))
    }

    public func lineText(_ row: Int) -> String {
        String(grid[row].map(\.character)).trimmingCharacters(in: .whitespaces)
    }

    public var visibleText: String {
        (0..<rows).map { lineText($0) }.joined(separator: "\n")
    }

    mutating func putCharacter(_ character: Character) {
        if pendingWrap {
            cursorColumn = 0
            advanceLine()
            pendingWrap = false
        }
        var cell = current
        cell.character = character
        grid[cursorRow][cursorColumn] = cell
        if cursorColumn == columns - 1 { pendingWrap = true }
        else { cursorColumn += 1 }
    }

    mutating func carriageReturn() {
        cursorColumn = 0
        pendingWrap = false
    }

    mutating func lineFeed() {
        pendingWrap = false
        advanceLine()
    }

    mutating func backspace() {
        pendingWrap = false
        if cursorColumn > 0 { cursorColumn -= 1 }
    }

    mutating func tab() {
        pendingWrap = false
        cursorColumn = min(columns - 1, (cursorColumn / 8 + 1) * 8)
    }

    private mutating func advanceLine() {
        if cursorRow == rows - 1 {
            scrollback.append(grid[0])
            if scrollback.count > scrollbackLimit { scrollback.removeFirst(scrollback.count - scrollbackLimit) }
            grid.removeFirst()
            grid.append(Array(repeating: TerminalCell(), count: columns))
        } else {
            cursorRow += 1
        }
    }

    mutating func moveCursor(row: Int, column: Int) {
        cursorRow = min(max(0, row), rows - 1)
        cursorColumn = min(max(0, column), columns - 1)
        pendingWrap = false
    }

    mutating func moveCursorBy(rows deltaRows: Int, columns deltaColumns: Int) {
        moveCursor(row: cursorRow + deltaRows, column: cursorColumn + deltaColumns)
    }

    mutating func eraseInDisplay(_ mode: Int) {
        switch mode {
        case 0:
            eraseInLine(0)
            for row in (cursorRow + 1)..<rows { grid[row] = blankLine() }
        case 1:
            eraseInLine(1)
            for row in 0..<cursorRow { grid[row] = blankLine() }
        default:
            for row in 0..<rows { grid[row] = blankLine() }
        }
    }

    mutating func eraseInLine(_ mode: Int) {
        switch mode {
        case 0:
            for column in cursorColumn..<columns { grid[cursorRow][column] = TerminalCell() }
        case 1:
            for column in 0...cursorColumn { grid[cursorRow][column] = TerminalCell() }
        default:
            grid[cursorRow] = blankLine()
        }
    }

    mutating func applySGR(_ parameters: [Int]) {
        let params = parameters.isEmpty ? [0] : parameters
        var index = 0
        while index < params.count {
            let code = params[index]
            switch code {
            case 0: current = TerminalCell()
            case 1: current.bold = true
            case 4: current.underline = true
            case 7: current.inverse = true
            case 22: current.bold = false
            case 24: current.underline = false
            case 27: current.inverse = false
            case 30...37: current.foreground = code - 30
            case 39: current.foreground = nil
            case 40...47: current.background = code - 40
            case 49: current.background = nil
            case 90...97: current.foreground = code - 90 + 8
            case 100...107: current.background = code - 100 + 8
            case 38, 48:
                // Extended colors (256-palette / RGB): consume the
                // operands; the palette index is kept for 256-color form.
                if index + 2 < params.count, params[index + 1] == 5 {
                    if code == 38 { current.foreground = params[index + 2] }
                    else { current.background = params[index + 2] }
                    index += 2
                } else if index + 4 < params.count, params[index + 1] == 2 {
                    index += 4
                }
            default: break
            }
            index += 1
        }
    }

    private func blankLine() -> [TerminalCell] {
        Array(repeating: TerminalCell(), count: columns)
    }
}

/// Streaming parser: bytes in, screen updates out. Handles CSI sequences,
/// OSC strings (consumed, not rendered), charset switches and the common
/// control characters. UTF-8 is decoded across chunk boundaries.
public struct TerminalParser: Sendable {
    public private(set) var screen: TerminalScreen
    private var state: State = .ground
    private var csiParameters = ""
    private var utf8Remainder = Data()

    private enum State { case ground, escape, csi, osc, oscEscape, charset }

    public init(columns: Int = 80, rows: Int = 24) {
        screen = TerminalScreen(columns: columns, rows: rows)
    }

    public mutating func feed(_ data: Data) {
        var bytes = utf8Remainder + data
        // Hold back a trailing incomplete UTF-8 sequence for the next chunk.
        var validLength = bytes.count
        if validLength > 0 {
            var back = 0
            while back < 3, back < validLength {
                let byte = bytes[bytes.count - 1 - back]
                if byte & 0x80 == 0 { break }
                if byte & 0xC0 == 0xC0 {
                    let needed = byte & 0xE0 == 0xC0 ? 2 : byte & 0xF0 == 0xE0 ? 3 : 4
                    if back + 1 < needed { validLength = bytes.count - back - 1 }
                    break
                }
                back += 1
            }
        }
        utf8Remainder = Data(bytes.suffix(bytes.count - validLength))
        bytes = bytes.prefix(validLength)
        // Iterate scalars, not Characters: "\r\n" is a single grapheme
        // cluster but two terminal control characters.
        for scalar in String(decoding: bytes, as: UTF8.self).unicodeScalars {
            consume(Character(scalar))
        }
    }

    private mutating func consume(_ character: Character) {
        switch state {
        case .ground:
            switch character {
            case "\u{1B}": state = .escape
            case "\r": screen.carriageReturn()
            case "\n", "\u{0B}", "\u{0C}": screen.lineFeed()
            case "\u{08}": screen.backspace()
            case "\t": screen.tab()
            case "\u{07}", "\u{00}": break
            default:
                if character.unicodeScalars.count == 1,
                   let scalar = character.unicodeScalars.first, scalar.value < 0x20 { break }
                screen.putCharacter(character)
            }
        case .escape:
            switch character {
            case "[": state = .csi; csiParameters = ""
            case "]": state = .osc
            case "(", ")", "*", "+": state = .charset
            case "7": state = .ground
            case "8": state = .ground
            case "c": screen = TerminalScreen(columns: screen.columns, rows: screen.rows); state = .ground
            default: state = .ground
            }
        case .charset:
            state = .ground
        case .osc:
            if character == "\u{07}" { state = .ground }
            else if character == "\u{1B}" { state = .oscEscape }
        case .oscEscape:
            state = character == "\\" ? .ground : .osc
        case .csi:
            if let scalar = character.unicodeScalars.first, (0x40...0x7E).contains(scalar.value) {
                executeCSI(final: character, parameters: csiParameters)
                state = .ground
            } else {
                csiParameters.append(character)
            }
        }
    }

    private mutating func executeCSI(final: Character, parameters raw: String) {
        let isPrivate = raw.hasPrefix("?") || raw.hasPrefix(">")
        let numbers = raw.drop(while: { $0 == "?" || $0 == ">" })
            .split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0) ?? 0 }
        func param(_ index: Int, default fallback: Int) -> Int {
            index < numbers.count && numbers[index] != 0 ? numbers[index] : fallback
        }
        guard !isPrivate else { return }
        switch final {
        case "A": screen.moveCursorBy(rows: -param(0, default: 1), columns: 0)
        case "B": screen.moveCursorBy(rows: param(0, default: 1), columns: 0)
        case "C": screen.moveCursorBy(rows: 0, columns: param(0, default: 1))
        case "D": screen.moveCursorBy(rows: 0, columns: -param(0, default: 1))
        case "E": screen.moveCursorBy(rows: param(0, default: 1), columns: 0); screen.carriageReturn()
        case "F": screen.moveCursorBy(rows: -param(0, default: 1), columns: 0); screen.carriageReturn()
        case "G": screen.moveCursor(row: screen.cursorRow, column: param(0, default: 1) - 1)
        case "H", "f": screen.moveCursor(row: param(0, default: 1) - 1, column: param(1, default: 1) - 1)
        case "J": screen.eraseInDisplay(numbers.first ?? 0)
        case "K": screen.eraseInLine(numbers.first ?? 0)
        case "m": screen.applySGR(numbers)
        case "d": screen.moveCursor(row: param(0, default: 1) - 1, column: screen.cursorColumn)
        default: break
        }
    }
}

/// Encodes user input for the SSH channel: plain text passes through as
/// UTF-8; named keys become their VT sequences.
public enum TerminalInput {
    public enum Key: Sendable {
        case enter, tab, backspace, escape
        case arrowUp, arrowDown, arrowLeft, arrowRight
        case home, end, pageUp, pageDown, delete
        case control(Character)
    }

    public static func data(for key: Key) -> Data {
        switch key {
        case .enter: return Data("\r".utf8)
        case .tab: return Data("\t".utf8)
        case .backspace: return Data([0x7F])
        case .escape: return Data([0x1B])
        case .arrowUp: return Data("\u{1B}[A".utf8)
        case .arrowDown: return Data("\u{1B}[B".utf8)
        case .arrowRight: return Data("\u{1B}[C".utf8)
        case .arrowLeft: return Data("\u{1B}[D".utf8)
        case .home: return Data("\u{1B}[H".utf8)
        case .end: return Data("\u{1B}[F".utf8)
        case .pageUp: return Data("\u{1B}[5~".utf8)
        case .pageDown: return Data("\u{1B}[6~".utf8)
        case .delete: return Data("\u{1B}[3~".utf8)
        case .control(let character):
            guard let scalar = character.uppercased().unicodeScalars.first,
                  (0x40...0x5F).contains(scalar.value) else { return Data() }
            return Data([UInt8(scalar.value - 0x40)])
        }
    }
}
