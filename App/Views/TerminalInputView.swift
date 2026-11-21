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

    private let scrollView = UIScrollView()
    private let label = UILabel()
    private var composingText = ""
    private var composingSelection = NSRange(location: 0, length: 0)
    private var scrollPending = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Same dynamic pair as AppPalette.text (DesignSystem.swift).
        label.textColor = UIColor { traits in
            let hex: UInt32 = traits.userInterfaceStyle == .dark ? 0xEFF3F3 : 0x191E20
            return UIColor(red: Double((hex >> 16) & 255) / 255,
                           green: Double((hex >> 8) & 255) / 255,
                           blue: Double(hex & 255) / 255, alpha: 1)
        }
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.numberOfLines = 0
        scrollView.addSubview(label)
        addSubview(scrollView)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(refocus)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("programmatic view") }

    override var canBecomeFirstResponder: Bool { true }

    @objc private func refocus() { becomeFirstResponder() }

    func display(_ text: String) {
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
                composingSelection = NSRange(location: range.start.offset,
                                             length: range.end.offset - range.start.offset)
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
        let start = text.index(text.startIndex, offsetBy: min(range.start.offset, text.count))
        let end = text.index(text.startIndex, offsetBy: min(range.end.offset, text.count))
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
    override var isEmpty: Bool {
        (start as? TerminalTextPosition)?.offset == (end as? TerminalTextPosition)?.offset
    }
}

/// SwiftUI shell for TerminalInputView: pushes the rendered screen in,
/// forwards focus requests (surface appearance, key-bar taps) down.
struct TerminalSurfaceView: UIViewRepresentable {
    let text: String
    let focusToken: Int
    let onSend: (Data) -> Void

    func makeUIView(context: Context) -> TerminalInputView {
        let view = TerminalInputView()
        view.onSend = onSend
        DispatchQueue.main.async { view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ view: TerminalInputView, context: Context) {
        view.onSend = onSend
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
