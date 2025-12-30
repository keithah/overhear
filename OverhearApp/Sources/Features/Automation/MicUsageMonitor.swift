@preconcurrency import CoreAudio
import os.log

private final class ListenerBlockWrapper {
    let block: AudioObjectPropertyListenerBlock
    init(_ block: @escaping AudioObjectPropertyListenerBlock) {
        self.block = block
    }
}

/// Thin wrapper around CoreAudio primitives to allow unit testing.
struct AudioObjectClient {
    var defaultInputDeviceID: @Sendable () -> AudioObjectID?
    var addListener: @Sendable (AudioObjectID, inout AudioObjectPropertyAddress, DispatchQueue, @escaping AudioObjectPropertyListenerBlock) -> OSStatus
    var removeListener: @Sendable (AudioObjectID, inout AudioObjectPropertyAddress, DispatchQueue, @escaping AudioObjectPropertyListenerBlock) -> OSStatus
    var addDefaultDeviceListener: @Sendable (inout AudioObjectPropertyAddress, DispatchQueue, @escaping AudioObjectPropertyListenerBlock) -> OSStatus
    var removeDefaultDeviceListener: @Sendable (inout AudioObjectPropertyAddress, DispatchQueue, @escaping AudioObjectPropertyListenerBlock) -> OSStatus
    var getPropertyData: @Sendable (AudioObjectID, inout AudioObjectPropertyAddress, inout UInt32, UnsafeMutableRawPointer) -> OSStatus

    static let live = AudioObjectClient(
        defaultInputDeviceID: {
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
            return status == noErr ? deviceID : nil
        },
        addListener: { device, address, queue, block in
            AudioObjectAddPropertyListenerBlock(device, &address, queue, block)
        },
        removeListener: { device, address, queue, block in
            AudioObjectRemovePropertyListenerBlock(device, &address, queue, block)
        },
        addDefaultDeviceListener: { address, queue, block in
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                queue,
                block
            )
        },
        removeDefaultDeviceListener: { address, queue, block in
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                queue,
                block
            )
        },
        getPropertyData: { device, address, dataSize, dataPointer in
            AudioObjectGetPropertyData(
                device,
                &address,
                0,
                nil,
                &dataSize,
                dataPointer
            )
        }
    )
}

/// Observes the system microphone activity flag (CoreAudio `kAudioDevicePropertyDeviceIsRunningSomewhere`)
/// and publishes changes on the main actor so UI and detection logic can react without hopping threads.
@MainActor
final class MicUsageMonitor {
    private let logger = Logger(subsystem: "com.overhear.app", category: "MicUsageMonitor")
    private let client: AudioObjectClient
    private var listenerAdded = false
    private var listenerWrapper: ListenerBlockWrapper?
    private var defaultDeviceWrapper: ListenerBlockWrapper?
    private var pendingRebinds = 0
    private var isActive = false {
        didSet {
            if oldValue != isActive {
                onChange?(isActive)
            }
        }
    }

    var onChange: (@MainActor (Bool) -> Void)?

    init(client: AudioObjectClient = .live) {
        self.client = client
    }

    func start() {
        guard !listenerAdded else { return }
        // Bind to the current default input device instead of the system object so we
        // actually receive the mic-running flag changes.
        guard let deviceID = client.defaultInputDeviceID() else {
            logger.error("No default input device; mic usage monitoring disabled")
            return
        }
        observedDevice = deviceID
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        let block = ListenerBlockWrapper { [weak self] _, _ in
            Task { @MainActor in
                await self?.refreshState()
            }
        }
        listenerWrapper = block

        let status = client.addListener(deviceID, &address, DispatchQueue.main, block.block)
        if status == noErr {
            listenerAdded = true
            logger.info("Mic usage listener added")
            Task { @MainActor in
                await refreshState()
            }
        } else {
            logger.error("Failed to add mic usage listener: \(status)")
        }

        // Also observe default input device changes so we can rebind the mic listener.
        var defaultDeviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let deviceChangeBlock = ListenerBlockWrapper { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                self.enqueueRebind()
            }
        }
        defaultDeviceWrapper = deviceChangeBlock
        let deviceChangeStatus = client.addDefaultDeviceListener(&defaultDeviceAddress, DispatchQueue.main, deviceChangeBlock.block)
        if deviceChangeStatus != noErr {
            logger.error("Failed to add default device listener: \(deviceChangeStatus)")
        }
    }

    func stop() {
        guard listenerAdded else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        if let block = listenerWrapper?.block, let device = observedDevice {
            let status = client.removeListener(device, &address, DispatchQueue.main, block)
            if status != noErr {
                logger.error("Failed to remove mic usage listener: \(status)")
            }
        }
        listenerAdded = false
        listenerWrapper = nil
        observedDevice = nil
        isActive = false

        if let deviceChangeBlock = defaultDeviceWrapper?.block {
            var defaultDeviceAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = client.removeDefaultDeviceListener(&defaultDeviceAddress, DispatchQueue.main, deviceChangeBlock)
            if status != noErr {
                logger.error("Failed to remove default device listener: \(status)")
            }
        }
        defaultDeviceWrapper = nil
        rebindTask?.cancel()
        rebindTask = nil
        pendingRebinds = 0
    }

    deinit {
        if listenerAdded {
            logger.error("MicUsageMonitor deinit while listener still active; stop() should be called explicitly")
        }
    }

    private func refreshState() async {
        guard let device = observedDevice ?? client.defaultInputDeviceID() else {
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
        let status = client.getPropertyData(
            device,
            &address,
            &dataSize,
            &value
        )

        if status == noErr {
            isActive = (value != 0)
        } else {
            logger.error("Mic usage query failed: \(status)")
        }
    }

    func healthCheck() {
        if listenerAdded && observedDevice == nil {
            logger.error("MicUsageMonitor listener active but no device; triggering rebind")
            enqueueRebind()
        }
    }

    private var observedDevice: AudioObjectID?
    private var rebindTask: Task<Void, Never>?

    private func enqueueRebind() {
        // Avoid unbounded growth if the system flaps devices rapidly.
        pendingRebinds = min(pendingRebinds + 1, 5)
        guard rebindTask == nil else { return }
        rebindTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.pendingRebinds > 0 {
                self.pendingRebinds -= 1
                await self.performRebind()
            }
            self.rebindTask = nil
        }
    }

    private func performRebind() async {
        if listenerAdded, let block = listenerWrapper?.block, let device = observedDevice {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = client.removeListener(device, &address, DispatchQueue.main, block)
            if status != noErr {
                logger.error("Failed to remove mic listener during rebind: \(status)")
            }
            listenerAdded = false
            listenerWrapper = nil
            observedDevice = nil
            isActive = false
        }

        guard let deviceID = client.defaultInputDeviceID() else {
            logger.error("Rebind failed: no default input device")
            let wasActive = isActive
            isActive = false
            if !wasActive {
                onChange?(false)
            }
            return
        }
        observedDevice = deviceID

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        let block = ListenerBlockWrapper { [weak self] _, _ in
            Task { @MainActor in
                await self?.refreshState()
            }
        }
        listenerWrapper = block
        let status = client.addListener(deviceID, &address, DispatchQueue.main, block.block)
        guard status == noErr else {
            logger.error("Failed to rebind mic usage listener: \(status)")
            listenerWrapper = nil
            observedDevice = nil
            let wasActive = isActive
            isActive = false
            if !wasActive {
                onChange?(false)
            }
            return
        }

        listenerAdded = true
        logger.info("Rebound mic usage listener to new input device")
        await refreshState()
    }
}
