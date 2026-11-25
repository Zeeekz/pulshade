import Testing
import Foundation
@testable import Pulshade

/// The sealed media pool: random per-file keys, padded buckets, fillers, uniform dates, overwrite-on-delete and wipe,
/// growth in doubling steps, and never touching a file another account on the device might own.
struct MediaPoolTests {
    private func makePool(_ prefix: String) -> MediaPool { MediaPool(directory: testDirectory(prefix)) }

    private func modificationDates(_ pool: MediaPool) throws -> [Int] {
        let urls = try FileManager.default.contentsOfDirectory(at: pool.mediaDirectory, includingPropertiesForKeys: nil) + [pool.mediaDirectory]
        return urls.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .map { Int($0.timeIntervalSince1970) }
    }

    private func contents(_ pool: MediaPool) throws -> [String: Data] {
        var out: [String: Data] = [:]
        for url in try FileManager.default.contentsOfDirectory(at: pool.mediaDirectory, includingPropertiesForKeys: nil) {
            out[url.lastPathComponent] = try Data(contentsOf: url)
        }
        return out
    }

    @Test func aSealedItemRoundTripsAndLooksLikeRandomBytes() throws {
        let pool = makePool("pulshade-media-roundtrip")
        let plain = Data(repeating: 0x41, count: 300_000)
        let ref = try pool.store(plain)

        #expect(try pool.load(ref) == plain)
        #expect(pool.fileCount == MediaPool.smallest, "the first item already comes with a full pool of filler")

        let second = try pool.store(plain)
        #expect(second.name != ref.name)
        #expect(second.key != ref.key, "every file has its own random key")
        #expect(pool.fileCount == MediaPool.smallest, "a second item reuses filler: nothing changes on disk")

        let raw = try Data(contentsOf: pool.mediaDirectory.appendingPathComponent(ref.name))
        #expect(raw.range(of: plain) == nil, "nothing is stored in the clear")
        #expect(pool.mediaDirectory.path.hasPrefix(pool.directory.path), "the pool is inside the vault's folder")
        for file in try FileManager.default.contentsOfDirectory(at: pool.mediaDirectory, includingPropertiesForKeys: [.fileSizeKey]) {
            let size = try #require(file.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            #expect(Vault.paddedSize(size) == size, "every file lands on a vault bucket")
        }
    }

    @Test func thePoolGrowsInDoublingStepsToTwiceWhatItHolds() throws {
        #expect(MediaPool.target(forReal: 0, files: 0) == 16)
        #expect(MediaPool.target(forReal: 8, files: 16) == 16)
        #expect(MediaPool.target(forReal: 9, files: 16) == 32)
        #expect(MediaPool.target(forReal: 37, files: 64) == 128)
        let pool = makePool("pulshade-media-grow")
        let item = Data([1, 2, 3])
        for _ in 0..<8 { _ = try pool.store(item) }
        #expect(pool.fileCount == 16)
        _ = try pool.store(item)
        #expect(pool.fileCount == 32, "nine items need at least eighteen files: the next power of two")
        #expect(pool.fileCount >= 2 * pool.realNames.count)
    }

