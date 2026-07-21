import Foundation
import AppKit

// Send the system Play/Pause media key so YouTube/Spotify pauses before we speak
// and resumes after. Uses the NSEvent systemDefined subtype-8 trick. Gated on
// Accessibility trust (the user grants it manually). Runtime-only.
enum MediaKeys {
    private static let NX_KEYTYPE_PLAY: Int32 = 16

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Check trust and, if not granted, show the system Accessibility prompt (adds the
    /// app to the list and opens System Settings). Safe to call at launch — no dialog
    /// if already trusted.
    @discardableResult
    static func ensureTrust(prompt: Bool = true) -> Bool {
        // Literal key avoids referencing the non-Sendable global kAXTrustedCheckOptionPrompt.
        return AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": prompt] as CFDictionary)
    }

    /// Toggle system play/pause. No-op (returns false) without Accessibility trust.
    @discardableResult
    static func togglePlayPause() -> Bool {
        guard isTrusted else {
            NSLog("Vloude: no Accessibility trust, skipping media key")
            return false
        }
        post(down: true)
        post(down: false)
        return true
    }

    private static func post(down: Bool) {
        let flags: NSEvent.ModifierFlags = down ? .init(rawValue: 0xa00) : .init(rawValue: 0xb00)
        let data1 = (Int(NX_KEYTYPE_PLAY) << 16) | ((down ? 0xa : 0xb) << 8)
        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        ) else { return }
        event.cgEvent?.post(tap: .cghidEventTap)
    }
}
