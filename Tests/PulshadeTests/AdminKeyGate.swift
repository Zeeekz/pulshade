import Foundation

/// Tests run side by side, and several of them swap in their own admin key, which is one setting for the whole
/// process. Each takes this first and gives it back when it's done, so two never change it under each other.
actor AdminKeyGate {
    static let shared = AdminKeyGate()
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if busy {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            busy = true
        }
    }

    func release() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }
}
