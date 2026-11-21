import SwiftUI
import UIKit
import OpenWrtKit

/// The terminal surface (round 6): the view itself is the text input,
/// the way mature terminals (Termius, Blink) build it. There is no
/// local text buffer mirroring the shell's line — that dual state was
/// the old TextField design's root failure (Ctrl+C, mid-line edits and
/// command execution all desynchronized it). Keystrokes become PTY
/// bytes immediately through TerminalInput's encoder, and the screen
/// the shell paints back is the only state.
///
/// The UITextInput "document" exists only while an IME composition is
/// in flight: setMarkedText holds the composing string locally, and a
/// commit (candidate tap, insertText, unmarkText) forwards it as bytes
/// and forgets it. Nothing is ever echoed locally.
final class TerminalInputView: UIView, UIKeyInput, UITextInput {
    /// Byte sink: the live SSH session in production, a recorder under
    /// the DEBUG UI-test seed.
    var onSend: ((Data) -> Void)?
    /// Grid-size sink (package D): fired whenever the laid-out size or
    /// the font size implies a different column/row count, so the
    /// view layer can resize the parser and the PTY together.
    var onResize: ((Int, Int) -> Void)?
    /// Paste sink (package D): clipboard text arrives here from the
    /// edit menu; the view layer encodes it (bracketed when the
    /// remote program asked for it) — this view stays byte-honest.
    var onPaste: ((String) -> Void)?

