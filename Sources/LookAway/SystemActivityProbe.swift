import AppKit
import CoreAudio
import CoreMediaIO
import LookAwayCore

/// Reads real device use rather than which app happens to be in front.
///
/// The microphone side asks CoreAudio for its list of audio processes and picks
/// out the ones with a live input stream, which gives both "is the mic being
/// captured" and "by whom" in one pass. The camera side asks CoreMediaIO
/// whether any camera is running; that answer is per device rather than per
/// process, so on its own it says nothing about which app is responsible.
///
/// Neither query records anything or opens a device, so neither one trips the
/// microphone or camera permission prompts.
@MainActor
final class SystemActivityProbe: MeetingActivityProbing {
    func sample() -> MeetingActivity {
        MeetingActivity(
            capturingBundleIDs: microphoneCapturingBundleIDs(),
            isCameraInUse: isAnyCameraRunning(),
            runningBundleIDs: runningBundleIDs()
        )
    }

    // MARK: - Microphone

    private func microphoneCapturingBundleIDs() -> Set<String> {
        // `kAudioHardwarePropertyProcessObjectList` arrived in macOS 14.4. On
        // 14.0-14.3 the query simply fails, and `fallbackInputBundleIDs` stands
        // in with a device-level reading.
        let processes = audioProcessObjectIDs()
        guard !processes.isEmpty else { return fallbackInputBundleIDs() }

        var capturing: Set<String> = []
        for process in processes {
            guard flag(process, kAudioProcessPropertyIsRunningInput) else { continue }
            if let bundleID = string(process, kAudioProcessPropertyBundleID), !bundleID.isEmpty {
                capturing.insert(bundleID)
            } else if let bundleID = bundleIDOfProcess(owning: process) {
                // Helpers and XPC services sometimes report no bundle ID.
                capturing.insert(bundleID)
            }
        }
        return capturing
    }

    /// macOS 14.0-14.3 has no per-process audio list. All we can tell there is
    /// whether the default input device is running, so every chosen app that is
    /// open gets the credit and the camera rule ends up doing the same work.
    private func fallbackInputBundleIDs() -> Set<String> {
        guard let device = defaultInputDevice(),
              flag(device, kAudioDevicePropertyDeviceIsRunningSomewhere)
        else { return [] }
        return runningBundleIDs()
    }

    private func audioProcessObjectIDs() -> [AudioObjectID] {
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids
    }

    private func defaultInputDevice() -> AudioObjectID? {
        var address = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        ) == noErr, device != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return device
    }

    /// Last resort for a process with no bundle ID of its own: look its PID up
    /// in the running applications.
    private func bundleIDOfProcess(owning object: AudioObjectID) -> String? {
        var address = Self.address(kAudioProcessPropertyPID)
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &pid) == noErr, pid > 0
        else { return nil }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    // MARK: - Camera

    private func isAnyCameraRunning() -> Bool {
        var address = Self.cmioAddress(kCMIOHardwarePropertyDevices)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else { return false }

        let count = Int(size) / MemoryLayout<CMIOObjectID>.size
        var devices = [CMIOObjectID](repeating: 0, count: count)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &used, &devices
        ) == noErr else { return false }

        return devices.contains { isRunning($0) }
    }

    private func isRunning(_ device: CMIOObjectID) -> Bool {
        var address = Self.cmioAddress(kCMIODevicePropertyDeviceIsRunningSomewhere)
        var running: UInt32 = 0
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        guard CMIOObjectGetPropertyData(device, &address, 0, nil, size, &used, &running) == noErr
        else { return false }
        return running != 0
    }

    // MARK: - Running apps

    private func runningBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    // MARK: - Property helpers

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func cmioAddress(_ selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(UInt32(selector)),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
    }

    private func flag(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var address = Self.address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
        else { return false }
        return value != 0
    }

    private func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = Self.address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        return value as String?
    }
}
