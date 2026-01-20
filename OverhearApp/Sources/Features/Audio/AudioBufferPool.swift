import AVFoundation
import Foundation

/// Simple pool that hands out shared, immutable buffers to observers to reduce cloning overhead.
/// Backed by reference counting to release buffers when the last observer drops it.
final class PooledAudioBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    private let release: () -> Void

    init(buffer: AVAudioPCMBuffer, release: @escaping () -> Void) {
        self.buffer = buffer
        self.release = release
    }

    func cloned() -> AVAudioPCMBuffer {
        buffer
    }

    deinit {
        release()
    }

    static func makeShared(from source: AVAudioPCMBuffer, pool: AudioBufferPool) -> PooledAudioBuffer? {
        pool.incrementRetain(source: source)
    }
}

/// Thread-safe pool keyed by buffer identity; AVAudioPCMBuffer isn’t Hashable, so use ObjectIdentifier.
final class AudioBufferPool {
    private var counts: [ObjectIdentifier: (AVAudioPCMBuffer, Int)] = [:]
    private let lock = NSLock()

    func incrementRetain(source: AVAudioPCMBuffer) -> PooledAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }
        let key = ObjectIdentifier(source)
        let entry = counts[key]
        let buffer = entry?.0 ?? source
        let newCount = (entry?.1 ?? 0) + 1
        counts[key] = (buffer, newCount)
        return PooledAudioBuffer(buffer: buffer) { [weak self] in
            self?.decrement(key: key)
        }
    }

    private func decrement(key: ObjectIdentifier) {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = counts[key] else { return }
        let newCount = entry.1 - 1
        if newCount <= 0 {
            counts.removeValue(forKey: key)
        } else {
            counts[key] = (entry.0, newCount)
        }
    }
}
