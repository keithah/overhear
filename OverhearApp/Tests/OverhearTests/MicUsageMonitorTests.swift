import CoreAudio
import XCTest
@testable import Overhear

@MainActor
final class MicUsageMonitorTests: XCTestCase {
    final class FakeAudioClient: @unchecked Sendable {
        var currentDefault: AudioObjectID? = 1
        var addListenerCalls = 0
        var removeListenerCalls = 0
        var addDefaultListenerCalls = 0
        var removeDefaultListenerCalls = 0
        var getPropertyDataCalls = 0
        var lastDevice: AudioObjectID?
        var runningFlag: UInt32 = 0
        var addListenerDelayMicros: useconds_t = 0
        var addListenerStatus: OSStatus = noErr
        var removeListenerStatus: OSStatus = noErr
        var addDefaultStatus: OSStatus = noErr
        var removeDefaultStatus: OSStatus = noErr
        var getPropertyDataStatus: OSStatus = noErr

        var micListener: AudioObjectPropertyListenerBlock?
        var defaultListener: AudioObjectPropertyListenerBlock?

        var client: AudioObjectClient {
            AudioObjectClient(
                defaultInputDeviceID: { [weak self] in self?.currentDefault },
                addListener: { [weak self] device, address, _, block in
                    guard let self else { return kAudioHardwareBadDeviceError }
                    if self.addListenerDelayMicros > 0 {
                        usleep(self.addListenerDelayMicros)
                    }
                    self.addListenerCalls += 1
                    self.micListener = block
                    self.lastDevice = device
                    return self.addListenerStatus
                },
                removeListener: { [weak self] _, _, _, _ in
                    guard let self else { return kAudioHardwareBadDeviceError }
                    self.removeListenerCalls += 1
                    return self.removeListenerStatus
                },
                addDefaultDeviceListener: { [weak self] address, _, block in
                    guard let self else { return kAudioHardwareBadDeviceError }
                    self.addDefaultListenerCalls += 1
                    self.defaultListener = block
                    return self.addDefaultStatus
                },
                removeDefaultDeviceListener: { [weak self] _, _, _ in
                    guard let self else { return kAudioHardwareBadDeviceError }
                    self.removeDefaultListenerCalls += 1
                    return self.removeDefaultStatus
                },
                getPropertyData: { [weak self] _, _, _, dataPointer in
                    guard let self else { return kAudioHardwareBadDeviceError }
                    self.getPropertyDataCalls += 1
                    dataPointer.assumingMemoryBound(to: UInt32.self).pointee = self.runningFlag
                    return self.getPropertyDataStatus
                }
            )
        }

        func triggerDefaultDeviceChange() {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            defaultListener?(0, &address)
        }
    }

    func testStartAddsListenersAndReflectsMicState() async {
        let fake = FakeAudioClient()
        fake.runningFlag = 1
        let monitor = MicUsageMonitor(client: fake.client)
        var states: [Bool] = []
        monitor.onChange = { states.append($0) }

        monitor.start()
        await Task.yield()

        XCTAssertEqual(fake.addListenerCalls, 1)
        XCTAssertEqual(fake.addDefaultListenerCalls, 1)
        XCTAssertEqual(states.last, true)
    }

    func testRebindOnDefaultDeviceChange() async {
        let fake = FakeAudioClient()
        let monitor = MicUsageMonitor(client: fake.client)

        monitor.start()
        await Task.yield()
        XCTAssertEqual(fake.lastDevice, 1)

        fake.currentDefault = 2
        fake.triggerDefaultDeviceChange()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(fake.lastDevice, 2)
        XCTAssertEqual(fake.addListenerCalls, 2, "Rebind should add a new listener on device change")
    }

    func testQueuedRebindsProcessSequentially() async {
        let fake = FakeAudioClient()
        // Slow down addListener to keep the first rebind in-flight when the second request arrives.
        fake.addListenerDelayMicros = 60_000
        let monitor = MicUsageMonitor(client: fake.client)

        monitor.start()
        await Task.yield()
        XCTAssertEqual(fake.lastDevice, 1)

        fake.currentDefault = 2
        fake.triggerDefaultDeviceChange()
        // Immediately queue another change while the first rebind is still running.
        fake.currentDefault = 3
        fake.triggerDefaultDeviceChange()

        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(fake.lastDevice, 3, "Last rebind should target the final default device")
        XCTAssertEqual(fake.addListenerCalls, 3, "Queued rebind should add listener for each change")
    }
}
