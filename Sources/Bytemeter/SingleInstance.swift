import Foundation

/// Only one Bytemeter may run at a time.
///
/// This matters more than it looks. Two copies would each read the same
/// cumulative counters and the same stored baseline, each work out the same
/// delta, and each write it, so every figure would come out roughly double.
/// The LaunchAgent has KeepAlive set and the app can also be opened by hand, so
/// the two can meet.
///
/// An advisory lock on a file held for the life of the process is the simplest
/// thing that cannot go stale: if the process dies, however it dies, the kernel
/// drops the lock.
enum SingleInstance {

    private static var descriptor: Int32 = -1

    static func claim(at url: URL) -> Bool {
        let folder = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let fd = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return true }     // cannot lock, do not block the app

        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        descriptor = fd                        // held until the process exits
        return true
    }
}
