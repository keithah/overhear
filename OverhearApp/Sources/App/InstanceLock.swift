import Foundation
import OSLog
import Darwin

/// File-backed single-instance lock that can be exercised without AppKit.
final class InstanceLock {
    private let lockURL: URL
    private let logger: Logger
    private var fd: Int32?

    init(lockDirectoryOverride: URL? = nil, logger: Logger = Logger(subsystem: "com.overhear.app", category: "InstanceLock")) {
        let fm = FileManager.default
        let appSupport = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
        let baseDir = lockDirectoryOverride ?? appSupport?.appendingPathComponent("Overhear", isDirectory: true)
        let userTemp = FileManager.default.temporaryDirectory.appendingPathComponent(NSUserName(), isDirectory: true)
        var chosenLockURL = userTemp.appendingPathComponent("overhear.instance.lock")
        if let dir = baseDir {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if let values = try? dir.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
                logger.error("Instance lock directory is a symlink; falling back to /tmp for lock file")
            } else {
                chosenLockURL = dir.appendingPathComponent("instance.lock")
            }
        }
        self.lockURL = chosenLockURL
        self.logger = logger
    }

    /// Attempts to acquire the single-instance lock. Returns false when another live process holds the lock.
    func acquire() -> Bool {
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd != -1 else {
            logger.error("Failed to open instance lock at \(self.lockURL.path, privacy: .public); errno=\(errno)")
            return false
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let pid = getpid()
        var locked = false
        var retainFD = false
        defer {
            if locked && !retainFD {
                flock(fd, LOCK_UN)
            }
            if !retainFD {
                close(fd)
            }
        }

        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let holderPID = readLockPID(from: lockURL)
            if let holderPID, !isProcessRunning(pid: holderPID) {
                logger.notice("Detected stale instance lock for pid \(holderPID); attempting to reclaim")
                if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                    locked = true
                    retainFD = true
                    self.fd = fd
                    writePID(pid, to: fd)
                    return true
                } else {
                    // Brief backoff to reduce TOCTOU window if another process races to reclaim.
                    usleep(50_000)
                    if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                        locked = true
                        retainFD = true
                        self.fd = fd
                        writePID(pid, to: fd)
                        return true
                    }
                }
            } else if let holderPID {
                logger.error("Another Overhear instance is already running (pid \(holderPID))")
            } else {
                logger.error("Another Overhear instance is already running")
            }
            return false
        }

        locked = true
        retainFD = true
        self.fd = fd
        writePID(pid, to: fd)
        return true
    }

    func release() {
        guard let fd else { return }
        flock(fd, LOCK_UN)
        close(fd)
        self.fd = nil
    }
}

private extension InstanceLock {
    func writePID(_ pid: Int32, to fd: Int32) {
        let data = "\(pid)\n".data(using: .utf8) ?? Data()
        _ = ftruncate(fd, 0)
        _ = lseek(fd, 0, SEEK_SET)
        data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            _ = write(fd, base, ptr.count)
        }
        _ = fsync(fd)
    }

    func readLockPID(from url: URL) -> Int32? {
        guard let contents = try? String(contentsOf: url).trimmingCharacters(in: .whitespacesAndNewlines),
              let value = Int32(contents) else {
            return nil
        }
        return value
    }

    func isProcessRunning(pid: Int32) -> Bool {
        let result = kill(pid, 0)
        if result == 0 { return true }
        if errno == ESRCH {
            return false
        }
        // Conservatively treat other errors (e.g., EPERM) as “running”.
        return true
    }
}
