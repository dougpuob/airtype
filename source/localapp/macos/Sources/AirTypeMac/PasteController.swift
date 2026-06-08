import AppKit
import ApplicationServices
import Foundation

struct RunningAppIdentity {
    let bundleIdentifier: String?
    let localizedName: String?

    static func frontmost() -> RunningAppIdentity? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return RunningAppIdentity(
            bundleIdentifier: app.bundleIdentifier,
            localizedName: app.localizedName
        )
    }

    func activate() {
        if let bundleIdentifier,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
            app.activate(options: [.activateIgnoringOtherApps])
            return
        }

        if let localizedName {
            let script = """
            tell application "\(localizedName.replacingOccurrences(of: "\"", with: "\\\""))" to activate
            """
            runAppleScript(script)
        }
    }
}

final class PasteController {
    func paste(_ text: String, to app: RunningAppIdentity?) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // Check Accessibility permission before attempting to paste
        let accessibilityEnabled = AXIsProcessTrusted()
        if !accessibilityEnabled {
            Logger.shared.log("Accessibility permission not granted. Opening System Settings...")
            openAccessibilitySettings()
            Logger.shared.log("Please grant Accessibility permission for AirTypeMac in System Settings")
            return
        }

        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        app?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            let ok = runAppleScript("""
            tell application "System Events"
                keystroke "v" using command down
            end tell
            """)
            if ok {
                Logger.shared.log("Pasted ASR text at cursor")
            } else {
                Logger.shared.log("Paste failed. Check Accessibility permission for AirTypeMac.")
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                if NSPasteboard.general.string(forType: .string) == text, let previous {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(previous, forType: .string)
                }
            }
        }
    }

    private func openAccessibilitySettings() {
        DispatchQueue.main.async {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(url)
        }
    }
}

@discardableResult
func runAppleScript(_ script: String) -> Bool {
    var error: NSDictionary?
    let appleScript = NSAppleScript(source: script)
    appleScript?.executeAndReturnError(&error)
    if let error {
        Logger.shared.log("AppleScript failed: \(error)")
        return false
    }
    return true
}
