import Darwin
import Foundation
import ServiceManagement

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
    static var log: URL { support.appendingPathComponent("agent.log") }
    static var agent: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/xswitcher-agent") }
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

/// Starts, signals and stops the background agent.
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

    static func ensureRunning() {
        if runningPID == nil { start() }
    }

    /// Launches the agent in its own session so it outlives this window.
    /// It refuses to run twice (lock file), so calling this is always safe.
    static func start() {
        guard runningPID == nil else { return }
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        spawn(["run", "--no-prompt", "--no-menubar-launch"], logTo: Paths.log.path)
    }

    /// Runs the agent once, e.g. ["index", "3"], without waiting.
    static func runOnce(_ args: [String]) {
        spawn(args, logTo: "/dev/null")
    }

    static func reload() { send(SIGHUP) }
    static func pause() { send(SIGUSR1) }
    static func resume() { send(SIGUSR2) }

    /// Asks the agent to quit and waits up to a second for it.
    static func stop() {
        guard let pid = runningPID else { return }
        kill(pid, SIGTERM)
        for _ in 0..<40 where kill(pid, 0) == 0 { usleep(25_000) }
    }

    private static func send(_ sig: Int32) {
        if let pid = runningPID { kill(pid, sig) }
    }

    private static func spawn(_ args: [String], logTo log: String) {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fa, 1, log, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&fa, 1, 2)
        defer {
            posix_spawnattr_destroy(&attr)
            posix_spawn_file_actions_destroy(&fa)
        }
        let path = Paths.agent.path
        let argv: [UnsafeMutablePointer<CChar>?] = ([path] + args).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, path, &fa, &attr, argv, envp) == 0 else { return }
        DispatchQueue.global(qos: .utility).async {
            var st: Int32 = 0
            waitpid(pid, &st, 0) // reap it if it exits while we are still open
        }
    }
}

/// "Open at login": registers the agent's LaunchAgent with launchd.
enum LoginItem {
    static let service = SMAppService.agent(plistName: "local.xswitcher.agent.plist")

    static var isEnabled: Bool { service.status == .enabled }
    static var needsApproval: Bool { service.status == .requiresApproval }

    /// A new build has a new ad-hoc signature, and launchd refuses to start
    /// the registered agent until it is registered again. Returns true if it
    /// had to do that.
    /// Calls `done` once the agent should be up again. Registering right
    /// after unregistering doesn't take, so it waits a second in between.
    static func repairIfNeeded(then done: @escaping () -> Void) -> Bool {
        guard isEnabled, Agent.runningPID == nil else { return false }
        try? service.unregister()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            try? service.register()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { done() }
        }
        return true
    }

    static func set(_ on: Bool) throws {
        if on {
            Agent.stop() // launchd starts its own copy right away
            try service.register()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { Agent.ensureRunning() }
        } else {
            try service.unregister()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Agent.ensureRunning() }
        }
    }
}
