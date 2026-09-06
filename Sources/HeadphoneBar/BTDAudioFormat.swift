import CoreAudio
import Foundation

struct BTDAudioFormat: Identifiable {
    let stream: AudioStreamID
    let description: AudioStreamBasicDescription
    var id: String { "\(stream)-\(description.mSampleRate)-\(description.mBitsPerChannel)-\(description.mChannelsPerFrame)-\(description.mFormatFlags & ~kAudioFormatFlagIsNonMixable)-\(description.mBytesPerFrame)" }
    var title: String { "\(description.mChannelsPerFrame) ch · \(description.mBitsPerChannel)-bit · \(description.mSampleRate / 1000) kHz" }
}

enum BTDAudioFormats {
    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    private static func outputStream() throws -> AudioStreamID {
        let dongles = AudioOutputs.list().filter(\.isBTD700)
        guard dongles.count == 1, let dongle = dongles.first else { throw ControlError.message("Connect one BTD 700 to edit its audio format.") }
        var property = address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dongle.id, &property, 0, nil, &size) == noErr else { throw ControlError.message("Cannot read BTD 700 audio streams.") }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard streams.count == 1, AudioObjectGetPropertyData(dongle.id, &property, 0, nil, &size, &streams) == noErr else { throw ControlError.message("The BTD 700 output stream could not be identified.") }
        return streams[0]
    }
    static func current() throws -> BTDAudioFormat {
        let stream = try outputStream()
        var property = address(kAudioStreamPropertyPhysicalFormat)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(stream, &property, 0, nil, &size, &format) == noErr else { throw ControlError.message("Cannot read the BTD 700 audio format.") }
        return BTDAudioFormat(stream: stream, description: format)
    }
    static func available() throws -> [BTDAudioFormat] {
        let stream = try outputStream()
        var property = address(kAudioStreamPropertyAvailablePhysicalFormats)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(stream, &property, 0, nil, &size) == noErr else { throw ControlError.message("Cannot read supported BTD 700 formats.") }
        var ranges = [AudioStreamRangedDescription](repeating: AudioStreamRangedDescription(), count: Int(size) / MemoryLayout<AudioStreamRangedDescription>.size)
        guard AudioObjectGetPropertyData(stream, &property, 0, nil, &size, &ranges) == noErr else { throw ControlError.message("Cannot read supported BTD 700 formats.") }
        var formats: [BTDAudioFormat] = []
        for range in ranges.sorted(by: { $0.mFormat.mFormatFlags < $1.mFormat.mFormatFlags }) where range.mFormat.mFormatID == kAudioFormatLinearPCM {
            let rates = range.mSampleRateRange.mMinimum == range.mSampleRateRange.mMaximum
                ? [range.mSampleRateRange.mMinimum]
                : [44100.0, 48000.0, 88200.0, 96000.0, 176400.0, 192000.0].filter { $0 >= range.mSampleRateRange.mMinimum && $0 <= range.mSampleRateRange.mMaximum }
            for rate in rates {
                var format = range.mFormat
                format.mSampleRate = rate
                let option = BTDAudioFormat(stream: stream, description: format)
                if !formats.contains(where: { $0.id == option.id }) { formats.append(option) }
            }
        }
        return formats.sorted { ($0.description.mSampleRate, $0.description.mBitsPerChannel) < ($1.description.mSampleRate, $1.description.mBitsPerChannel) }
    }
    static func select(_ format: BTDAudioFormat) async throws -> BTDAudioFormat {
        guard try available().contains(where: { $0.id == format.id }) else { throw ControlError.message("That audio format is no longer available. Refresh and try again.") }
        var property = address(kAudioStreamPropertyPhysicalFormat)
        var value = format.description
        let status = AudioObjectSetPropertyData(format.stream, &property, 0, nil, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &value)
        guard status == noErr else { throw ControlError.message("macOS could not change the BTD 700 format (\(status)).") }
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(100))
            let actual = try current()
            if actual.id == format.id { return actual }
        }
        throw ControlError.message("The BTD 700 did not confirm the requested audio format. Refresh to see its current setting.")
    }
}
