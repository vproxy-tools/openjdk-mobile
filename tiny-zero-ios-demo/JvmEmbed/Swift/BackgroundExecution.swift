import BackgroundTasks
import Foundation
import UIKit

/// Keeps the process (and therefore the embedded JVM thread) alive while the
/// app is in the background.
///
/// Two implementations:
///
/// 1. `ContinuedProcessingBackgroundExecution` (iOS 26+): the native
///    `BGContinuedProcessingTask` API. Per the SDK contract the request
///    "begins a workload immediately, or shortly after submission" — the
///    workload starts right away (foreground) and the system *adopts* it:
///    the launch handler may fire seconds after the submit, when the app is
///    backgrounded, or after a system relaunch of a killed process.
///    `begin()` therefore starts the work as soon as the submit is accepted;
///    the handler only attaches the task lifecycle (expiration handler +
///    NSProgress) or, in a relaunched process, starts the work headless.
///    The submit uses strategy `.fail` — the system either commits to
///    running the task now or throws on the spot — and there is **no silent
///    degradation**: a failed submit is reported verbatim and the JVM is not
///    started.
///
/// 2. `FallbackBackgroundExecution`: `UIApplication.beginBackgroundTask`,
///    used below iOS 26 where the continued processing API does not exist.
protocol BackgroundExecution: AnyObject {
    /// Human readable mode shown in the UI.
    var displayName: String { get }

    /// Failure description of the last `begin()` attempt (submit rejected,
    /// background task denied, ...). Nil when the claim succeeded.
    var lastError: String? { get }

    /// True while a granted system task keeps the process runnable in the
    /// background (adopted continued processing task / active background
    /// task assertion).
    var isClaimed: Bool { get }

    /// Installs the lifecycle callbacks. Called once at model init, so a
    /// system relaunch that fires the launch handler before any UI action
    /// still starts the JVM.
    /// `onLaunch` is invoked exactly once per claim when the real work may
    /// begin: right after a successful submit (continued processing starts
    /// the workload in the foreground), or in a relaunched process from the
    /// launch handler. `onExpire` is called when the granted window ends.
    func setHandlers(onLaunch: @escaping () -> Void,
                     onExpire: @escaping () -> Void)

    /// Starts claiming background runtime and begins the work (via
    /// `onLaunch`). Returns false if the system denied it (see
    /// `lastError`); the JVM is then not started.
    func begin() -> Bool

    /// Ends the claim (normal stop or JVM exit); also cancels a still
    /// pending submission so the system does not fire the handler for work
    /// that no longer exists.
    func end()
}

// MARK: - iOS 26 continued processing (native API)

/// Identifier rules, derived empirically on iOS 26.5 — all three checks must
/// pass or the task is never dispatched:
///   1. Info.plist BGTaskSchedulerPermittedIdentifiers matches EXACT
///      entries only (verified: neither a trailing "<x>.*" nor middle
///      wildcards match across dot segments), so the plist must list the
///      concrete identifier literally. Submitting the wildcard itself is
///      "Unrecognized Identifier", code 3. Consequence: a distribution
///      whose bundle id was rewritten by the signing tool (sideloaders
///      append ".<TEAMID>") cannot pass this gate - begin() pre-checks the
///      app's own plist and fails with a clear remedy instead.
///   2. register() and submit() must use the exact same concrete identifier
///      (a concrete submit against a wildcard registration crashes on an
///      NSAssertion).
///   3. The identifier prefix must contain the bundle ID with the exact same
///      case, otherwise submit passes but the handler never fires.
/// The identifiers are therefore derived from the bundle ID at runtime and
/// the plist entries use $(PRODUCT_BUNDLE_IDENTIFIER).
private var continuedBundleID: String {
    Bundle.main.bundleIdentifier ?? "com.example.TinyJvm"
}
private var continuedIdentifier: String { "\(continuedBundleID).continuedProcessing.demo" }

/// Must be called from `application(_:didFinishLaunchingWithOptions:)`
/// before the app finishes launching; registering twice for the same
/// identifier gets the process killed by the system.
func registerContinuedProcessingLaunchHandler() {
    guard #available(iOS 26.0, *) else { return }
    BGTaskScheduler.shared.register(forTaskWithIdentifier: continuedIdentifier, using: nil) { task in
        guard let continued = task as? BGContinuedProcessingTask else { return }
        ContinuedProcessingBackgroundExecution.shared.launchHandlerFired(continued)
    }
}

@available(iOS 26.0, *)
final class ContinuedProcessingBackgroundExecution: BackgroundExecution {

    static let shared = ContinuedProcessingBackgroundExecution()

    /// Title/subtitle of the submitted request; the system shows them in the
    /// notification center and on the lock screen while the task runs.
    /// Override before `begin()` to customize.
    var requestTitle = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        ?? "Embedded JVM"
    var requestSubtitle = "Embedded JVM background workload"

    let displayName = "BGContinuedProcessingTask(iOS 26)"
    private(set) var lastError: String? = nil
    private var task: BGContinuedProcessingTask?
    private var onLaunch: (() -> Void)?
    private var onExpire: (() -> Void)?
    /// Guards the single onLaunch delivery across the normal flow (submit
    /// success) and the system-relaunch flow (launch handler first).
    private var launchDelivered = false

    private init() {}

    var isClaimed: Bool { task != nil }

    func setHandlers(onLaunch: @escaping () -> Void,
                     onExpire: @escaping () -> Void) {
        self.onLaunch = onLaunch
        self.onExpire = onExpire
    }

