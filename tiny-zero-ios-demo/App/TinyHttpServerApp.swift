import SwiftUI
import UIKit

/// BGTaskScheduler launch handlers must be registered before the app finishes
/// launching, hence the classic AppDelegate adaptor.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        registerContinuedProcessingLaunchHandler()
        return true
    }
}

@main
struct TinyHttpServerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Must be the shared instance: the native bridge's log/exit callbacks
    // target JvmModel.shared, so a separate instance here would leave the
    // UI console without any JVM output.
    @State private var model = JvmModel.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
        }
    }
}
