import AppKit

enum StatusIcon {
    static func make(recording: Bool) -> NSImage {
        AirTypeIcon.statusIcon(recording: recording)
    }
}
