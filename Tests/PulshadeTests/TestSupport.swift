import Foundation
@testable import Pulshade

/// Where tests put throwaway vaults. `PULSHADE_TEST_DIR` overrides the system temp folder,
/// for sandboxes that don't allow writing there.
func testDirectory(_ prefix: String) -> URL {
    FileKeys.inMemory = true
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
    return model
}
