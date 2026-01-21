import XCTest
import AVFoundation
@testable import Overhear

final class AudioBufferPoolTests: XCTestCase {
    func testReferenceCountingReleasesBuffers() {
        let pool = AudioBufferPool()
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
        buffer.frameLength = 256

        XCTAssertEqual(pool._testActiveCount(), 0)
        let pooled1 = AudioBufferPool.PooledAudioBuffer.makeShared(from: buffer, pool: pool)
        XCTAssertNotNil(pooled1)
        XCTAssertEqual(pool._testActiveCount(), 1)
        let pooled2 = AudioBufferPool.PooledAudioBuffer.makeShared(from: buffer, pool: pool)
        XCTAssertNotNil(pooled2)
        XCTAssertEqual(pool._testActiveCount(), 1, "Same source buffer should share a single pooled entry")

        // Release references
        withExtendedLifetime((pooled1, pooled2)) {}
        XCTAssertEqual(pool._testActiveCount(), 0)
    }
}
