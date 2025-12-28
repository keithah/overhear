@preconcurrency import CoreAudio
import os.log

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
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
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

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                await self?.refreshState()
            }
        }
        listenerBlock = block

        let status = client.addListener(deviceID, &address, DispatchQueue.main, block)
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
        let deviceChangeBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                await self?.rebindToCurrentDevice()
            }
        }
        defaultDeviceListener = deviceChangeBlock
        let deviceChangeStatus = client.addDefaultDeviceListener(&defaultDeviceAddress, DispatchQueue.main, deviceChangeBlock)
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
        if let block = listenerBlock, let device = observedDevice {
            let status = client.removeListener(device, &address, DispatchQueue.main, block)
            if status != noErr {
                logger.error("Failed to remove mic usage listener: \(status)")
            }
        }
        listenerAdded = false
        listenerBlock = nil
        observedDevice = nil
        isActive = false

        if let deviceChangeBlock = defaultDeviceListener {
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
        defaultDeviceListener = nil
        rebindTask?.cancel()
        rebindTask = nil
    }

    deinit {
        if listenerAdded {
            logger.error("MicUsageMonitor deinit while listener still active; forcing stop()")
        }
        Task { @MainActor [weak self] in
            self?.stop()
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
            Task { await rebindToCurrentDevice() }
        }
    }

    private var observedDevice: AudioObjectID?
    private var rebinding = false
    private var rebindTask: Task<Void, Never>?

    private func rebindToCurrentDevice() async {
        guard !rebinding else { return }
        rebinding = true

        let oldTask = rebindTask
        rebindTask = nil
        oldTask?.cancel()
        if let oldTask {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await oldTask.value }
                group.addTask {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
                _ = await group.next()
                group.cancelAll()
            }
        }

        rebindTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.rebinding = false }

        // Tear down existing listener
            if self.listenerAdded, let block = self.listenerBlock, let device = self.observedDevice {
                var address = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                    mScope: kAudioObjectPropertyScopeInput,
                    mElement: kAudioObjectPropertyElementMain
                )
                let status = AudioObjectRemovePropertyListenerBlock(device, &address, DispatchQueue.main, block)
                if status != noErr {
                    self.logger.error("Failed to remove mic listener during rebind: \(status)")
                }
                self.listenerAdded = false
                self.listenerBlock = nil
                self.observedDevice = nil
            }

        // Re-register on the new default device
            guard let deviceID = self.client.defaultInputDeviceID() else {
                self.logger.error("Rebind failed: no default input device")
                self.isActive = false
                return
            }
            self.observedDevice = deviceID

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
            self.listenerBlock = block
            let status = self.client.addListener(deviceID, &address, DispatchQueue.main, block)
            guard status == noErr else {
                self.logger.error("Failed to rebind mic usage listener: \(status)")
                self.listenerBlock = nil
                self.observedDevice = nil
                self.isActive = false
                return
            }

            self.listenerAdded = true
            self.logger.info("Rebound mic usage listener to new input device")
            await self.refreshState()
        }
    }
}
