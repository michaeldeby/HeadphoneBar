import CoreAudio
import Foundation

struct AudioOutput: Identifiable {
    let id: AudioDeviceID
    let name: String
    let transport: UInt32
    var isBTD700: Bool { name.uppercased().contains("BTD 700") }
}

enum AudioOutputs {
    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    static func list() -> [AudioOutput] {
        var property = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &devices) == noErr else { return [] }
        return devices.compactMap { device in
            var streams = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &streamSize) == noErr, streamSize > 0 else { return nil }
            var nameProperty = address(kAudioObjectPropertyName)
            var nameReference: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(device, &nameProperty, 0, nil, &nameSize, &nameReference) == noErr,
                  let name = nameReference?.takeRetainedValue() else { return nil }
            var transportProperty = address(kAudioDevicePropertyTransportType)
            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            _ = AudioObjectGetPropertyData(device, &transportProperty, 0, nil, &transportSize, &transport)
            return AudioOutput(id: device, name: name as String, transport: transport)
        }
    }
    static func currentID() -> AudioDeviceID? {
        var property = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &device) == noErr else { return nil }
        return device
    }
    static func select(_ device: AudioDeviceID) throws {
        guard list().contains(where: { $0.id == device }) else { throw ControlError.message("That audio output is no longer connected.") }
        var property = address(kAudioHardwarePropertyDefaultOutputDevice)
        var target = device
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &target)
        guard status == noErr else { throw ControlError.message("macOS could not switch the audio output (\(status)).") }
        guard currentID() == device else { throw ControlError.message("macOS did not confirm the audio output change. Try again.") }
    }
}
