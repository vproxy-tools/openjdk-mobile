import Foundation
import Observation

/// App-wide observable state: JVM lifecycle, persisted log/status, the
/// 30-day background progress and the error surfaced to the UI.
///
/// Everything that survives a process restart lives in Documents/
/// (java-console.log + java-state.json), so relaunching the app after a full
/// termination still shows what the background program did and how it ended.
@Observable
final class JvmModel {

    static let shared = JvmModel()

    enum Phase: String, Codable {
        case idle, starting, running, stopping
    }

    struct PersistedState: Codable {
        var phase: Phase = .idle
        var port: Int = 8080
        var startedAt: Date? = nil
        var lastLogAt: Date? = nil
        var backgroundMode: String = ""
        var exitReason: String? = nil
    }

    // MARK: observable state

    private(set) var phase: Phase = .idle
    var portText: String = "8080"
    /// Mode switch: on = the JVM runs under a background task
    /// (BGContinuedProcessingTask / beginBackgroundTask); off = the JVM is
    /// started directly in foreground mode with no background claim.
    var useBackgroundTask: Bool = true
    private(set) var logLines: [String] = []
    private(set) var errorMessage: String? = nil
    private(set) var elapsedSeconds: TimeInterval = 0
    private(set) var backgroundMode: String = ""

    static let taskWindow: TimeInterval = 30 * 24 * 3600 // 30 days
    private static let maxLogLines = 400

    // MARK: internals

    private let backgroundExecution = makeBackgroundExecution()
    private var startedAt: Date?
    private var stopRequested = false
    private var tickTimer: Timer?
    private let ioQueue = DispatchQueue(label: "tinyvm.logio", qos: .utility)

    private var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    private var logFile: URL { documents.appendingPathComponent("java-console.log") }
    private var stateFile: URL { documents.appendingPathComponent("java-state.json") }

    // MARK: init / restore

    init() {
        backgroundMode = backgroundExecution.displayName
        restoreFromDisk()
    }

