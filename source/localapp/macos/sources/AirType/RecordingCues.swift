import AppKit
import Foundation

/// Quiet local recording cues. Does not change global output volume.
///
/// System Settings display names (Jump / Pebble / Boop) map to legacy files under
/// `/System/Library/Sounds/` via `Sound.appex` `AlertSounds.loctable` (en):
/// Frog → Jump, Bottle → Pebble, Tink → Boop. `NSSound(named: "Jump"|"Pebble")` is nil;
/// load the verified file URLs instead.
enum RecordingCues {
    private static let cueVolume: Float = 0.32
    private static let soundsDirectory = URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true)

    /// System Settings “Boop”.
    static let startDisplayName = "Boop"
    static let startFileName = "Tink.aiff"

    /// System Settings “Jump”.
    static let successDisplayName = "Jump"
    static let successFileName = "Frog.aiff"

    /// System Settings “Pebble”.
    static let failureDisplayName = "Pebble"
    static let failureFileName = "Bottle.aiff"

    static func playStart() {
        playSystemSound(fileName: startFileName, displayName: startDisplayName)
    }

    static func playSuccess() {
        playSystemSound(fileName: successFileName, displayName: successDisplayName)
    }

    static func playFailure() {
        playSystemSound(fileName: failureFileName, displayName: failureDisplayName)
    }

    /// True when the exact installed file for a Settings display name is readable.
    static func installedFileAvailable(displayName: String) -> Bool {
        guard let file = fileName(forDisplayName: displayName) else { return false }
        return FileManager.default.isReadableFile(atPath: soundsDirectory.appendingPathComponent(file).path)
    }

    static func fileName(forDisplayName displayName: String) -> String? {
        switch displayName {
        case startDisplayName: return startFileName
        case successDisplayName: return successFileName
        case failureDisplayName: return failureFileName
        default: return nil
        }
    }

    /// Load exact system AIFF by path. No silent substitute with a different cue identity.
    private static func playSystemSound(fileName: String, displayName: String) {
        let url = soundsDirectory.appendingPathComponent(fileName)
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            Logger.shared.log(
                "Recording cue missing exact asset: display=\(displayName) file=\(url.path)"
            )
            return
        }
        guard let sound = NSSound(contentsOf: url, byReference: true) else {
            Logger.shared.log(
                "Recording cue failed to load: display=\(displayName) file=\(url.path)"
            )
            return
        }
        sound.volume = cueVolume
        sound.play()
    }
}

/// At-most-one terminal cue (success or failure/cancel) per input session id.
struct RecordingSessionCueGate {
    private var closedInputIDs: Set<Int> = []
    private var terminalCuePlayed: Set<Int> = []

    mutating func isClosed(_ inputID: Int) -> Bool {
        closedInputIDs.contains(inputID)
    }

    @discardableResult
    mutating func close(_ inputID: Int) -> Bool {
        if closedInputIDs.contains(inputID) { return false }
        closedInputIDs.insert(inputID)
        pruneIfNeeded()
        return true
    }

    mutating func playTerminal(inputID: Int, success: Bool, cuesEnabled: Bool) {
        guard cuesEnabled else { return }
        guard !terminalCuePlayed.contains(inputID) else { return }
        terminalCuePlayed.insert(inputID)
        if success {
            RecordingCues.playSuccess()
        } else {
            RecordingCues.playFailure()
        }
        pruneIfNeeded()
    }

    private mutating func pruneIfNeeded() {
        if closedInputIDs.count > 64 {
            closedInputIDs = Set(closedInputIDs.sorted().suffix(32))
        }
        if terminalCuePlayed.count > 64 {
            terminalCuePlayed = Set(terminalCuePlayed.sorted().suffix(32))
        }
    }
}
