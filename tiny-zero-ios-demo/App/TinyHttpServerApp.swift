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
    @State private var model = JvmModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
        }
    }
}