    private func restoreFromDisk() {
        if let data = try? Data(contentsOf: stateFile),
           let state = try? JSONDecoder().decode(PersistedState.self, from: data) {
            if state.phase == .running || state.phase == .starting {
                // The process restarted (e.g. user swiped the app away), so no
                // JVM can be alive; report the interruption explicitly.
                let when = state.lastLogAt.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .medium) } ?? "?"
                errorMessage = "上次会话在进程被终止时中断(最后活动:\(when))。日志已从磁盘恢复。"
            }
            portText = String(state.port)
        }
        if let tail = readLogTail() {
            logLines = tail
        }
    }

    private func readLogTail() -> [String]? {
        guard let handle = try? FileHandle(forReadingFrom: logFile) else { return nil }
        defer { try? handle.close() }
        let size = (try? logFile.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let window = max(0, size - 64 * 1024)
        if window > 0 {
            try? handle.seek(toOffset: UInt64(window))
        }
        let data = (try? handle.readToEnd()) ?? Data()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.split(separator: "\n").suffix(Self.maxLogLines).map(String.init)
    }

    // MARK: test automation hooks

    /// Supports `simctl launch ... -autostart <port> [-direct]` and
    /// `-autostop <seconds>` so the demo can be verified end-to-end without
    /// UI interaction (used by the documented simulator test flow).
    /// `-direct` starts the JVM in foreground mode (no background task).
    func handleLaunchArguments() {
        guard phase == .idle else { return }
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-direct") {
            useBackgroundTask = false
        }
        if let i = args.firstIndex(of: "-autostart"), i + 1 < args.count {
            portText = args[i + 1]
            start()
        }
        if let i = args.firstIndex(of: "-autostop"), i + 1 < args.count,
           let delay = Double(args[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                if let self, self.canStop {
                    self.stop()
                }
            }
        }
    }

    // MARK: actions

    var canStart: Bool { phase == .idle }
    var canStop: Bool { phase == .running || phase == .starting }
    /// The mode switch can only be changed while idle.
    var canSwitchMode: Bool { phase == .idle }

    func toggle() {
        canStop ? stop() : start()
    }

    func start() {
        guard canStart else { return }
        guard let port = Int(portText.trimmingCharacters(in: .whitespaces)), (1...65535).contains(port) else {
            errorMessage = "端口无效:\(portText)(需要 1–65535 的数字)"
            return
        }

        stopRequested = false
        errorMessage = nil
        phase = .starting

        if !useBackgroundTask {
            // Foreground mode: start the JVM directly, with no background
            // claim at all. Useful to isolate JVM behaviour from the
            // BGContinuedProcessingTask/beginBackgroundTask machinery.
            backgroundMode = "前台模式(直接运行,无后台任务)"
            launchJVM(port: port)
            return
        }

        // The JVM is started from the background task's launch callback
        // (BGContinuedProcessingTask on iOS 26), so the program genuinely
        // runs as a continued processing task, not as a foreground thread.
        // There is deliberately no degradation: a failed submit is reported
        // and the JVM is not started.
        guard backgroundExecution.begin(onLaunch: { [weak self] in
            DispatchQueue.main.async { self?.launchJVM(port: port) }
        }, onExpire: { [weak self] in
            DispatchQueue.main.async { self?.handleBackgroundExpired() }
        }, onFail: { [weak self] message in
            DispatchQueue.main.async {
                guard let self, self.phase == .starting else { return }
                self.phase = .idle
                self.errorMessage = "后台任务失败:\(message)"
                self.appendLog("[app] 后台任务失败:\(message)")
                self.persistState(exitReason: self.errorMessage)
            }
        }) else {
            phase = .idle
            errorMessage = backgroundExecution.lastError ?? "系统拒绝了后台执行申请,未启动 JVM"
            appendLog("[app] \(errorMessage ?? "")")
            return
        }
    }

    private func launchJVM(port: Int) {
        guard phase == .starting else { return }

        // The runtime image folder reference is bundled as "lib"
        // (<bundle>/lib/lib/modules, see support/build-sim-jvm.sh).
        guard let libDir = Bundle.main.path(forResource: "lib", ofType: nil),
              FileManager.default.fileExists(atPath: libDir + "/lib/modules"),
              let jar = Bundle.main.path(forResource: "TinyHttpServer", ofType: "jar") else {
            phase = .idle
            errorMessage = "bundle 里缺少 runtime/ 或 TinyHttpServer.jar"
            return
        }

        let rc = tinyvm_start(libDir, jar, Int32(port),
                              { JvmModel.shared.handleLogLine($0) },
                              { JvmModel.shared.handleExit($0, $1) })
        if rc != 0 {
            backgroundExecution.end()
            phase = .idle
            errorMessage = "JVM 启动失败:\(String(cString: tinyvm_last_error()))"
            appendLog("[app] JVM 启动失败:\(String(cString: tinyvm_last_error()))")
            persistState(exitReason: errorMessage)
            return
        }

        startedAt = Date()
        elapsedSeconds = 0
        phase = .running
        appendLog("=== 会话开始 \(Date().description(with: .current)) 端口=\(port) 模式=\(backgroundExecution.displayName) ===")
        startTicking()
        persistState()
    }

    func stop() {
        guard canStop else { return }
        stopRequested = true
        phase = .stopping
        // Finish the background task up front (fills its NSProgress, then
        // setTaskCompleted) so the system-side window is closed cleanly
        // before the process exits.
        if useBackgroundTask {
            backgroundExecution.end()
        }
        appendLog("[app] 用户请求停止并退出…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let rc = tinyvm_stop(10)
            DispatchQueue.main.async {
                if rc != 0 {
                    self.errorMessage = "退出未完成(\(String(cString: tinyvm_last_error())));请上滑手动关闭应用"
                }
                if self.useBackgroundTask {
                    self.backgroundExecution.end()
                }
                self.phase = .idle
                self.stopTicking()
                self.appendLog("=== 会话结束 ===")
                self.persistState(exitReason: "用户停止")
            }
        }
    }

    // MARK: callbacks from the native bridge (JVM thread)

    private func handleLogLine(_ raw: UnsafePointer<CChar>?) {
        guard let raw else { return }
        let line = String(cString: raw)
        DispatchQueue.main.async { [weak self] in
            self?.appendLog(line)
            self?.persistState() // refreshes lastLogAt for relaunch reporting
        }
    }

    private func handleExit(_ code: Int32, _ reason: UnsafePointer<CChar>?) {
        let why = reason.map { String(cString: $0) } ?? "?"
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stopTicking()
            if self.useBackgroundTask {
                self.backgroundExecution.end()
            }
            let wasUserStop = self.stopRequested
            self.phase = .idle
            self.appendLog("[native] JVM 退出 code=\(code) reason=\(why)")
            if !wasUserStop || code != 0 {
                self.errorMessage = "后台程序退出:code=\(code) reason=\(why)"
            }
            self.persistState(exitReason: self.errorMessage ?? "main 正常返回")
        }
    }

    private func handleBackgroundExpired() {
        guard phase == .running || phase == .starting else { return }
        appendLog("[app] 后台任务到期,系统即将挂起进程(JVM 将暂停)")
        errorMessage = "后台任务到期:系统挂起了进程"
        persistState(exitReason: "后台任务到期,进程被挂起")
        // The JVM thread itself keeps its state; the process is merely
        // suspended. Do not mark it as exited.
    }

    // MARK: 30-day progress

    var progress: Double {
        // The stop path exits the process; show the window as completed
        // instead of frozen mid-way.
        if phase == .stopping { return 1 }
        guard phase == .running, let startedAt else { return 0 }
        return min(1, elapsedSeconds / Self.taskWindow)
    }

    var remainingText: String {
        if phase == .stopping { return "后台任务已完成,正在退出" }
        guard phase == .running, let startedAt else { return "未运行" }
        let rem = max(0, Self.taskWindow - elapsedSeconds)
        let d = Int(rem) / 86400, h = (Int(rem) % 86400) / 3600, m = (Int(rem) % 3600) / 60
        return String(format: "剩余 %dd %02dh %02dm / 30 天", d, h, m)
    }

    private func startTicking() {
        tickTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, let s = self.startedAt else { return }
            self.elapsedSeconds = Date().timeIntervalSince(s)
            // Feed the task's NSProgress so the system UI reflects it too.
            if #available(iOS 26.0, *),
               let cp = self.backgroundExecution as? ContinuedProcessingBackgroundExecution {
                cp.updateProgress(elapsedSeconds: self.elapsedSeconds)
            }
        }
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
        elapsedSeconds = 0
    }

    // MARK: persistence

    private func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > Self.maxLogLines {
            logLines.removeFirst(logLines.count - Self.maxLogLines)
        }
        let data = Data((line + "\n").utf8)
        ioQueue.async { [logFile] in
            if let handle = try? FileHandle(forWritingTo: logFile) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: logFile)
            }
        }
    }

    private func persistState(exitReason: String? = nil) {
        let state = PersistedState(
            phase: phase,
            port: Int(portText) ?? 0,
            startedAt: startedAt,
            lastLogAt: Date(),
            backgroundMode: backgroundExecution.displayName,
            exitReason: exitReason)
        ioQueue.async { [stateFile, state] in
            if let data = try? JSONEncoder().encode(state) {
                try? data.write(to: stateFile, options: .atomic)
            }
        }
    }
}
