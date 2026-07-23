import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

// Pre-initialized AUHAL input unit — the technique fast dictation apps (e.g. VoiceInk)
// use for instant-on capture. All expensive work (opening the default input device,
// negotiating formats, AudioUnitInitialize) happens in prepare(), ahead of time; start()
// on a prepared unit is near-instant (~10 ms) and stop() keeps it initialized so the NEXT
// start is instant too. A prepared-but-stopped unit shows no mic indicator and does no IO.
// Implemented independently against Apple's documented AUHAL API (no third-party code).
final class AUHALInput: @unchecked Sendable {
    private var unit: AudioUnit?
    private(set) var format: AVAudioFormat?   // client format: device rate, mono, Float32
    private var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    private(set) var prepared = false
    private var running = false

    /// One-time (per device) expensive setup. Safe to call again to re-bind the current
    /// default input device. Returns false on any CoreAudio error.
    @discardableResult
    func prepare() -> Bool {
        teardown()
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev) == noErr,
              dev != 0 else { return false }

        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { return false }
        var u: AudioUnit?
        guard AudioComponentInstanceNew(comp, &u) == noErr, let au = u else { return false }

        var one: UInt32 = 1, zero: UInt32 = 0
        let u32 = UInt32(MemoryLayout<UInt32>.size)
        guard AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, u32) == noErr,
              AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, u32) == noErr,
              AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev,
                                   UInt32(MemoryLayout<AudioDeviceID>.size)) == noErr
        else { AudioComponentInstanceDispose(au); return false }

        // Hardware format on the input scope of bus 1 → adopt its sample rate (AUHAL does
        // not rate-convert); mono Float32 as our client format on the output scope.
        var hw = AudioStreamBasicDescription()
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioUnitGetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hw, &asbdSize) == noErr,
              hw.mSampleRate > 0,
              let client = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hw.mSampleRate,
                                         channels: 1, interleaved: false)
        else { AudioComponentInstanceDispose(au); return false }
        var clientASBD = client.streamDescription.pointee
        guard AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &clientASBD, asbdSize) == noErr
        else { AudioComponentInstanceDispose(au); return false }

        var cb = AURenderCallbackStruct(inputProc: auhalInputCallback,
                                        inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        guard AudioUnitSetProperty(au, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb,
                                   UInt32(MemoryLayout<AURenderCallbackStruct>.size)) == noErr,
              AudioUnitInitialize(au) == noErr
        else { AudioComponentInstanceDispose(au); return false }

        unit = au
        format = client
        prepared = true
        return true
    }

    /// Start IO on the prepared unit — near-instant. Buffers arrive on the HAL IO thread.
    func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) -> Bool {
        guard let unit, prepared, !running else { return false }
        self.onBuffer = onBuffer
        guard AudioOutputUnitStart(unit) == noErr else { self.onBuffer = nil; return false }
        running = true
        return true
    }

    /// Stop IO but KEEP the unit initialized (next start stays instant, indicator goes off).
    func stop() {
        onBuffer = nil
        guard let unit, running else { return }
        AudioOutputUnitStop(unit)
        AudioUnitReset(unit, kAudioUnitScope_Global, 0)
        running = false
    }

    /// Full release (hard recovery / device switch); prepare() must run again after.
    func teardown() {
        stop()
        if let unit {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        unit = nil
        format = nil
        prepared = false
    }

    fileprivate func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                            _ ts: UnsafePointer<AudioTimeStamp>, _ bus: UInt32, _ frames: UInt32) {
        guard let unit, let format, let cb = onBuffer,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buf.frameLength = frames
        guard AudioUnitRender(unit, flags, ts, bus, frames, buf.mutableAudioBufferList) == noErr else { return }
        cb(buf)
    }
}

private func auhalInputCallback(refCon: UnsafeMutableRawPointer,
                                ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                                inTimeStamp: UnsafePointer<AudioTimeStamp>,
                                inBusNumber: UInt32, inNumberFrames: UInt32,
                                ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    Unmanaged<AUHALInput>.fromOpaque(refCon).takeUnretainedValue()
        .render(ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames)
    return noErr
}
