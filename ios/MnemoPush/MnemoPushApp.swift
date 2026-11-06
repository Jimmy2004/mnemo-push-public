import SwiftUI
import BackgroundTasks
import MnemoCore
@MainActor final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: SyncModel.identifier, using: .main) { task in
            guard let refresh = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in SyncModel.shared.handle(refresh) }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: SyncModel.processIdentifier, using: .main) { task in
            Task { @MainActor in SyncModel.shared.handle(task) }
        }
        SyncModel.shared.applyKeepAlive()
        if launchOptions?[.location] != nil { KeepAliveController.shared.restoreLocationLaunch() }
        Task { await SyncModel.shared.refreshUploads() }
        return true
    }
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == "dev.mnemo.push.upload" else { completionHandler(); return }
        Task { await BackgroundUploader.shared.handleEvents(completion: completionHandler) }
    }
}
@main @MainActor struct MnemoPushApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @Environment(\.scenePhase) var phase
    var body: some Scene {
        WindowGroup { ContentView().onChange(of: phase) { phase in
            if phase == .active { SyncModel.shared.foreground() }
            if phase == .background {
                do { try SyncModel.shared.schedule() } catch { SyncModel.shared.notice = "后台调度失败，请检查系统设置" }
            }
        } }
    }
}
