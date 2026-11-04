import AppKit
import ApplicationServices
import Foundation

/// Types streaming text straight into the focused app with synthesized Unicode key events
/// (no clipboard, no app switching). Keeps track of what it typed so it can revise the tail
/// with Backspace when the recognizer (or zh-tw conversion) changes earlier characters.
@MainActor
final class LiveTyper {
    private(set) var typed = ""
    private let source = CGEventSource(stateID: .hidSystemState)

    func reset() {
        typed = ""
    }

    /// Makes the text typed so far equal `target` with minimal Backspace + insert.
    func apply(_ target: String) {
        guard target != typed else { return }
        let commonCount = Self.commonPrefixCount(typed, target)
        let deleteCount = typed.count - commonCount
        let insertion = String(target.dropFirst(commonCount))
        if deleteCount > 0 {
            for _ in 0..<deleteCount { pressBackspace() }
            Logger.shared.log("Live typing revised tail: deleted=\(deleteCount)")
        }
        if !insertion.isEmpty {
            typeUnicode(insertion)
        }
        typed = target
    }

    /// Removes everything this session typed (used on Escape).
    func erase() {
        apply("")
    }

    private static func commonPrefixCount(_ lhs: String, _ rhs: String) -> Int {
        var count = 0
        for (a, b) in zip(lhs, rhs) {
            guard a == b else { break }
            count += 1
        }
        return count
    }

    private func pressBackspace() {
        let backspace: CGKeyCode = 51
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: backspace, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: backspace, keyDown: false) else { return }
        down.flags = []
        up.flags = []
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
    }

    private func typeUnicode(_ text: String) {
        let units = Array(text.utf16)
        var start = 0
        // CGEvent accepts up to 20 UTF-16 units per event; keep chunks small and never split a surrogate pair.
        while start < units.count {
            var end = min(start + 16, units.count)
            if end < units.count, UTF16.isLeadSurrogate(units[end - 1]) {
                end -= 1
            }
            var chunk = Array(units[start..<end])
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return }
            down.flags = []
            up.flags = []
            down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            down.post(tap: .cgSessionEventTap)
            up.post(tap: .cgSessionEventTap)
            start = end
        }
    }
}