    private let scrollView = UIScrollView()
    private let label = UILabel()
    private var composingText = ""
    private var composingSelection = NSRange(location: 0, length: 0)
    private var scrollPending = false
    private var displayedText = ""
    private var fontSize: CGFloat = 12
    private var lastReportedGrid: (columns: Int, rows: Int)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Same dynamic pair as AppPalette.text (DesignSystem.swift).
        label.textColor = UIColor { traits in
            let hex: UInt32 = traits.userInterfaceStyle == .dark ? 0xEFF3F3 : 0x191E20
            return UIColor(red: Double((hex >> 16) & 255) / 255,
                           green: Double((hex >> 8) & 255) / 255,
                           blue: Double(hex & 255) / 255, alpha: 1)
        }
        label.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        label.numberOfLines = 0
        scrollView.addSubview(label)
        addSubview(scrollView)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(refocus)))
        // Pinch zooms the terminal font (the Termius/Blink gesture);
        // the grid is recomputed from the new cell size in layout.
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)
        // Long-press offers the native edit menu (copy the screen,
        // paste the clipboard) — the platform's own text-interaction
        // shape, adapted to a surface that is not itself a document.
        addInteraction(UIEditMenuInteraction(delegate: self))
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        addGestureRecognizer(longPress)
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard gesture.state == .changed || gesture.state == .ended else { return }
        let candidate = min(max(fontSize * gesture.scale, 9), 22)
        gesture.scale = 1
        guard abs(candidate - fontSize) > 0.1 else { return }
        fontSize = candidate
        label.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        setNeedsLayout()
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        becomeFirstResponder()
        let location = gesture.location(in: self)
        for interaction in interactions {
            if let menu = interaction as? UIEditMenuInteraction {
                menu.presentEditMenu(with: .init(identifier: nil, sourcePoint: location, arrowDirection: .down))
            }
        }
    }

    // MARK: Edit-menu actions (copy the screen / paste the clipboard)

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(copy(_:)): return !displayedText.isEmpty
        case #selector(paste(_:)): return UIPasteboard.general.hasStrings
        default: return super.canPerformAction(action, withSender: sender)
        }
    }

    @objc override func copy(_ sender: Any?) {
        UIPasteboard.general.string = displayedText
    }

    @objc override func paste(_ sender: Any?) {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { return }
        onPaste?(text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic view") }

    override var canBecomeFirstResponder: Bool { true }

    @objc private func refocus() { becomeFirstResponder() }

    func display(_ text: String) {
        displayedText = text
        label.text = text
        scrollPending = true
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scrollView.frame = bounds
        let width = max(bounds.width - 16, 0)
        label.frame = CGRect(x: 8, y: 8, width: width, height: 0)
        label.sizeToFit()
        label.frame = CGRect(x: 8, y: 8, width: width, height: label.frame.height)
        scrollView.contentSize = CGSize(width: bounds.width, height: label.frame.height + 16)
        if scrollPending {
            scrollPending = false
            let y = max(0, scrollView.contentSize.height - scrollView.bounds.height)
            scrollView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
        }
        reportGridSizeIfChanged()
    }

    /// The grid implied by the current bounds and font metrics. The
    /// cell width is the advance of a monospace "M"; the cell height
    /// is the font's line height. Reported only on change so rotation
    /// and pinch produce exactly one resize per settled size.
    private func reportGridSizeIfChanged() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let cellWidth = ("M" as NSString).size(withAttributes: [.font: label.font as Any]).width
        let grid = TerminalGeometry.gridSize(viewWidth: Double(bounds.width - 16),
                                             viewHeight: Double(bounds.height - 16),
                                             cellWidth: Double(cellWidth),
                                             cellHeight: Double(label.font.lineHeight))
        if let last = lastReportedGrid, last == grid { return }
        lastReportedGrid = grid
        onResize?(grid.columns, grid.rows)
    }

    private func send(_ data: Data) {
        guard !data.isEmpty else { return }
        onSend?(data)
    }

    private func commitComposing() {
        guard !composingText.isEmpty else { return }
        let text = composingText
        composingText = ""
        composingSelection = NSRange(location: 0, length: 0)
        send(TerminalInput.data(forCommittedText: text))
        inputDelegate?.textDidChange(self)
    }

    // MARK: UIKeyInput

    var hasText: Bool { true }

    func insertText(_ text: String) {
        // A commit arriving while a composition is open replaces it:
        // the composition is consumed by this insertion, so a trailing
        // unmarkText finds nothing and cannot double-send.
        if !composingText.isEmpty {
            composingText = ""
            composingSelection = NSRange(location: 0, length: 0)
        }
        send(TerminalInput.data(forCommittedText: text))
        inputDelegate?.textDidChange(self)
    }

    func deleteBackward() {
        if !composingText.isEmpty {
            composingText.removeLast()
            composingSelection = NSRange(location: composingText.count, length: 0)
            inputDelegate?.selectionDidChange(self)
            inputDelegate?.textDidChange(self)
            return
        }
        send(TerminalInput.data(for: .backspace))
    }

    // MARK: Hardware keyboard (keys insertText never sees)

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled: Set<UIPress> = []
        for press in presses {
            guard let key = press.key else { unhandled.insert(press); continue }
            if key.modifierFlags.contains(.control) {
                if let character = key.charactersIgnoringModifiers.first {
                    if character == " " {
                        send(Data([0x00]))
                    } else {
                        send(TerminalInput.data(for: .control(character)))
                    }
                }
                continue
            }
            switch key.keyCode {
            case .keyboardUpArrow: send(TerminalInput.data(for: .arrowUp))
            case .keyboardDownArrow: send(TerminalInput.data(for: .arrowDown))
            case .keyboardLeftArrow: send(TerminalInput.data(for: .arrowLeft))
            case .keyboardRightArrow: send(TerminalInput.data(for: .arrowRight))
            case .keyboardEscape: send(TerminalInput.data(for: .escape))
            case .keyboardDeleteForward: send(TerminalInput.data(for: .delete))
            case .keyboardHome: send(TerminalInput.data(for: .home))
            case .keyboardEnd: send(TerminalInput.data(for: .end))
            case .keyboardPageUp: send(TerminalInput.data(for: .pageUp))
            case .keyboardPageDown: send(TerminalInput.data(for: .pageDown))
            default: unhandled.insert(press)
            }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    // MARK: UITextInput — the document is the composition, nothing else

    weak var inputDelegate: UITextInputDelegate?
    var markedTextStyle: [NSAttributedString.Key: Any]?

    var tokenizer: UITextInputTokenizer { UITextInputStringTokenizer(textInput: self) }

    var beginningOfDocument: UITextPosition { TerminalTextPosition(0) }
    var endOfDocument: UITextPosition { TerminalTextPosition(composingText.count) }

    var selectedTextRange: UITextRange? {
        get {
            TerminalTextRange(start: TerminalTextPosition(composingSelection.location),
                              end: TerminalTextPosition(composingSelection.location + composingSelection.length))
        }
        set {
            if let range = newValue as? TerminalTextRange {
                composingSelection = NSRange(location: range.startOffset,
                                             length: range.endOffset - range.startOffset)
            }
        }
    }

    var markedTextRange: UITextRange? {
        composingText.isEmpty ? nil
            : TerminalTextRange(start: TerminalTextPosition(0),
                                end: TerminalTextPosition(composingText.count))
    }

    func text(in range: UITextRange) -> String? {
        guard let range = range as? TerminalTextRange else { return nil }
        let text = composingText
        let start = text.index(text.startIndex, offsetBy: min(range.startOffset, text.count))
        let end = text.index(text.startIndex, offsetBy: min(range.endOffset, text.count))
        return String(text[start..<end])
    }

    func replace(_ range: UITextRange, withText text: String) {
        // Replacing the marked range is the other commit shape IMEs
        // use; with no composition it is a plain insertion.
        composingText = ""
        composingSelection = NSRange(location: 0, length: 0)
        send(TerminalInput.data(forCommittedText: text))
        inputDelegate?.textDidChange(self)
    }

    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        composingText = markedText ?? ""
        composingSelection = selectedRange
        inputDelegate?.selectionDidChange(self)
        inputDelegate?.textDidChange(self)
    }

    func unmarkText() { commitComposing() }

    func textRange(from fromPosition: UITextPosition, to toPosition: UITextPosition) -> UITextRange? {
        guard let from = fromPosition as? TerminalTextPosition,
              let to = toPosition as? TerminalTextPosition else { return nil }
        return TerminalTextRange(start: from, end: to)
    }

    func position(from position: UITextPosition, in direction: UITextLayoutDirection) -> UITextPosition? {
        guard let position = position as? TerminalTextPosition else { return nil }
        switch direction {
        case .left, .up: return TerminalTextPosition(max(0, position.offset - 1))
        case .right, .down: return TerminalTextPosition(min(composingText.count, position.offset + 1))
        @unknown default: return position
        }
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
        guard let position = position as? TerminalTextPosition else { return nil }
        return TerminalTextPosition(min(max(0, position.offset + offset), composingText.count))
    }

    func position(from position: UITextPosition, in direction: UITextLayoutDirection,
                  offset: Int) -> UITextPosition? {
        // LTR semantics throughout (baseWritingDirection is fixed
        // .leftToRight): right/down move towards the end of the
        // composition, left/up towards its start. (UITextLayoutDirection
        // has no forward/backward — those are storage directions.)
        // A move that would land outside the composition has no
        // position.
        guard let position = position as? TerminalTextPosition else { return nil }
        let target: Int
        switch direction {
        case .right, .down: target = position.offset + offset
        case .left, .up: target = position.offset - offset
        @unknown default: return position
        }
        guard target >= 0, target <= composingText.count else { return nil }
        return TerminalTextPosition(target)
    }

    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection) -> UITextPosition? {
        // The farthest position inside the range in a direction: in
        // this LTR-only document that is the range's start for
        // left/up and its end for right/down.
        guard let range = range as? TerminalTextRange else { return nil }
        switch direction {
        case .left, .up: return range.start
        case .right, .down: return range.end
        @unknown default: return range.end
        }
    }

    func offset(from: UITextPosition, to toPosition: UITextPosition) -> Int {
        guard let from = from as? TerminalTextPosition,
              let to = toPosition as? TerminalTextPosition else { return 0 }
        return to.offset - from.offset
    }

    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
        guard let position = position as? TerminalTextPosition,
              let other = other as? TerminalTextPosition else { return .orderedSame }
        if position.offset < other.offset { return .orderedAscending }
        if position.offset > other.offset { return .orderedDescending }
        return .orderedSame
    }

    func firstRect(for range: UITextRange) -> CGRect {
        caretRect(for: range.end)
    }

    func caretRect(for position: UITextPosition) -> CGRect {
        let lineHeight = label.font.lineHeight
        return CGRect(x: 8, y: max(8, label.frame.height + 8 - lineHeight), width: 2, height: lineHeight)
    }

    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }

    func closestPosition(to point: CGPoint) -> UITextPosition? { endOfDocument }

    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? { range.end }

    func characterRange(byExtending position: UITextPosition, in direction: UITextLayoutDirection) -> UITextRange? {
        TerminalTextRange(start: position, end: position)
    }

    func characterRange(at point: CGPoint) -> UITextRange? {
        TerminalTextRange(start: endOfDocument, end: endOfDocument)
    }

    func baseWritingDirection(for position: UITextPosition, in direction: UITextStorageDirection) -> NSWritingDirection {
        .leftToRight
    }

    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {
        // Deliberately no state: the composition is an ephemeral IME
        // buffer with no persistent layout, and the getter above
        // reports the only direction this input ever uses (LTR).
        // Storing a direction would create state nothing reads.
    }

    // MARK: UITextInputTraits — no assistant features second-guess input

    var keyboardType: UIKeyboardType = .default
    var keyboardAppearance: UIKeyboardAppearance = .default
    var returnKeyType: UIReturnKeyType = .default
    var enablesReturnKeyAutomatically: Bool = false
    var isSecureTextEntry: Bool = false
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
}

