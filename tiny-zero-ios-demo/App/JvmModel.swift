import Foundation
import Observation
import UIKit

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

    /// One console line as styled runs: the program's raw line with ANSI
    /// escape sequences parsed into segments, so only the parts actually
    /// covered by a color code are colored (vproxy colors just the
    /// timestamp/level prefix). `plainText` (for the persisted log) has all
    /// escapes stripped.
    struct LogLine {
        struct Segment {
            var text: String
            var color: Int // ANSI SGR foreground (30-37/90-97); 0 = default
        }

        var segments: [Segment]

        var plainText: String { segments.map(\.text).joined() }

        /// Parses the raw line: SGR color sequences (ESC [ … m) start new
        /// segments; every other escape sequence is dropped.
        init(raw: String) {
            var segments: [Segment] = []
            var text = ""
            var color = 0
            var i = raw.startIndex
            while i < raw.endIndex {
                let c = raw[i]
                if c != "\u{1B}" {
                    text.append(c)
                    i = raw.index(after: i)
                    continue
                }
                // Escape sequence: ESC '[' … final-byte, or ESC + one byte.
                var j = raw.index(after: i)
                if j < raw.endIndex, raw[j] == "[" {
                    var params = ""
                    var final: Character?
                    j = raw.index(after: j)
                    scan: while j < raw.endIndex {
                        let fc = raw[j]
                        if let a = fc.asciiValue, a >= 0x40, a <= 0x7E {
                            final = fc
                        } else {
                            params.append(fc)
                            j = raw.index(after: j)
                            continue
                        }
                        break scan
                    }
                    if final == "m" {
                        if !text.isEmpty {
                            segments.append(Segment(text: text, color: color))
                            text = ""
                        }
                        color = Self.applySgr(params, previous: color)
                    }
                }
                i = (j < raw.endIndex) ? raw.index(after: j) : j
            }
            segments.append(Segment(text: text, color: color))
            self.segments = segments
        }

        init(plain: String) {
            self.segments = [Segment(text: plain, color: 0)]
        }

        /// Applies one SGR parameter list ("0;32"); the last color wins and
        /// 0 resets to default.
        private static func applySgr(_ params: String, previous: Int) -> Int {
            var result = previous
            for token in params.split(separator: ";", omittingEmptySubsequences: false) {
                guard let code = Int(token.trimmingCharacters(in: .whitespaces)) else { continue }
                if (30...37).contains(code) || (90...97).contains(code) {
                    result = code
                } else if code == 0 {
                    result = 0
                }
            }
            return result
        }
    }

    struct PersistedState: Codable {
        var phase: Phase = .idle
        var lastLogAt: Date? = nil
    }

    // MARK: observable state

    private(set) var phase: Phase = .idle
    /// Mode switch: on = the JVM runs under a background task
    /// (BGContinuedProcessingTask / beginBackgroundTask); off = the JVM is
    /// started directly in foreground mode with no background claim.
    var useBackgroundTask: Bool = true
    private(set) var logLines: [LogLine] = []
    private(set) var errorMessage: String? = nil
    private(set) var elapsedSeconds: TimeInterval = 0
    private(set) var backgroundMode: String = ""

    static let taskWindow: TimeInterval = 30 * 24 * 3600 // 30 days
    private static let maxLogLines = 400

    // MARK: internals

    /// Builds a NULL-terminated C string array for the bridge API. The
    /// bridge copies the strings synchronously inside tinyvm_start, so
    /// freeing after the call returns is safe.
    private func makeCStringArray(_ strings: [String]) -> [UnsafeMutablePointer<CChar>?] {
        strings.map { s -> UnsafeMutablePointer<CChar>? in
            let bytes = Array(s.utf8CString) // includes the trailing null
            let p = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
            p.initialize(from: bytes, count: bytes.count)
            return p
        } + [nil]
    }

    private func freeCStringArray(_ array: [UnsafeMutablePointer<CChar>?]) {
        for p in array { p?.deallocate() }
    }

    private let backgroundExecution = makeBackgroundExecution()
    private var startedAt: Date?
    private var stopRequested = false
    private var tickTimer: Timer?
    private var lastStatePersist: Date = .distantPast
    private let ioQueue = DispatchQueue(label: "tinyvm.logio", qos: .utility)

    /// Passed as -Duser.home, so vproxy puts all of its state (including
    /// .vproxy/) inside the sandbox. Must be writable on real devices: the
    /// data container root itself is read-only there, while Documents/ is
    /// writable on both device and simulator.
    private var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    private var logFile: URL { documents.appendingPathComponent("java-console.log") }
    private var stateFile: URL { documents.appendingPathComponent("java-state.json") }

    // MARK: init / restore

    init() {
        backgroundMode = backgroundExecution.displayName
        if #available(iOS 26.0, *),
           let cp = backgroundExecution as? ContinuedProcessingBackgroundExecution {
            cp.requestTitle = "Tiny Zero HTTP Server"
            cp.requestSubtitle = "嵌入式 JVM 后台服务"
        }
        restoreFromDisk()
        // Wire the background-execution handlers before the UI exists: the
        // system may relaunch the app in the background for a submitted
        // continued-processing task, and the launch handler then starts the
        // JVM without any user interaction.
        wireBackgroundHandlers()
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.detectBackgroundSuspension() }
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
        }
        if let tail = readLogTail() {
            logLines = tail
        }
    }

    private func readLogTail() -> [LogLine]? {
        guard let handle = try? FileHandle(forReadingFrom: logFile) else { return nil }
        defer { try? handle.close() }
        let size = (try? logFile.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let window = max(0, size - 64 * 1024)
        if window > 0 {
            try? handle.seek(toOffset: UInt64(window))
        }
        let data = (try? handle.readToEnd()) ?? Data()
        let text = String(data: data, encoding: .utf8) ?? ""
        return text.split(separator: "\n").suffix(Self.maxLogLines).map { LogLine(plain: String($0)) }
    }

    // MARK: test automation hooks

    /// Supports `simctl launch ... -autostart [-direct]` and
    /// `-autostop <seconds>` so the demo can be verified end-to-end without
    /// UI interaction (used by the documented simulator test flow).
    /// `-direct` starts the JVM in foreground mode (no background task).
    func handleLaunchArguments() {
        guard phase == .idle else { return }
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-direct") {
            useBackgroundTask = false
        }
        if args.contains("-autostart") {
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

    func toggle() {
        canStop ? stop() : start()
    }

    func start() {
        guard canStart else { return }

        stopRequested = false
        errorMessage = nil
        phase = .starting

        if !useBackgroundTask {
            // Foreground mode: start the JVM directly, with no background
            // claim at all. Useful to isolate JVM behaviour from the
            // BGContinuedProcessingTask/beginBackgroundTask machinery.
            backgroundMode = "前台模式(直接运行,无后台任务)"
            launchJVM()
            return
        }

        // Continued processing semantics (iOS 26 SDK): the workload begins
        // immediately after a successful submit and the system adopts it via
        // the launch handler — seconds later, when backgrounded, or after a
        // process relaunch (from which the handler starts the JVM headless).
        // There is deliberately no degradation: a failed submit is reported
        // and the JVM is not started.
        guard backgroundExecution.begin() else {
            phase = .idle
            reportError((backgroundExecution.lastError ?? "系统拒绝了后台执行申请,未启动 JVM")
                + backgroundFailureHint)
            return
        }
    }

    private func wireBackgroundHandlers() {
        backgroundExecution.setHandlers(
            onLaunch: { [weak self] in
                DispatchQueue.main.async { self?.onBackgroundLaunch() }
            },
            onExpire: { [weak self] in
                DispatchQueue.main.async { self?.handleBackgroundExpired() }
            })
    }

    /// The workload may begin: right after a successful submit (normal
    /// flow, phase already .starting) or from the launch handler of a
    /// system-relaunched process (phase idle, headless continuation).
    private func onBackgroundLaunch() {
        if phase == .idle {
            appendLog("=== continued processing 后台重启进程,继续工作负载 ===")
            errorMessage = nil
            phase = .starting
            persistState()
        }
        launchJVM()
    }

    /// Returning to the foreground without an adopted task: if wall-clock
    /// time ran ahead of the live tick counter, the process was suspended
    /// during the background stay — report it instead of pretending the
    /// background window held.
    private func detectBackgroundSuspension() {
        guard phase == .running, useBackgroundTask, !backgroundExecution.isClaimed,
              let startedAt else { return }
        let gap = Date().timeIntervalSince(startedAt) - elapsedSeconds
        if gap > 90 {
            reportError("后台期间进程被挂起约 \(Int(gap)) 秒(continued processing 未接管);进程恢复,JVM 线程继续")
            persistState()
        }
    }

    /// The continued-processing grant does not exist on the simulator, so a
    /// background-task failure there is expected: tell the user the concrete
    /// way out instead of a dead end. On device there is nothing to add.
    private var backgroundFailureHint: String {
        #if targetEnvironment(simulator)
        return "(模拟器不支持后台任务;请关闭「后台任务运行 JVM」开关用前台模式重试)"
        #else
        return ""
        #endif
    }

    private func launchJVM() {
        guard phase == .starting else { return }

        // The runtime image folder reference is bundled as "lib"
        // (<bundle>/lib/lib/modules, see support/build-sim-jvm.sh).
        guard let libDir = Bundle.main.path(forResource: "lib", ofType: nil),
              FileManager.default.fileExists(atPath: libDir + "/lib/modules"),
              let vproxyJar = Bundle.main.path(forResource: "vproxy", ofType: "jar"),
              let bootstrapJar = Bundle.main.path(forResource: "vproxy-ios-bootstrap", ofType: "jar") else {
            phase = .idle
            reportError("bundle 资源不完整:需要 \(Bundle.main.bundlePath)/lib/lib/modules、vproxy.jar 与 vproxy-ios-bootstrap.jar;请重跑 support/build-sim-jvm.sh 和 support/build-java.sh")
            return
        }

        // vproxy runs with -Dvfd=posix, so its PosixFDs loads the embedded
        // libvfdposix framework through System.loadLibrary; both vproxy native
        // frameworks must be present in <bundle>/Frameworks.
        let frameworksDir = Bundle.main.bundleURL.appendingPathComponent("Frameworks").path
        for fw in ["libpni", "libvfdposix"] {
            guard FileManager.default.fileExists(atPath: "\(frameworksDir)/\(fw).framework/\(fw).dylib") else {
                phase = .idle
                reportError("bundle 缺少 \(fw).framework(-Dvfd=posix 需要);请重跑 support/build-java.sh 并重新构建 app")
                return
            }
        }

        // vproxy reads ${user.home}/.vproxy/resolv.conf before
        // /etc/resolv.conf; the bridge collects the system DNS servers into
        // that file via libresolv (same path on simulator and device).
        guard tinyvm_write_dns_config(documents.path, ".vproxy/resolv.conf") == 0 else {
            let detail = String(cString: tinyvm_last_error())
            backgroundExecution.end()
            phase = .idle
            reportError("DNS 配置写入失败:\(detail)")
            persistState()
            return
        }

        let jarPaths = "\(vproxyJar):\(bootstrapJar)"
        // -Deploy=helloworld is a program argument, exactly like the
        // documented `java -jar vproxy.jar -Deploy=helloworld` launch.
        // The --add-exports is vproxy's own suggestion at startup: it enables
        // its JDKUnsafe path instead of falling back with a reflection
        // warning. --enable-native-access keeps PNI's foreign-function
        // downcalls into the frameworks warning-free.
        // -Dvfd=posix makes vproxy use the native PosixFDs implementation
        // (epoll/kqueue-style ae event loop via libae) instead of the JDK
        // NIO based one; System.loadLibrary resolves "vfdposix" because
        // java.library.path lists the framework directories, whose inner
        // dylibs are named lib<name>.dylib exactly as the JVM expects.
        // libpni is on the path too: it is normally pulled in by dyld as
        // libvfdposix's @rpath dependency, but listing it keeps an explicit
        // System.loadLibrary("pni") working as well.
        var cArgs = makeCStringArray(["-Deploy=helloworld"])
        var cVmOptions = makeCStringArray(
            ["--add-exports=java.base/jdk.internal.misc=ALL-UNNAMED",
             "--enable-native-access=ALL-UNNAMED",
             "-Dvfd=posix",
             "-Djava.library.path=\(frameworksDir)/libpni.framework:\(frameworksDir)/libvfdposix.framework"])
        defer {
            freeCStringArray(cArgs)
            freeCStringArray(cVmOptions)
        }
        let rc = tinyvm_start(jarPaths, documents.path, "io.vproxy.app.app.Main",
                              &cArgs, &cVmOptions,
                              { JvmModel.shared.handleLogLine($0) },
                              { JvmModel.shared.handleExit($0, $1) })
        if rc != 0 {
            let detail = String(cString: tinyvm_last_error())
            backgroundExecution.end()
            phase = .idle
            reportError("JVM 启动失败:\(detail)")
            persistState()
            return
        }

        startedAt = Date()
        elapsedSeconds = 0
        phase = .running
        appendLog("=== 会话开始 \(Date().description(with: .current)) 模式=\(backgroundMode) ===")
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
            // The bridge first waits for a still-booting VM to appear, then
            // issues System.exit; the budget must cover both.
            let rc = tinyvm_stop(30)
            DispatchQueue.main.async {
                if rc != 0 {
                    // The process is still alive (JVM booting or the exit
                    // path stalled): restore the running state instead of
                    // pretending the stop worked.
                    self.phase = .running
                    self.errorMessage = "停止未完成(\(String(cString: tinyvm_last_error())));可重试,或上滑手动关闭应用"
                    self.persistState()
                    return
                }
                self.phase = .idle
                self.stopTicking()
                self.appendLog("=== 会话结束 ===")
                self.persistState()
            }
        }
    }

    // MARK: callbacks from the native bridge (JVM thread)

    private func handleLogLine(_ raw: UnsafePointer<CChar>?) {
        guard let raw else { return }
        let line = LogLine(raw: String(cString: raw))
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.appendLog(line)
            // lastLogAt feeds the relaunch report; persisting on every line
            // would re-encode and rewrite the state file per log line.
            if Date().timeIntervalSince(self.lastStatePersist) > 5 {
                self.lastStatePersist = Date()
                self.persistState()
            }
        }
    }

    private func handleExit(_ code: Int32, _ reason: UnsafePointer<CChar>?) {
        let why = reason.map { String(cString: $0) } ?? "?"
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.stopTicking()
            self.backgroundExecution.end() // no-op when nothing was claimed
            let wasUserStop = self.stopRequested
            self.phase = .idle
            self.appendLog("[native] JVM 退出 code=\(code) reason=\(why)")
            if !wasUserStop || code != 0 {
                self.errorMessage = "后台程序退出:code=\(code) reason=\(why)"
            }
            self.persistState()
        }
    }

    private func handleBackgroundExpired() {
        guard phase == .running || phase == .starting else { return }
        appendLog("[app] 后台任务被系统收回(expiration),任务已收尾;进程随后会被挂起,JVM 线程暂停")
        errorMessage = "后台任务被系统收回:任务已正常收尾,进程被挂起(回前台后 JVM 继续)"
        persistState()
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

    private func appendLog(_ line: LogLine) {
        logLines.append(line)
        if logLines.count > Self.maxLogLines {
            logLines.removeFirst(logLines.count - Self.maxLogLines)
        }
        let data = Data((line.plainText + "\n").utf8)
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

    private func appendLog(_ text: String) {
        appendLog(LogLine(plain: text))
    }

    /// Surfaces an error to the UI and records it in the console log.
    private func reportError(_ text: String) {
        errorMessage = text
        appendLog("[app] \(text)")
    }

    private func persistState() {
        let state = PersistedState(
            phase: phase,
            lastLogAt: Date())
        ioQueue.async { [stateFile, state] in
            if let data = try? JSONEncoder().encode(state) {
                try? data.write(to: stateFile, options: .atomic)
            }
        }
    }
}
