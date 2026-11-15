import Darwin
import Foundation

enum Paths {
    private static let env = ProcessInfo.processInfo.environment
    private static let home = URL(fileURLWithPath: NSHomeDirectory())

    static var config: URL {
        if let e = env["XSWITCHER_CONFIG"], !e.isEmpty { return URL(fileURLWithPath: e) }
        if let x = env["XDG_CONFIG_HOME"], !x.isEmpty { return URL(fileURLWithPath: x).appendingPathComponent("xswitcher/config") }
        return home.appendingPathComponent(".config/xswitcher/config")
    }

    static var support: URL {
        if let e = env["XSWITCHER_SUPPORT_DIR"], !e.isEmpty { return URL(fileURLWithPath: e) }
        return home.appendingPathComponent("Library/Application Support/XSwitcher")
    }

    static var status: URL { support.appendingPathComponent("status") }

    /// This Settings helper lives in XSwitcher.app/Contents/Helpers/.
    static var mainApp: URL {
        Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static var agent: URL { mainApp.appendingPathComponent("Contents/MacOS/xswitcher-agent") }
}

/// What the agent last reported in its status file.
struct AgentStatus {
    let values: [String: String]

    var pid: pid_t? { values["pid"].flatMap { pid_t($0) } }
    var isRunning: Bool { pid.map { kill($0, 0) == 0 } ?? false }
    // An installed tap is proof of access too (taps fail without it).
    var hasAccessibility: Bool {
        values["accessibility"] == "yes" || values["hotkey_tap"] == "yes" || values["swipe_tap"] == "yes"
    }
    var trackpadGestureOn: Bool { values["trackpad_gesture"] != "off" }
    var configOK: Bool { values["config_ok"] != "no" }
    var failedShortcuts: [String] { (values["hotkeys_failed"] ?? "").split(separator: ",").map(String.init) }
}

/// The switcher itself is XSwitcher.app's main program. This window only
/// talks to it: config file + signals + a couple of notifications.
enum Agent {
    static func status() -> AgentStatus? {
        guard let text = try? String(contentsOf: Paths.status, encoding: .utf8) else { return nil }
        var v: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { v[kv[0]] = kv[1] }
        }
        return AgentStatus(values: v)
    }

    static var runningPID: pid_t? {
        guard let s = status(), s.isRunning else { return nil }
        return s.pid
    }

    /// Opens XSwitcher.app through LaunchServices, so it runs as the app
    /// (and macOS checks XSwitcher's own permission, not this window's).
    static func start() {
        guard runningPID == nil else { return }
        run("/usr/bin/open", ["-g", "-a", Paths.mainApp.path, "--args", "--no-settings", "--no-menubar-launch"])
    }

    static func ensureRunning() { if runningPID == nil { start() } }

    static func reload() { send(SIGHUP) }
    static func pause() { send(SIGUSR1) }
    static func resume() { send(SIGUSR2) }

    /// Asks XSwitcher to quit and waits up to a second.
    static func stop() {
        guard let pid = runningPID else { return }
        kill(pid, SIGTERM)
        for _ in 0..<40 where kill(pid, 0) == 0 { usleep(25_000) }
    }

    static func goTo(desktop n: Int) { post("local.xswitcher.goto", ["index": n]) }

    /// Clears stale Accessibility entries left by older builds (a new
    /// signature makes the old switch show "on" but do nothing), then asks
    /// XSwitcher to show macOS's prompt, which adds a fresh entry.
    static func requestAccess() {
        run("/usr/bin/tccutil", ["reset", "Accessibility", "local.xswitcher"], wait: true)
        post("local.xswitcher.requestAccess", nil)
    }

    private static func send(_ sig: Int32) {
        if let pid = runningPID { kill(pid, sig) }
    }

    private static func post(_ name: String, _ info: [String: Any]?) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(name), object: nil, userInfo: info, deliverImmediately: true)
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String], wait: Bool = false) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        guard wait else { return "" }
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// "Open at login" for XSwitcher.app. Done by the main program
/// (SMAppService.mainApp must run inside XSwitcher.app's own executable).
enum LoginItem {
    enum State: String { case on, off, needsApproval = "needs-approval" }

    static func state() -> State {
        State(rawValue: Agent.run(Paths.agent.path, ["login", "status"], wait: true)) ?? .off
    }

    @discardableResult
    static func set(_ on: Bool) -> State {
        State(rawValue: Agent.run(Paths.agent.path, ["login", on ? "on" : "off"], wait: true)) ?? .off
    }
}
