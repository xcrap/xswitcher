import AppKit

/// Click, then press the keys. Esc cancels, Delete clears.
///
/// While recording, the agent is paused and this button listens at the same
/// low level the agent uses, so even Ctrl+arrows (which macOS would normally
/// keep for itself) can be recorded.
@MainActor
final class ShortcutButton: NSButton {
    var shortcut: Shortcut? { didSet { updateTitle() } }
    var onChange: ((Shortcut?) -> Void)?

    private var recording = false
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var localMonitor: Any?

    init(shortcut: Shortcut?, width: CGFloat = 150) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(clicked)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
        updateTitle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func updateTitle() {
        if recording {
            title = "Press keys…"
        } else {
            title = shortcut?.display ?? "Click to set"
        }
        contentTintColor = shortcut == nil && !recording ? .secondaryLabelColor : nil
    }

    @objc private func clicked() {
        recording ? stop() : start()
    }

    private func start() {
        recording = true
        updateTitle()
        Agent.pause()
        if !installTap() {
            // No Accessibility yet: fall back to keys sent to this window.
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                self?.handle(code: UInt32(e.keyCode), mods: Shortcut.mods(from: e.modifierFlags))
                return nil
            }
        }
    }

    func stop() {
        guard recording else { return }
        recording = false
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        tap = nil
        tapSource = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
        updateTitle()
        Agent.resume()
    }

    fileprivate func handle(code: UInt32, mods: UInt32) {
        guard recording else { return }
        let escape: UInt32 = 53, delete: UInt32 = 51, fwdDelete: UInt32 = 117
        if mods == 0 && code == escape { stop(); return }
        if mods == 0 && (code == delete || code == fwdDelete) {
            stop()
            shortcut = nil
            onChange?(nil)
            return
        }
        guard Keys.byCode(code) != nil else { NSSound.beep(); return }
        guard mods != 0 || Keys.isFunctionKey(code) else {
            NSSound.beep() // a bare letter would block normal typing
            return
        }
        stop()
        let s = Shortcut(keyCode: code, mods: mods)
        shortcut = s
        onChange?(s)
    }

    private func installTap() -> Bool {
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let button = Unmanaged<ShortcutButton>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                MainActor.assumeIsolated { if let t = button.tap { CGEvent.tapEnable(tap: t, enable: true) } }
                return Unmanaged.passUnretained(event)
            }
            guard type == .keyDown else { return Unmanaged.passUnretained(event) }
            let code = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
            let mods = Shortcut.mods(from: event.flags)
            DispatchQueue.main.async { button.handle(code: code, mods: mods) }
            return nil // swallow it: this key press was meant for us
        }
        guard let t = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
                                        callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        tap = t
        tapSource = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        return true
    }
}