    func begin() -> Bool {
        lastError = nil
        launchDelivered = false

        // The plist gate matches exact identifiers only (rule 1 above). A
        // rewritten bundle id (sideload tools append ".<TEAMID>") can never
        // match the build-time plist entries, so check our own Info.plist
        // up front and fail with a clear remedy instead of the raw
        // "Unrecognized Identifier" submit error.
        let permitted = Bundle.main.object(
            forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        guard permitted.contains(continuedIdentifier) else {
            lastError = "此安装的 bundle id 被签名工具改写为 \(continuedBundleID)，"
                + "后台任务标识 \(continuedIdentifier) 未列入 BGTaskSchedulerPermittedIdentifiers "
                + "白名单，后台模式不可用。请将此报错复制发送给开发者，据其中的 team id "
                + "构建专属 ipa 后后台模式即可使用；或关闭「后台任务」开关使用前台模式"
            return false
        }

        // Submitting a new request with the same id replaces the queued one.
        // Strategy .fail (SDK semantics, iOS 26): either the system commits
        // to running the task now or the submit throws immediately. The
        // .queue strategy parks the request at the back of a system queue
        // under load: submit "succeeds" but the task never starts.
        let request = BGContinuedProcessingTaskRequest(
            identifier: continuedIdentifier,
            title: requestTitle,
            subtitle: requestSubtitle)
        request.strategy = .fail

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // No degradation: report the raw system error and refuse to run.
            lastError = "BGContinuedProcessingTask submit 失败:\(Self.describeSubmitError(error))"
            return false
        }

        // The workload begins now, in the foreground; the launch handler
        // attaches the task lifecycle whenever the system adopts the work
        // (seconds later, on backgrounding, or after a process relaunch).
        launchDelivered = true
        onLaunch?()
        return true
    }

    /// Called by the launch handler registered in
    /// `registerContinuedProcessingLaunchHandler()`.
    func launchHandlerFired(_ task: BGContinuedProcessingTask) {
        self.task = task
        task.expirationHandler = { [weak self] in
            guard let self else { return }
            self.task = nil
            self.onExpire?()
            // The task MUST be completed on expiration: leaving it dangling
            // makes the system kill the process outright (SIGKILL). The JVM
            // thread is not exited here — the process simply gets suspended
            // and the work resumes when the app is foregrounded again.
            task.expirationHandler = nil
            task.setTaskCompleted(success: false)
        }

        // Report progress over the 30-day presentation window.
        task.progress.totalUnitCount = Int64(30 * 24 * 3600)

        // System relaunch: begin() never ran in this process, so the work
        // starts here, headless.
        if !launchDelivered {
            launchDelivered = true
            onLaunch?()
        }
    }

    /// Feeds the task's NSProgress (elapsed seconds within 30 days).
    func updateProgress(elapsedSeconds: TimeInterval) {
        task?.progress.completedUnitCount = Int64(elapsedSeconds)
    }

    func end() {
        launchDelivered = false
        // A still pending submission must not fire its handler for work
        // that no longer exists.
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: continuedIdentifier)
        let current = task
        task = nil
        // Nil the expiration handler first: we are ending voluntarily, this
        // is not an expiration.
        current?.expirationHandler = nil
        // Present the window as fully completed before closing the task.
        if let progress = current?.progress {
            progress.completedUnitCount = progress.totalUnitCount
        }
        current?.setTaskCompleted(success: true)
    }

    /// Maps BGTaskScheduler submit error codes to their documented causes so
    /// the UI report says why, not just "error 4".
    private static func describeSubmitError(_ error: Error) -> String {
        guard let bgError = error as? BGTaskScheduler.Error else { return "\(error)" }
        switch bgError.code {
        case .unavailable:
            return "\(error)(模拟器不支持后台处理)"
        case .tooManyPendingTaskRequests:
            return "\(error)(挂起的同类任务过多,请先停止再重试)"
        case .notPermitted:
            return "\(error)(Info.plist BGTaskSchedulerPermittedIdentifiers 不匹配或用户拒绝了后台启动)"
        case .immediateRunIneligible:
            return "\(error)(系统当前负载/条件不允许立即运行,.fail 语义)"
        @unknown default:
            return "\(error)"
        }
    }
}

// MARK: - Below iOS 26

final class FallbackBackgroundExecution: BackgroundExecution {

    var displayName = "iOS<26:beginBackgroundTask(约 30 秒–3 分钟)"
    var lastError: String? = nil

    private var task: UIBackgroundTaskIdentifier = .invalid
    private var onLaunch: (() -> Void)?
    private var onExpire: (() -> Void)?

    var isClaimed: Bool { task != .invalid }

    func setHandlers(onLaunch: @escaping () -> Void,
                     onExpire: @escaping () -> Void) {
        self.onLaunch = onLaunch
        self.onExpire = onExpire
    }

    func begin() -> Bool {
        end()
        task = UIApplication.shared.beginBackgroundTask(withName: "tinyjvm") { [weak self] in
            self?.onExpire?()
            self?.end()
        }
        guard task != .invalid else {
            lastError = "beginBackgroundTask 被系统拒绝"
            return false
        }
        onLaunch?()
        return true
    }

    func end() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}

// MARK: - Selection

func makeBackgroundExecution() -> BackgroundExecution {
    if #available(iOS 26.0, *) {
        return ContinuedProcessingBackgroundExecution.shared
    }
    return FallbackBackgroundExecution()
}
