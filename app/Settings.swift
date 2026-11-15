import Foundation

/// The config file both halves share (~/.config/xswitcher/config). The
/// agent's parser in agent/hotkeys.c is the reference for the format.
struct Settings {
    static let bindingNames = ["left", "right", "last"] + (1...16).map { "space\($0)" }

    var shortcuts: [String: Shortcut] = [
        "left": Shortcut(config: "ctrl+left")!,
        "right": Shortcut(config: "ctrl+right")!,
    ]
    var overrideSystemShortcuts = true // hotkeys = tap
    var swipeOverride = false
    var menuBar = false
    var checkUpdates = true
    var gestureSpeed: Double = 2000

    static func load() -> Settings {
        var s = Settings()
        guard let text = try? String(contentsOf: Paths.config, encoding: .utf8) else { return s }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let kv = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2 else { continue }
            let (key, value) = (kv[0], kv[1])
            let on = ["on", "true", "yes", "1"].contains(value.lowercased())
            switch key {
            case "hotkeys": s.overrideSystemShortcuts = value.lowercased() != "carbon"
            case "swipe_override": s.swipeOverride = on
            case "menubar": s.menuBar = on
            case "check_updates": s.checkUpdates = on
            case "gesture_speed": s.gestureSpeed = Double(value) ?? 2000
            default:
                if bindingNames.contains(key) { s.shortcuts[key] = Shortcut(config: value) }
            }
        }
        return s
    }

    func save() throws {
        var out = """
        # XSwitcher settings. The Settings window writes this file; you can also edit it by hand
        # and run `kill -HUP $(pgrep -x xswitcher-agent)` to reload.
        # Shortcuts: modifiers (ctrl, alt, cmd, shift) + key, or "none".

        """
        for name in Settings.bindingNames {
            out += "\(name) = \(shortcuts[name]?.configString ?? "none")\n"
        }
        out += """

        # tap: take over shortcuts before macOS sees them (needed for ctrl+left/right)
        # carbon: let macOS match them (macOS's own shortcuts win)
        hotkeys = \(overrideSystemShortcuts ? "tap" : "carbon")
        swipe_override = \(swipeOverride ? "on" : "off")
        menubar = \(menuBar ? "on" : "off")
        check_updates = \(checkUpdates ? "on" : "off")
        gesture_speed = \(Int(gestureSpeed))

        """
        try FileManager.default.createDirectory(at: Paths.config.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try out.write(to: Paths.config, atomically: true, encoding: .utf8)
    }
}
