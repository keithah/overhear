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

        let defaultDevice = AudioObjectID(kAudioObjectSystemObject)
        let status = AudioObjectAddPropertyListenerBlock(defaultDevice, &address, DispatchQueue.main, block)
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
        let defaultDevice = AudioObjectID(kAudioObjectSystemObject)
        if let block = listenerBlock {
            AudioObjectRemovePropertyListenerBlock(defaultDevice, &address, DispatchQueue.main, block)
        }
        listenerAdded = false
        listenerBlock = nil
        isActive = false
    }

    private func refreshState() async {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
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
}
