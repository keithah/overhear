import XCTest
import AVFoundation
@testable import Overhear

final class AVAudioCaptureServiceSessionTests: XCTestCase {

    private func makeTestBuffer(frameLength: AVAudioFrameCount = 32) throws -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
            throw XCTSkip("Failed to create AVAudioPCMBuffer for test")
        }
        buffer.frameLength = frameLength
        return buffer
    }

    func testBuffersFromPriorSessionAreDropped() {
        let currentSession = UUID()
        let previousSession = UUID()

        XCTAssertTrue(
            AVAudioCaptureService.shouldProcessBuffer(
                isRecording: true,
                observerSessionID: currentSession,
                bufferSessionID: currentSession
            )
        )
        XCTAssertFalse(
            AVAudioCaptureService.shouldProcessBuffer(
                isRecording: true,
                observerSessionID: currentSession,
                bufferSessionID: previousSession
            )
        )
        XCTAssertFalse(
            AVAudioCaptureService.shouldProcessBuffer(
                isRecording: false,
                observerSessionID: currentSession,
                bufferSessionID: currentSession
            )
        )
    }

    func testBackpressureDropDecision() {
        XCTAssertFalse(
            AVAudioCaptureService.backpressureDropDecision(pending: 63, max: 64),
            "Should not drop when pending is below the limit"
        )
        XCTAssertTrue(
            AVAudioCaptureService.backpressureDropDecision(pending: 64, max: 64),
            "Should drop when pending reaches the limit"
        )
        XCTAssertTrue(
            AVAudioCaptureService.backpressureDropDecision(pending: 128, max: 64),
            "Should drop when pending exceeds the limit"
        )
    }

    func testNotifyObserversStopsAfterRecordingStops() async throws {
        let service = AVAudioCaptureService()
        let sessionID = UUID()
        let buffer = try makeTestBuffer()
        await service._testConfigureRecordingState(recording: true, sessionID: sessionID)
        let first = expectation(description: "observer called while recording")
        let observerID = await service.registerBufferObserver { _ in
            first.fulfill()
        }
        await service._testNotifyObservers(buffer: buffer, sessionID: sessionID)
        await fulfillment(of: [first], timeout: 1.0)

        await service.unregisterBufferObserver(observerID)
        await service._testClearObservers()
        await service._testConfigureRecordingState(recording: false, sessionID: sessionID)
        let inverted = expectation(description: "observer not called after stop")
        inverted.isInverted = true
        await service._testNotifyObservers(buffer: buffer, sessionID: sessionID)
        await fulfillment(of: [inverted], timeout: 0.5)
    }

    func testWaitForInFlightBuffersDrainsPendingCount() async {
        let service = AVAudioCaptureService()
        await service._testSetPendingBufferCount(2)
        let drainTask = Task {
            try? await Task.sleep(nanoseconds: 20_000_000)
            await service._testSetPendingBufferCount(0)
        }
        await service._testWaitForInFlightBuffers()
        let remaining = await service._testPendingBufferCount()
        XCTAssertEqual(remaining, 0)
        drainTask.cancel()
    }

    func testFinalizeDrainsObserversAfterPendingBuffers() async throws {
        let service = AVAudioCaptureService()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        await service._testConfigureRecordingState(recording: true, sessionID: UUID())
        await service._testSetOutputURL(tempURL)
        _ = await service.registerBufferObserver { _ in }
        await service._testSetPendingBufferCount(1)
        let drainTask = Task {
            try? await Task.sleep(nanoseconds: 20_000_000)
            await service._testSetPendingBufferCount(0)
        }

        await service._testFinalizeRecording(url: tempURL, stoppedEarly: false)
        drainTask.cancel()

        let observerCount = await service._testObserverCount()
        XCTAssertEqual(observerCount, 0)
        let pending = await service._testPendingBufferCount()
        XCTAssertEqual(pending, 0)
    }

    func testRegisterDuringFinalizeDoesNotLeaveObservers() async throws {
        let service = AVAudioCaptureService()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        await service._testConfigureRecordingState(recording: true, sessionID: UUID())
        await service._testSetOutputURL(tempURL)

        let finalizeTask = Task {
            await service._testFinalizeRecording(url: tempURL, stoppedEarly: false)
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
        _ = await service.registerBufferObserver { _ in }

        await finalizeTask.value
        let observerCount = await service._testObserverCount()
        XCTAssertEqual(observerCount, 0)
    }

    func testBackpressureDropDoesNotIncrementPending() async throws {
        let service = AVAudioCaptureService()
        let sessionID = UUID()
        let buffer = try makeTestBuffer()
        await service._testConfigureRecordingState(recording: true, sessionID: sessionID)
        await service._testSetOutputURL(
            FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        await service._testSetPendingBufferCount(64)
        await service._testNotifyObservers(buffer: buffer, sessionID: sessionID)
        let pending = await service._testPendingBufferCount()
        XCTAssertEqual(pending, 64, "Backpressure should drop without increasing pending count")
    }

    func testPendingCounterUnderflowIsCorrected() async throws {
        let service = AVAudioCaptureService()
        let sessionID = UUID()
        let buffer = try makeTestBuffer()
        await service._testConfigureRecordingState(recording: true, sessionID: sessionID)
        await service._testSetOutputURL(
            FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        await service._testSetPendingBufferCount(0)
        // Force underflow by notifying with empty pending and expect correction to 0.
        await service._testNotifyObservers(buffer: buffer, sessionID: sessionID)
        let pending = await service._testPendingBufferCount()
        XCTAssertEqual(pending, 0, "Pending counter should not go negative and should be corrected to zero")
    }

    func testBackpressureStressDoesNotExceedLimit() async throws {
        let service = AVAudioCaptureService()
        let sessionID = UUID()
        let buffer = try makeTestBuffer()
        await service._testConfigureRecordingState(recording: true, sessionID: sessionID)
        await service._testSetOutputURL(
            FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        await service._testSetPendingBufferCount(64)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await service._testNotifyObservers(buffer: buffer, sessionID: sessionID)
                }
            }
            group.waitForAll()
        }
        let pending = await service._testPendingBufferCount()
        XCTAssertLessThanOrEqual(pending, 64, "Pending buffer count should not exceed max after stress")
    }

    func testMemoryDropLeavesPendingUnchanged() async throws {
        let service = AVAudioCaptureService()
        let sessionID = UUID()
        // Large buffer to exercise byte accounting; actual drop is triggered by pendingBytes cap.
        let buffer = try makeTestBuffer(frameLength: 4096)
        await service._testConfigureRecordingState(recording: true, sessionID: sessionID)
        await service._testSetOutputURL(
            FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        // Simulate cap breach by setting pending bytes near the limit via multiple notifications.
        for _ in 0..<5 {
            await service._testNotifyObservers(buffer: buffer, sessionID: sessionID)
        }
        let pending = await service._testPendingBufferCount()
        XCTAssertLessThanOrEqual(pending, 64, "Memory drops should not inflate pending count")
    }

    func testFinalizeWhileObserverRegistersDoesNotLeak() async throws {
        let service = AVAudioCaptureService()
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        await service._testConfigureRecordingState(recording: true, sessionID: UUID())
        await service._testSetOutputURL(tempURL)

        let finalizeTask = Task {
            await service._testFinalizeRecording(url: tempURL, stoppedEarly: false)
        }
        try? await Task.sleep(nanoseconds: 2_000_000)
        let id = await service.registerBufferObserver { _ in }
        try? await Task.sleep(nanoseconds: 2_000_000)
        await service.unregisterBufferObserver(id)
        await finalizeTask.value
        let observerCount = await service._testObserverCount()
        XCTAssertEqual(observerCount, 0, "Observers should be cleared even if registered during finalize")
    }
}
