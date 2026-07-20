import Foundation
import CoreAudio
import AVFoundation

// Enumerate CoreAudio input devices and route an AVAudioEngine's input to a chosen one.
// AVAudioEngine on macOS uses the system default input unless we set the AUHAL's current
// device explicitly (done before engine.start()).
struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum AudioDevices {
    static func inputDevices() -> [AudioInputDevice] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }

        var out: [AudioInputDevice] = []
        for id in ids where hasInput(id) {
            let name = stringProperty(id, kAudioObjectPropertyName) ?? "Unbekanntes Gerät"
            let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) ?? ""
            out.append(AudioInputDevice(id: id, uid: uid, name: name))
        }
        return out
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        inputDevices().first { $0.uid == uid }?.id
    }

    /// Route this engine's input to `deviceID`. Call before `engine.start()`.
    static func setInputDevice(_ deviceID: AudioDeviceID, on engine: AVAudioEngine) {
        guard let unit = engine.inputNode.audioUnit else { return }
        var dev = deviceID
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global, 0, &dev,
                             UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    // MARK: - private

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        let bufList = AudioBufferList.allocate(maximumBuffers: Int(size) / MemoryLayout<AudioBuffer>.stride)
        defer { free(bufList.unsafeMutablePointer) }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, bufList.unsafeMutablePointer) == noErr else { return false }
        var channels = 0
        for buf in UnsafeMutableAudioBufferListPointer(bufList.unsafeMutablePointer) {
            channels += Int(buf.mNumberChannels)
        }
        return channels > 0
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr -> OSStatus in
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr else { return nil }
        return value as String
    }
}
