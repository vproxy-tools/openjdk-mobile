import BackgroundTasks
import Foundation
import UIKit

/// Keeps the process (and therefore the embedded JVM thread) alive while the
/// app is in the background.
///
/// Two implementations:
///
/// 1. `ContinuedProcessingBackgroundExecution` (iOS 26+): the native
///    `BGContinuedProcessingTask` API — no reflection and **no silent
///    degradation**: `begin()` submits a `BGContinuedProcessingTaskRequest`
///    and the JVM is started from the task's launch handler. If the submit
///    fails, or the launch handler is not run within the grant window, the
///    failure is reported verbatim (`lastError` / `onFail`) and the JVM is
///    not started. The granted window is presented as 30 days and reported
///    through `NSProgress` (the task conforms to `NSProgressReporting`).
///
/// 2. `FallbackBackgroundExecution`: `UIApplication.beginBackgroundTask`,
///    used below iOS 26 where the continued processing API does not exist.
protocol BackgroundExecution: AnyObject {
    /// Human readable mode shown in the UI.
    var displayName: String { get }

    /// Failure description of the last `begin()` attempt (submit rejected,
    /// launch handler never fired, ...). Nil when the claim succeeded.
    var lastError: String? { get }

    /// Starts claiming background runtime. Returns false if the system
    /// denied it (see `lastError`). `onLaunch` is invoked exactly once when
    /// the real work may start (from the BGContinuedProcessingTask launch
    /// handler, or immediately below iOS 26). `onExpire` is called when the
    /// granted window ends. `onFail` is called when a submitted task is
    /// later rejected (launch handler never fired).
    func begin(onLaunch: @escaping () -> Void,
               onExpire: @escaping () -> Void,
               onFail: @escaping (String) -> Void) -> Bool

    /// Ends the claim (normal stop).
    func end()
}

// MARK: - iOS 26 continued processing (native API)

/// Task identifier, also advertised in Info.plist
/// (BGTaskSchedulerPermittedIdentifiers). iOS 26.5 rejects the wildcard
/// notation suggested by the SDK headers ("Invalid identifier form for
/// Continued Processing Task"), so a fixed concrete identifier is used.
private let continuedIdentifier = "com.wkgcass.tinyhttpserver.continued.demo"

/// How long to wait for the launch handler after a successful submit before
/// reporting failure. On a real device the handler fires immediately while
/// the app is foregrounded.
private let launchGrantTimeout: TimeInterval = 10

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

    private(set) var displayName = "BGContinuedProcessingTask(iOS 26)"
    private(set) var lastError: String? = nil
    private var task: BGContinuedProcessingTask?
    private var onLaunch: (() -> Void)?
    private var onExpire: (() -> Void)?
    private var onFail: ((String) -> Void)?
    private var launchGrantTimer: Timer?

    private init() {}

    func begin(onLaunch: @escaping () -> Void,
               onExpire: @escaping () -> Void,
               onFail: @escaping (String) -> Void) -> Bool {
        self.onLaunch = onLaunch
        self.onExpire = onExpire
        self.onFail = onFail
        lastError = nil

        // Submitting a new request with the same id replaces the queued one.
        let request = BGContinuedProcessingTaskRequest(
            identifier: continuedIdentifier,
            title: "Tiny Zero HTTP Server",
            subtitle: "嵌入式 JVM 后台服务")
        request.strategy = .queue

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // No degradation: report the raw system error and refuse to run.
            lastError = "BGContinuedProcessingTask submit 失败:\(error)"
            displayName = "BGContinuedProcessingTask 提交失败"
            return false
        }

        displayName = "BGContinuedProcessingTask(已提交,等待系统授予)"
        launchGrantTimer = Timer.scheduledTimer(withTimeInterval: launchGrantTimeout, repeats: false) { [weak self] _ in
            guard let self, self.task == nil else { return }
            self.lastError = "launchHandler \(Int(launchGrantTimeout)) 秒内未触发(系统未授予 continued processing)"
            self.displayName = "BGContinuedProcessingTask 未授予"
            self.onFail?(self.lastError!)
        }
        return true
    }

    /// Called by the launch handler registered in
    /// `registerContinuedProcessingLaunchHandler()`.
    func launchHandlerFired(_ task: BGContinuedProcessingTask) {
        self.task = task
        displayName = "BGContinuedProcessingTask(iOS 26,已授予)"
        launchGrantTimer?.invalidate()
        launchGrantTimer = nil

        task.expirationHandler = { [weak self] in
            guard let self else { return }
            self.task = nil
            self.onExpire?()
        }

        // Report progress over the 30-day presentation window.
        task.progress.totalUnitCount = Int64(30 * 24 * 3600)

        onLaunch?()
    }

    /// Feeds the task's NSProgress (elapsed seconds within 30 days).
    func updateProgress(elapsedSeconds: TimeInterval) {
        task?.progress.completedUnitCount = Int64(elapsedSeconds)
    }

    func end() {
        launchGrantTimer?.invalidate()
        launchGrantTimer = nil
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
}

// MARK: - Below iOS 26

final class FallbackBackgroundExecution: BackgroundExecution {

    var displayName = "iOS<26:beginBackgroundTask(约 30 秒–3 分钟)"
    var lastError: String? = nil

    private var task: UIBackgroundTaskIdentifier = .invalid

    func begin(onLaunch: @escaping () -> Void,
               onExpire: @escaping () -> Void,
               onFail: @escaping (String) -> Void) -> Bool {
        end()
        task = UIApplication.shared.beginBackgroundTask(withName: "tinyjvm") {
            onExpire()
            self.end()
        }
        guard task != .invalid else {
            lastError = "beginBackgroundTask 被系统拒绝"
            return false
        }
        onLaunch()
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
