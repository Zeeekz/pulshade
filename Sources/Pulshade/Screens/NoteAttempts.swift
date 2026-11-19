import Foundation

/// Wrong-password attempts for locked profile notes, kept across closing and reopening the sheet. Without this,
/// the lockout was per sheet: close and reopen was a free reset.
enum NoteAttempts {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var failures: [String: Int] = [:]
    nonisolated(unsafe) private static var waitUntil: [String: Date] = [:]

    /// When this note may be tried again.
    static func wait(for id: String) -> Date {
        lock.withLock { waitUntil[id] ?? .distantPast }
    }

    /// Counts a wrong password and returns the new count.
    @discardableResult
    static func failed(_ id: String) -> Int {
        lock.withLock {
            let count = (failures[id] ?? 0) + 1
            failures[id] = count
            if count >= 3 { waitUntil[id] = Date().addingTimeInterval(Double(min(30, count * 3))) }
            return count
        }
    }

    /// The note opened: forget this note's attempts.
    static func opened(_ id: String) {
        lock.withLock {
            failures[id] = nil
            waitUntil[id] = nil
        }
    }
}
