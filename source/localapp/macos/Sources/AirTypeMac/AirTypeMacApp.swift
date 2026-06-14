import SwiftUI

@main
struct AirTypeMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AirTypeCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.shared.startNewRunLog()
        NSApp.applicationIconImage = AirTypeIcon.appIcon()
        NSApp.setActivationPolicy(.accessory)
        coordinator = AirTypeCoordinator()
        coordinator?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
    }
}
