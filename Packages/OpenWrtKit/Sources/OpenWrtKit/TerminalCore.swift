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
    /// True for the trailing half of a wide (wcwidth 2) character: the
    /// cell carries no glyph of its own and text extraction skips it,
    /// so a CJK character occupies exactly the two columns a real
    /// terminal gives it (package D, audit F9).
    public var isWideContinuation = false
    public init() {}
}

/// wcwidth(3) for the terminal grid: East-Asian wide and fullwidth
/// characters take two columns, combining marks and zero-width
/// characters take none, everything else takes one. This is the same
/// table shape xterm and every mature terminal (Termius, Blink) lay
/// their grids out with; without it CJK output overwrites itself.
public enum TerminalCharWidth {
    public static func width(of character: Character) -> Int {
        var sawWide = false
        var sawPrintable = false
        for scalar in character.unicodeScalars {
            switch width(ofScalar: scalar) {
            case 2: sawWide = true; sawPrintable = true
            case 1: sawPrintable = true
            default: break
            }
        }
        if sawWide { return 2 }
        return sawPrintable ? 1 : 0
    }

    public static func width(ofScalar scalar: Unicode.Scalar) -> Int {
        let value = scalar.value
        if value < 0x20 || (0x7F..<0xA0).contains(value) { return 0 }
        if value == 0x00AD { return 1 }
        // Zero-width: combining marks (by general category), joiners,
        // variation selectors and the combining-diacritic blocks.
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark:
            return 0
        case .spacingMark:
            // Indic spacing vowel signs are zero-width in wcwidth's
            // table; other spacing marks keep their column.
            if (0x0900...0x097F).contains(value) { return 0 }
        default: break
        }
        if (0x200B...0x200F).contains(value) || (0xFE00...0xFE0F).contains(value)
            || (0xFE20...0xFE2F).contains(value) || value == 0x2060 { return 0 }
        if isWide(value) { return 2 }
        return 1
    }

    private static func isWide(_ value: UInt32) -> Bool {
        switch value {
        case 0x1100...0x115F, 0x2329...0x232A, 0x2E80...0x303E,
             0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
             0xFE10...0xFE19, 0xFE30...0xFE6F, 0xFF00...0xFF60,
             0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F900...0x1F9FF,
             0x1FA70...0x1FAFF, 0x20000...0x2FFFD, 0x30000...0x3FFFD:
            return true
        default:
            return false
        }
    }
}

/// Derives the terminal grid from a view size and the monospace
/// cell metrics — the geometry every resize event (rotation, split
/// view, pinch-to-zoom the font) is computed with. Clamped so a
/// degenerate layout can never ask the shell for a 0-column PTY.
public enum TerminalGeometry {
    public static func gridSize(viewWidth: Double, viewHeight: Double,
                                cellWidth: Double, cellHeight: Double) -> (columns: Int, rows: Int) {
        guard cellWidth > 0, cellHeight > 0, viewWidth > 0, viewHeight > 0 else { return (80, 24) }
        let columns = Int(viewWidth / cellWidth)
        let rows = Int(viewHeight / cellHeight)
        return (min(max(columns, 20), 500), min(max(rows, 5), 200))
    }
}

