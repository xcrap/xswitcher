import AppKit
import Carbon.HIToolbox

/// Key names shared with the agent's config parser (agent/hotkeys.c). Keep the
/// two tables in sync.
struct KeyInfo {
    let code: UInt32
    let name: String   // as written in the config file
    let glyph: String  // as shown in the UI
}

enum Keys {
    static let all: [KeyInfo] = {
        var k: [KeyInfo] = []
        func add(_ code: Int, _ name: String, _ glyph: String? = nil) {
            k.append(KeyInfo(code: UInt32(code), name: name, glyph: glyph ?? name.uppercased()))
        }
        let letters: [(Int, String)] = [
            (kVK_ANSI_A, "a"), (kVK_ANSI_B, "b"), (kVK_ANSI_C, "c"), (kVK_ANSI_D, "d"), (kVK_ANSI_E, "e"),
            (kVK_ANSI_F, "f"), (kVK_ANSI_G, "g"), (kVK_ANSI_H, "h"), (kVK_ANSI_I, "i"), (kVK_ANSI_J, "j"),
            (kVK_ANSI_K, "k"), (kVK_ANSI_L, "l"), (kVK_ANSI_M, "m"), (kVK_ANSI_N, "n"), (kVK_ANSI_O, "o"),
            (kVK_ANSI_P, "p"), (kVK_ANSI_Q, "q"), (kVK_ANSI_R, "r"), (kVK_ANSI_S, "s"), (kVK_ANSI_T, "t"),
            (kVK_ANSI_U, "u"), (kVK_ANSI_V, "v"), (kVK_ANSI_W, "w"), (kVK_ANSI_X, "x"), (kVK_ANSI_Y, "y"),
            (kVK_ANSI_Z, "z"),
        ]
        letters.forEach { add($0.0, $0.1) }
        let digits = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4,
                      kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (i, c) in digits.enumerated() { add(c, "\(i)") }
        let fkeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                     kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        for (i, c) in fkeys.enumerated() { add(c, "f\(i + 1)", "F\(i + 1)") }
        add(kVK_LeftArrow, "left", "←"); add(kVK_RightArrow, "right", "→")
        add(kVK_UpArrow, "up", "↑"); add(kVK_DownArrow, "down", "↓")
        add(kVK_Space, "space", "Space"); add(kVK_Tab, "tab", "⇥"); add(kVK_Return, "return", "↩")
        add(kVK_Escape, "escape", "⎋"); add(kVK_Delete, "delete", "⌫"); add(kVK_ForwardDelete, "forwarddelete", "⌦")
        add(kVK_Home, "home", "↖"); add(kVK_End, "end", "↘"); add(kVK_PageUp, "pageup", "⇞"); add(kVK_PageDown, "pagedown", "⇟")
        add(kVK_ANSI_Minus, "minus", "-"); add(kVK_ANSI_Equal, "equal", "=")
        add(kVK_ANSI_LeftBracket, "leftbracket", "["); add(kVK_ANSI_RightBracket, "rightbracket", "]")
        add(kVK_ANSI_Semicolon, "semicolon", ";"); add(kVK_ANSI_Quote, "quote", "'")
        add(kVK_ANSI_Comma, "comma", ","); add(kVK_ANSI_Period, "period", ".")
        add(kVK_ANSI_Slash, "slash", "/"); add(kVK_ANSI_Backslash, "backslash", "\\"); add(kVK_ANSI_Grave, "grave", "`")
        let keypad = [kVK_ANSI_Keypad0, kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4,
                      kVK_ANSI_Keypad5, kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9]
        for (i, c) in keypad.enumerated() { add(c, "keypad\(i)", "Keypad \(i)") }
        add(kVK_ANSI_KeypadPlus, "keypadplus", "Keypad +"); add(kVK_ANSI_KeypadMinus, "keypadminus", "Keypad -")
        add(kVK_ANSI_KeypadMultiply, "keypadmultiply", "Keypad *"); add(kVK_ANSI_KeypadDivide, "keypaddivide", "Keypad /")
        add(kVK_ANSI_KeypadEnter, "keypadenter", "⌅"); add(kVK_ANSI_KeypadDecimal, "keypaddecimal", "Keypad .")
        add(kVK_ANSI_KeypadEquals, "keypadequals", "Keypad ="); add(kVK_ANSI_KeypadClear, "keypadclear", "⌧")
        return k
    }()

    static func byName(_ name: String) -> KeyInfo? { all.first { $0.name == name } }
    static func byCode(_ code: UInt32) -> KeyInfo? { all.first { $0.code == code } }

    /// F1–F20 may be used without modifiers; every other key needs one, so a
    /// shortcut can never swallow normal typing.
    static func isFunctionKey(_ code: UInt32) -> Bool {
        guard let name = byCode(code)?.name, name.count > 1, name.first == "f" else { return false }
        return Int(name.dropFirst()) != nil
    }
}

/// A key plus modifiers, using Carbon's modifier bits like the agent does.
struct Shortcut: Equatable {
    var keyCode: UInt32
    var mods: UInt32

    static let control = UInt32(controlKey), option = UInt32(optionKey)
    static let command = UInt32(cmdKey), shift = UInt32(shiftKey)

    init(keyCode: UInt32, mods: UInt32) {
        self.keyCode = keyCode
        self.mods = mods
    }

    /// Parses "ctrl+alt+left". Returns nil for "none" or anything invalid.
    init?(config: String) {
        let parts = config.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last = parts.last, let key = Keys.byName(last) else { return nil }
        var m: UInt32 = 0
        for p in parts.dropLast() {
            switch p {
            case "ctrl", "control": m |= Shortcut.control
            case "alt", "opt", "option": m |= Shortcut.option
            case "cmd", "command": m |= Shortcut.command
            case "shift": m |= Shortcut.shift
            default: return nil
            }
        }
        self.init(keyCode: key.code, mods: m)
    }

    var configString: String {
        var parts: [String] = []
        if mods & Shortcut.control != 0 { parts.append("ctrl") }
        if mods & Shortcut.option != 0 { parts.append("alt") }
        if mods & Shortcut.command != 0 { parts.append("cmd") }
        if mods & Shortcut.shift != 0 { parts.append("shift") }
        parts.append(Keys.byCode(keyCode)?.name ?? "?")
        return parts.joined(separator: "+")
    }

    /// Apple's order: ⌃ ⌥ ⇧ ⌘ then the key.
    var display: String {
        var s = ""
        if mods & Shortcut.control != 0 { s += "⌃" }
        if mods & Shortcut.option != 0 { s += "⌥" }
        if mods & Shortcut.shift != 0 { s += "⇧" }
        if mods & Shortcut.command != 0 { s += "⌘" }
        return s + (Keys.byCode(keyCode)?.glyph ?? "?")
    }

    static func mods(from flags: CGEventFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.maskControl) { m |= control }
        if flags.contains(.maskAlternate) { m |= option }
        if flags.contains(.maskCommand) { m |= command }
        if flags.contains(.maskShift) { m |= shift }
        return m
    }

    static func mods(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.control) { m |= control }
        if flags.contains(.option) { m |= option }
        if flags.contains(.command) { m |= command }
        if flags.contains(.shift) { m |= shift }
        return m
    }
}
