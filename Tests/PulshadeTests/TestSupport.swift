import Foundation
#if canImport(Darwin)
import Darwin
#endif
@testable import Pulshade

/// True when the suite is running under Address/Thread/Undefined sanitizer instrumentation, which slows
/// everything down enough that wall-clock assertions are meaningless.
var runningUnderSanitizer: Bool {
    #if canImport(Darwin)
    // The runtime defines these symbols in the process it instruments; the environment isn't reliable.
    func present(_ name: String) -> Bool {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) != nil
    }
    return present("__asan_init") || present("__tsan_init") || present("__ubsan_handle_add_overflow")
    #else
    return false
    #endif
}

/// Set once, thread-safely: tests keep keys in memory so they don't leave hundreds of items in the login
/// Keychain. Writing this from every `testDirectory` call raced when suites ran in parallel.
private let inMemoryKeysConfigured: Void = { FileKeys.inMemory = true }()

/// Where tests put throwaway vaults. `PULSHADE_TEST_DIR` overrides the system temp folder,
/// for sandboxes that don't allow writing there.
func testDirectory(_ prefix: String) -> URL {
    _ = inMemoryKeysConfigured
    let base = ProcessInfo.processInfo.environment["PULSHADE_TEST_DIR"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.temporaryDirectory
    return base.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
}

/// A model for tests: no system watching, no microphone, and no random delays.
@MainActor func testModel(_ prefix: String) -> AppModel {
    let model = AppModel(vault: Vault(directory: testDirectory(prefix)), watchSystem: false)
    model.callAudio = false
    model.trafficShaping = false
    model.cutOffOnLock = false
    // Unlocks answer at once; the timing itself is tested on its own (`LockTimingTests`).
    model.unlockSettle = .zero
    // Invites to groups and channels wait for a yes; tests about other things say yes at once (LinkAuditFixTests don't).
    model.acceptsInvitesForTests = true
    return model
}

extension AppModel {
    /// A sync that really runs: one asked for while another is under way (the app's own, say) returns at once and does
    /// nothing, which under a busy test run used up a test's rounds before anything had arrived.
    func syncOnceFully() async {
        var waited = 0
        while isSyncing, waited < 150 {
            try? await Task.sleep(for: .milliseconds(20))
            waited += 1
        }
        await syncOnce()
    }
}