/// A character offset into the composition, the only positions this
/// input ever has.
final class TerminalTextPosition: UITextPosition {
    let offset: Int
    init(_ offset: Int) { self.offset = offset }
}

final class TerminalTextRange: UITextRange {
    private let startPosition: UITextPosition
    private let endPosition: UITextPosition
    init(start: UITextPosition, end: UITextPosition) {
        startPosition = start
        endPosition = end
    }
    override var start: UITextPosition { startPosition }
    override var end: UITextPosition { endPosition }
    override var isEmpty: Bool { startOffset == endOffset }

    /// Offsets of the range's ends. UITextPosition is opaque — it has
    /// no offset member — so the ends must come back through the
    /// concrete position type before any arithmetic. Positions this
    /// input did not mint have no offset; 0 keeps the arithmetic
    /// total instead of trapping.
    var startOffset: Int { (startPosition as? TerminalTextPosition)?.offset ?? 0 }
    var endOffset: Int { (endPosition as? TerminalTextPosition)?.offset ?? 0 }
}

extension TerminalInputView: UIEditMenuInteractionDelegate {
    func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                             menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        var actions: [UIMenuElement] = []
        if canPerformAction(#selector(copy(_:)), withSender: nil) {
            actions.append(UIAction(title: L10n.string("复制屏幕内容"),
                                    image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
                self?.copy(nil)
            })
        }
        if canPerformAction(#selector(paste(_:)), withSender: nil) {
            actions.append(UIAction(title: L10n.string("粘贴"),
                                    image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
                self?.paste(nil)
            })
        }
        return actions.isEmpty ? nil : UIMenu(children: actions)
    }
}

/// SwiftUI shell for TerminalInputView: pushes the rendered screen in,
/// forwards focus requests (surface appearance, key-bar taps) down.
struct TerminalSurfaceView: UIViewRepresentable {
    let text: String
    let focusToken: Int
    let onSend: (Data) -> Void
    var onResize: ((Int, Int) -> Void)?
    var onPaste: ((String) -> Void)?

    func makeUIView(context: Context) -> TerminalInputView {
        let view = TerminalInputView()
        view.onSend = onSend
        view.onResize = onResize
        view.onPaste = onPaste
        DispatchQueue.main.async { view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ view: TerminalInputView, context: Context) {
        view.onSend = onSend
        view.onResize = onResize
        view.onPaste = onPaste
        view.display(text)
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.lastFocusToken = focusToken
            view.becomeFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastFocusToken = 0
    }
}
