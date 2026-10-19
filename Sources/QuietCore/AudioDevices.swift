import CoreAudio
import Foundation

public struct AudioDevice: Identifiable, Hashable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let inputChannels: Int
    public let outputChannels: Int

    /// Loopback drivers that can act as a virtual microphone for other apps.
    public var isLoopback: Bool {
        let n = name.lowercased()
        return n.contains("blackhole") || n.contains("loopback") || n.contains("soundflower") || n.contains("quiet microphone")
    }
}

public enum AudioDevices {
    /// Hidden output half of Quiet.driver (driver/build_driver.sh). Apps see its other half, "Quiet Microphone".
    public static let quietOutputUID = "Quiet_2_UID"

    /// Where processed audio can go: Quiet.driver if installed (preferred), then any loopback like BlackHole.
    public static func virtualMicTargets() -> [AudioDevice] {
        let loopbacks = all().filter { $0.isLoopback && $0.outputChannels > 0 }
        guard let id = device(uid: quietOutputUID) else { return loopbacks }
        let quiet = AudioDevice(id: id, uid: quietOutputUID, name: "Quiet Microphone",
                                inputChannels: 0, outputChannels: channels(id, kAudioObjectPropertyScopeOutput))
        return [quiet] + loopbacks
    }

    /// Resolves a device UID, including hidden devices that `all()` does not list.
    public static func device(uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = withUnsafeMutablePointer(to: &cfUID) {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), $0, &size, &id)
        }
        return err == noErr && id != kAudioObjectUnknown ? id : nil
    }

    public static func all() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.map { id in
            AudioDevice(id: id,
                        uid: string(id, kAudioDevicePropertyDeviceUID) ?? "\(id)",
                        name: string(id, kAudioObjectPropertyName) ?? "Device \(id)",
                        inputChannels: channels(id, kAudioObjectPropertyScopeInput),
                        outputChannels: channels(id, kAudioObjectPropertyScopeOutput))
        }
    }

    public static func defaultInput() -> AudioDeviceID? { defaultDevice(kAudioHardwarePropertyDefaultInputDevice) }

    public static func defaultOutput() -> AudioDeviceID? { defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return err == noErr && id != 0 ? id : nil
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func channels(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
