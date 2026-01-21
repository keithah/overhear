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

    /// Returns the shared immutable buffer (no copy). Callers must not mutate.
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
        let (buffer, count) = counts[key] ?? (source, 0)
        counts[key] = (buffer, count + 1)
        return PooledAudioBuffer(buffer: buffer) { [weak self] in
            guard let self else {
                NSLog("AudioBufferPool deallocated before release; pooled buffer drop ignored (possible leak). Pool must outlive pooled buffers.")
                return
            }
            self.decrement(key: key)
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

#if DEBUG
extension AudioBufferPool {
    func _testActiveCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts.count
    }
}
#endif
