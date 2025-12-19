import CoreAudio
import os.log

/// Observes the system microphone activity flag (CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere`)
/// and publishes changes on the main actor so UI and detection logic can react without hopping threads.
@MainActor
final class MicUsageMonitor {
    private let logger = Logger(subsystem: "com.overhear.app", category: "MicUsageMonitor")
    private var listenerAdded = false
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var isActive = false {
        didSet {
            if oldValue != isActive {
                onChange?(isActive)
            }
        }
    }

    var onChange: (@MainActor (Bool) -> Void)?

    func start() {
        guard !listenerAdded else { return }
        // Bind to the current default input device instead of the system object so we
        // actually receive the mic-running flag changes.
        guard let deviceID = defaultInputDeviceID() else {
            logger.error("No default input device; mic usage monitoring disabled")
            return
        }
        observedDevice = deviceID
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                await self?.refreshState()
            }
        }
        listenerBlock = block

        let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main, block)
        if status == noErr {
            listenerAdded = true
            logger.info("Mic usage listener added")
            Task { @MainActor in
                await refreshState()
            }
        } else {
            logger.error("Failed to add mic usage listener: \(status)")
        }
    }

    func stop() {
        guard listenerAdded else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        if let block = listenerBlock, let device = observedDevice {
            AudioObjectRemovePropertyListenerBlock(device, &address, DispatchQueue.main, block)
        }
        listenerAdded = false
        listenerBlock = nil
        observedDevice = nil
        isActive = false
    }

    private func refreshState() async {
        guard let device = observedDevice ?? defaultInputDeviceID() else {
            logger.error("Cannot refresh mic state; no input device")
            return
        }
        observedDevice = device
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            device,
            &address,
            0,
            nil,
            &dataSize,
            &value
        )

        if status == noErr {
            isActive = (value != 0)
        } else {
            logger.error("Mic usage query failed: \(status)")
        }
    }

    private var observedDevice: AudioObjectID?

    private func defaultInputDeviceID() -> AudioObjectID? {
        var deviceID = AudioObjectID()
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )
        if status == noErr {
            return deviceID
        } else {
            logger.error("Failed to read default input device: \(status)")
            return nil
        }
    }
}