public struct TerminalScreen: Sendable {
    public private(set) var columns: Int
    public private(set) var rows: Int
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
        Self.text(forRow: grid[row])
    }

    /// The printable text of one grid row: wide-character continuation
    /// cells contribute nothing, so the string matches what a real
    /// terminal shows rather than double-spacing every CJK glyph.
    public static func text(forRow cells: [TerminalCell]) -> String {
        String(cells.filter { !$0.isWideContinuation }.map(\.character))
            .trimmingCharacters(in: .whitespaces)
    }

    public var visibleText: String {
        (0..<rows).map { lineText($0) }.joined(separator: "\n")
    }

    mutating func putCharacter(_ character: Character) {
        let width = TerminalCharWidth.width(of: character)
        if width == 0 {
            appendCombining(character)
            return
        }
        if pendingWrap {
            cursorColumn = 0
            advanceLine()
            pendingWrap = false
        }
        if width == 2, columns >= 2 {
            if cursorColumn == columns - 1 {
                // No room for the second half on this line: blank the
                // last cell and place the glyph at the next line start,
                // the way xterm handles a wide char at the right edge.
                grid[cursorRow][cursorColumn] = blankCell()
                cursorColumn = 0
                advanceLine()
            }
            var cell = current
            cell.character = character
            cell.isWideContinuation = false
            grid[cursorRow][cursorColumn] = cell
            var continuation = current
            continuation.character = " "
            continuation.isWideContinuation = true
            grid[cursorRow][cursorColumn + 1] = continuation
            if cursorColumn + 1 == columns - 1 { pendingWrap = true; cursorColumn = columns - 1 }
            else { cursorColumn += 2 }
            return
        }
        var cell = current
        cell.character = character
        cell.isWideContinuation = false
        grid[cursorRow][cursorColumn] = cell
        if cursorColumn == columns - 1 { pendingWrap = true }
        else { cursorColumn += 1 }
    }

    /// A zero-width character (combining mark, joiner) merges into the
    /// grapheme of the cell it follows instead of taking a column.
    private mutating func appendCombining(_ character: Character) {
        var column = pendingWrap ? columns - 1 : cursorColumn - 1
        var row = cursorRow
        if column < 0 {
            guard row > 0 else { return }
            row -= 1
            column = columns - 1
        }
        if grid[row][column].isWideContinuation, column > 0 { column -= 1 }
        let merged = String(grid[row][column].character) + String(character)
        grid[row][column].character = Character(merged)
    }

    private func blankCell() -> TerminalCell { TerminalCell() }

    /// Resizes the grid in place (package D): content is preserved
    /// top-left anchored, lines are truncated or padded, the cursor is
    /// clamped into the new bounds. Scrollback rows keep the width
    /// they were written at — like simple terminal models everywhere,
    /// history is not reflowed.
    public mutating func resize(columns newColumns: Int, rows newRows: Int) {
        let targetColumns = max(1, newColumns)
        let targetRows = max(1, newRows)
        guard targetColumns != columns || targetRows != rows else { return }
        var newGrid: [[TerminalCell]] = []
        for row in 0..<targetRows {
            if row < rows {
                var line = grid[row]
                if line.count > targetColumns { line = Array(line.prefix(targetColumns)) }
                while line.count < targetColumns { line.append(TerminalCell()) }
                newGrid.append(line)
            } else {
                newGrid.append(Array(repeating: TerminalCell(), count: targetColumns))
            }
        }
        grid = newGrid
        columns = targetColumns
        rows = targetRows
        cursorRow = min(cursorRow, targetRows - 1)
        cursorColumn = min(cursorColumn, targetColumns - 1)
        pendingWrap = false
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
    /// DEC private mode 2004: the running program (vim, tmux, a shell
    /// with bracketed-paste on) asks for pastes to arrive wrapped in
    /// ESC[200~ … ESC[201~ so it can tell a paste from typing. The
    /// input side reads this to encode UIPasteboard content.
    public private(set) var bracketedPasteEnabled = false
    private var state: State = .ground
    private var csiParameters = ""
    private var utf8Remainder = Data()

    private enum State { case ground, escape, csi, osc, oscEscape, charset }

    public init(columns: Int = 80, rows: Int = 24) {
        screen = TerminalScreen(columns: columns, rows: rows)
    }

    /// Forwards a view-driven size change to the screen model; the
    /// view layer pairs this with the SSH window-change message so
    /// the shell's idea of the grid and ours never diverge.
    public mutating func resize(columns: Int, rows: Int) {
        screen.resize(columns: columns, rows: rows)
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
        if isPrivate {
            // The one private mode the input side depends on: 2004
            // bracketed paste. Everything else stays ignored.
            if numbers.contains(2004) {
                if final == "h" { bracketedPasteEnabled = true }
                else if final == "l" { bracketedPasteEnabled = false }
            }
            return
        }
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

    /// Encodes a paste from the clipboard. When the remote program
    /// enabled bracketed paste (mode 2004), the text is wrapped in
    /// the begin/end markers so it is inserted, not executed line by
    /// line; embedded ESC bytes are stripped either way — a paste
    /// must never smuggle escape sequences into the shell. Newlines
    /// inside a bracketed paste stay LF (the receiving program owns
    /// their meaning); outside brackets they take the committed-text
    /// mapping (each becomes the Return CR).
    public static func data(forPaste text: String, bracketed: Bool) -> Data {
        let sanitized = text.unicodeScalars.filter { $0.value != 0x1B }
        let cleaned = String(String.UnicodeScalarView(sanitized))
        guard bracketed else { return data(forCommittedText: cleaned) }
        var out = Data("\u{1B}[200~".utf8)
        out.append(contentsOf: cleaned.utf8)
        out.append(contentsOf: "\u{1B}[201~".utf8)
        return out
    }

    /// Encodes text the user committed (typed, pasted, or an IME
    /// composition confirmed) into PTY bytes. The terminal surface is
    /// stateless — the shell's line discipline owns editing — so this
    /// is a pure per-scalar mapping:
    /// - CR, LF and CRLF each become the single CR the shell expects
    ///   from the Return key (an IME or keyboard that reports the
    ///   Return key as "\n" must still submit the line);
    /// - DEL (U+007F) stays DEL, matching the backspace key;
    /// - every other scalar, CJK included, passes through as UTF-8.
    public static func data(forCommittedText text: String) -> Data {
        var out = Data()
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\r":
                out.append(contentsOf: data(for: .enter))
                previousWasCR = true
            case "\n":
                if !previousWasCR { out.append(contentsOf: data(for: .enter)) }
                previousWasCR = false
            case "\u{7F}":
                out.append(contentsOf: data(for: .backspace))
                previousWasCR = false
            default:
                out.append(contentsOf: String(scalar).utf8)
                previousWasCR = false
            }
        }
        return out
    }
}
