import AppKit

/// Click, then press the keys. Esc cancels, Delete clears.
///
/// XSwitcher is paused while you record, so pressing a shortcut that's
/// already set doesn't switch desktops. Keys macOS keeps for itself (like
/// ⌃← / ⌃→ while its own Mission Control shortcuts are on) can't be
/// recorded here; "Restore Defaults" sets those.
@MainActor
final class ShortcutButton: NSButton {
    var shortcut: Shortcut? { didSet { updateTitle() } }
    var onChange: ((Shortcut?) -> Void)?

    private var recording = false
    private var monitor: Any?

    init(shortcut: Shortcut?, width: CGFloat = 140) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        bezelStyle = .rounded
        controlSize = .regular
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(clicked)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func updateTitle() {
        let text: String
        let color: NSColor
        if recording {
            text = "Type shortcut…"
            color = .controlAccentColor
        } else if let shortcut {
            text = shortcut.display
            color = .labelColor
        } else {
            text = "Record Shortcut"
            color = .secondaryLabelColor
        }
        attributedTitle = NSAttributedString(string: text, attributes: [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: shortcut != nil && !recording ? .medium : .regular),
        ])
    }

    @objc private func clicked() { recording ? stop() : start() }

    private func start() {
        recording = true
        updateTitle()
        Agent.pause()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            self?.handle(code: UInt32(e.keyCode), mods: Shortcut.mods(from: e.modifierFlags))
            return nil
        }
    }

    func stop() {
        guard recording else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        updateTitle()
        Agent.resume()
    }

    private func handle(code: UInt32, mods: UInt32) {
        guard recording else { return }
        let escape: UInt32 = 53, delete: UInt32 = 51, fwdDelete: UInt32 = 117
        if mods == 0 && code == escape { stop(); return }
        if mods == 0 && (code == delete || code == fwdDelete) {
            stop()
            shortcut = nil
            onChange?(nil)
            return
        }
        guard Keys.byCode(code) != nil, mods != 0 || Keys.isFunctionKey(code) else {
            NSSound.beep() // a bare letter would block normal typing
            return
        }
        stop()
        let s = Shortcut(keyCode: code, mods: mods)
        shortcut = s
        onChange?(s)
    }
}
