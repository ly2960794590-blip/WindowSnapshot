import Foundation

/// A system keyboard shortcut as stored in com.apple.symbolichotkeys.
public struct Hotkey: Equatable {
    public var keyCode: Int
    /// Modifier bits, same layout as CGEventFlags / NSEvent.ModifierFlags.
    public var modifiers: Int
    public var enabled: Bool

    public init(keyCode: Int, modifiers: Int, enabled: Bool) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.enabled = enabled
    }

    /// Symbolic hotkey ids used by Mission Control.
    public static let moveLeftASpaceID = 79
    public static let moveRightASpaceID = 81

    public static let controlFlag = 0x40000
    public static let leftArrowKeyCode = 123
    public static let rightArrowKeyCode = 124

    public static let functionFlag = 0x800000
    public static let numericPadFlag = 0x200000

    /// Flags to put on a synthesized key event. Real arrow-key presses always carry the Fn and
    /// numeric-pad bits, and Mission Control ignores a Control+arrow event without them.
    public var eventFlags: Int {
        (123...126).contains(keyCode) ? modifiers | Hotkey.functionFlag | Hotkey.numericPadFlag : modifiers
    }

    /// Reads one entry of `AppleSymbolicHotKeys`. A missing entry means the user never touched
    /// the shortcut, so the system default (Control + arrow) applies.
    public static func parse(_ entry: [String: Any]?, defaultKeyCode: Int) -> Hotkey {
        guard let entry = entry else {
            return Hotkey(keyCode: defaultKeyCode, modifiers: controlFlag, enabled: true)
        }
        let enabled = (entry["enabled"] as? NSNumber)?.boolValue ?? true
        if let value = entry["value"] as? [String: Any],
           let params = value["parameters"] as? [NSNumber], params.count >= 3 {
            return Hotkey(keyCode: params[1].intValue, modifiers: params[2].intValue, enabled: enabled)
        }
        return Hotkey(keyCode: defaultKeyCode, modifiers: controlFlag, enabled: enabled)
    }
}
