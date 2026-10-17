import Foundation
import Testing
@testable import ParleyMobile

struct PushTests {
    @Test func labelFromTheHostsPayload() {
        #expect(PushPayload.label(["label": "Tippfrei"]) == "Tippfrei")
        #expect(PushPayload.label(["aps": ["content-available": 1], "label": "  Shirts \n"]) == "Shirts")
        #expect(PushPayload.label(["label": "   "]) == nil)
        #expect(PushPayload.label(["label": 42]) == nil)
        #expect(PushPayload.label([:]) == nil)
    }

    @Test func callerName() {
        #expect(PushPayload.callerName("Tippfrei") == "Parley · Tippfrei")
        #expect(PushPayload.callerName(nil) == "Parley")
    }

    @Test func tokenAsHex() {
        #expect(PushPayload.hex(Data([0x00, 0x0f, 0xab, 0xff])) == "000fabff")
        #expect(PushPayload.hex(Data()) == "")
    }

    /// A provisioning profile is a CMS envelope with the XML plist inside.
    private func profile(_ aps: String?) -> Data {
        let entitlements = aps.map { "<key>aps-environment</key><string>\($0)</string>" } ?? ""
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>Name</key><string>Test</string>
        <key>Entitlements</key><dict><key>application-identifier</key><string>T.de.x</string>\(entitlements)</dict></dict></plist>
        """
        return Data([0x30, 0x82, 0x01, 0xFF, 0x06]) + Data(plist.utf8) + Data([0xA0, 0x82, 0x00])
    }

    @Test func environmentFromTheEmbeddedProfile() {
        #expect(PushEnvironment.fromProfile(profile("development")) == .development)
        #expect(PushEnvironment.fromProfile(profile("production")) == .production)
        #expect(PushEnvironment.fromProfile(profile(nil)) == nil)
        #expect(PushEnvironment.fromProfile(Data("not a profile".utf8)) == nil)
    }

    @Test func environmentWithoutAProfile() {
        // The test bundle has no embedded.mobileprovision: the build configuration decides.
        #if DEBUG
        #expect(PushEnvironment.current(bundle: Bundle(for: Marker.self)) == .development)
        #else
        #expect(PushEnvironment.current(bundle: Bundle(for: Marker.self)) == .production)
        #endif
    }

    private final class Marker {}
}
