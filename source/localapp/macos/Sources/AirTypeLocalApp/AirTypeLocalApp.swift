import SwiftUI

@main
struct AirTypeLocalApp: App {
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
        if SelfTest.runIfRequested() { return }
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