    @Test func deleteOverwritesTheFileKeepsTheShapeAndTheFillerIsReused() throws {
        let pool = makePool("pulshade-media-delete")
        let ref = try pool.store(Data(repeating: 7, count: 200_000))
        let url = pool.mediaDirectory.appendingPathComponent(ref.name)
        let beforeSize = try #require(url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let beforeCount = pool.fileCount

        try pool.delete(ref)
        #expect(pool.fileCount == beforeCount, "a deletion keeps the file count")
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == beforeSize)
        var threw = false
        do { _ = try pool.load(ref) } catch { threw = true }
        #expect(threw, "the deleted item's key opens nothing")
        #expect(pool.ownFillers.contains(ref.name), "the overwritten file is this account's filler now")
        #expect(Set(try modificationDates(pool)).count == 1, "every file and the folder share one date")
    }

    /// Another account on the device (a decoy, or the real one seen from a decoy) has files this one can't tell from
    /// filler. They must never be overwritten or removed, however this account stores and deletes.
    @Test func filesThisAccountDoesNotKnowAreNeverTouched() throws {
        let directory = testDirectory("pulshade-media-shared")
        let real = MediaPool(directory: directory)
        var realRefs: [MediaFileRef] = []
        for n in 0..<5 { realRefs.append(try real.store(Data(repeating: UInt8(n), count: 70_000))) }
        let theirs = try contents(real)

        // A second account starts with no idea which files are which, and works the pool hard.
        let decoy = MediaPool(directory: directory)
        var decoyRefs: [MediaFileRef] = []
        for n in 0..<40 { decoyRefs.append(try decoy.store(Data(repeating: UInt8(100 + n % 50), count: 1_000))) }
        for ref in decoyRefs.prefix(30) { try decoy.delete(ref) }
        for n in 0..<20 { _ = try decoy.store(Data(repeating: UInt8(200 + n % 50), count: 1_000)) }

        let after = try contents(real)
        for (name, bytes) in theirs {
            #expect(after[name] == bytes, "a file another account might own is left exactly as it was")
        }
        #expect(after.count >= theirs.count, "and nothing is ever removed")
        for (n, ref) in realRefs.enumerated() {
            #expect(try real.load(ref) == Data(repeating: UInt8(n), count: 70_000))
        }
    }

    @Test func wrongKeysMissingFilesAndTamperingAllFail() throws {
        let pool = makePool("pulshade-media-corrupt")
        let ref = try pool.store(Data(repeating: 9, count: 100_000))

        var wrongKey = ref
        wrongKey.key = Data(count: 32)
        var failed = false
        do { _ = try pool.load(wrongKey) } catch { failed = true }
        #expect(failed)

        var missing = ref
        missing.name = "not-there"
        failed = false
        do { _ = try pool.load(missing) } catch { failed = true }
        #expect(failed)

        let url = pool.mediaDirectory.appendingPathComponent(ref.name)
        var raw = try Data(contentsOf: url)
        raw[raw.startIndex] ^= 0xff
        try raw.write(to: url)
        failed = false
        do { _ = try pool.load(ref) } catch { failed = true }
        #expect(failed)
    }

    @Test func wipeRemovesTheWholePool() throws {
        let pool = makePool("pulshade-media-wipe")
        _ = try pool.store(Data([1, 2, 3]))
        pool.wipe()
        #expect(!FileManager.default.fileExists(atPath: pool.mediaDirectory.path))
        #expect(pool.fileCount == 0)
        #expect(pool.ownFillers.isEmpty)
    }

    @Test func destroyingTheVaultWipesTheMediaPool() throws {
        let directory = testDirectory("pulshade-media-destroy")
        let vault = Vault(directory: directory)
        let pool = MediaPool(directory: directory)
        _ = try pool.store(Data("secret".utf8))
        #expect(FileManager.default.fileExists(atPath: pool.mediaDirectory.path))

        vault.destroy(leavingNoTrace: true)
        #expect(!FileManager.default.fileExists(atPath: pool.mediaDirectory.path))
    }

    /// An item goes into its filler's own file (same inode), so real files can't be picked out from filler by being newer
    /// files, and every file's change time moves together.
    @Test func anItemIsWrittenIntoItsFillersOwnFile() throws {
        let pool = makePool("pulshade-media-inode")
        _ = try pool.store(Data([1]))
        func inodes() throws -> [String: Int] {
            var out: [String: Int] = [:]
            for url in try FileManager.default.contentsOfDirectory(at: pool.mediaDirectory, includingPropertiesForKeys: nil) {
                out[url.lastPathComponent] = (try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int) ?? -1
            }
            return out
        }
        let before = try inodes()
        let ref = try pool.store(Data(repeating: 7, count: 5_000))
        let after = try inodes()
        #expect(after[ref.name] == before[ref.name], "the same file, not a new one in its place")
        #expect(try pool.load(ref) == Data(repeating: 7, count: 5_000))
        // Every file's change time is the same second.
        var changed = Set<Int>()
        for url in try FileManager.default.contentsOfDirectory(at: pool.mediaDirectory, includingPropertiesForKeys: nil) {
            var info = stat()
            #expect(stat(url.path, &info) == 0)
            changed.insert(Int(info.st_ctimespec.tv_sec))
        }
        #expect(changed.count == 1)
    }

    /// A panic's wipe returns at once: the pool is gone from its place straight away and overwritten in the background.
    @Test func wipingSoonMovesThePoolAsideAndFinishesIt() async throws {
        let pool = makePool("pulshade-media-wipesoon")
        _ = try pool.store(Data([1, 2, 3]))
        pool.wipeSoon()
        #expect(!FileManager.default.fileExists(atPath: pool.mediaDirectory.path))
        #expect(pool.fileCount == 0)
        // Nothing beside the vault's files says a wipe happened: the pool went into the always-present work folder under a
        // random name, and is gone from there once overwritten.
        let names = try FileManager.default.contentsOfDirectory(atPath: pool.directory.path)
        #expect(!names.contains { $0.hasPrefix(".") || $0.contains("media") || $0.contains("gone") })
        let work = Vault.workURL(in: pool.directory)
        for _ in 0..<50 {
            if ((try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []).isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []).isEmpty)
    }

    /// Whatever the app was closed before overwriting (and a `.media-gone-` folder an older build left) is finished at
    /// the next launch, not only the next time the pool is used.
    @Test @MainActor func aWipeLeftPartWayIsFinishedAtLaunch() async throws {
        let directory = testDirectory("pulshade-media-leftover")
        let vault = Vault(directory: directory)
        let leftover = vault.workURL.appendingPathComponent(Data.random(16).hex, isDirectory: true)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try Data.random(4096).write(to: leftover.appendingPathComponent("a"))
        let older = directory.appendingPathComponent(".media-gone-0011223344556677", isDirectory: true)
        try FileManager.default.createDirectory(at: older, withIntermediateDirectories: true)
        try Data.random(4096).write(to: older.appendingPathComponent("b"))
        _ = AppModel(vault: Vault(directory: directory), watchSystem: false)
        for _ in 0..<50 {
            if !FileManager.default.fileExists(atPath: leftover.path), !FileManager.default.fileExists(atPath: older.path) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(!FileManager.default.fileExists(atPath: leftover.path) && !FileManager.default.fileExists(atPath: older.path))
        #expect(FileManager.default.fileExists(atPath: vault.workURL.path), "the work folder itself stays, so it says nothing")
    }

    /// Storing into a pool that already exists never grows it there and then (the app does that on the main thread, for
    /// anything anyone sends): it says the pool wants growing, and a copy grows it in the background.
    @Test func aBigGrowthIsLeftForTheBackground() throws {
        let pool = makePool("pulshade-media-later")
        let item = Data([1, 2, 3])
        for _ in 0..<8 { _ = try pool.store(item, growLater: true) }
        #expect(pool.fileCount == 16, "the very first pool is still made at once: it's small")
        _ = try pool.store(item, growLater: true)
        #expect(pool.fileCount == 16, "nine items want thirty-two files, but not now")
        #expect(pool.wantsGrowth)
        let worker = MediaPool(directory: pool.directory, realNames: pool.realNames, ownFillers: pool.ownFillers)
        let made = try worker.topUp(since: worker.wipes)
        #expect(worker.fileCount == 32 && made.count == 16)

        // An account with no filler of its own beside a big pool (a decoy) makes one file for its item, nothing more.
        let decoy = MediaPool(directory: pool.directory)
        let ref = try decoy.store(Data([9]), growLater: true)
        #expect(decoy.fileCount == 33)
        #expect(decoy.wantsGrowth)
        #expect(try decoy.load(ref) == Data([9]))
    }

    /// A growth asked for before Burn, Detach or a panic wiped the pool makes nothing, and never brings the pool back.
    @Test func aGrowthAskedForBeforeAWipeMakesNothing() throws {
        let pool = makePool("pulshade-media-burngrow")
        _ = try pool.store(Data([1]))
        let asked = pool.wipes
        let worker = MediaPool(directory: pool.directory, realNames: pool.realNames, ownFillers: pool.ownFillers)
        pool.wipe()
        #expect(throws: (any Error).self) { _ = try worker.topUp(since: asked) }
        #expect(!FileManager.default.fileExists(atPath: pool.mediaDirectory.path), "the pool stays gone")
    }
}
