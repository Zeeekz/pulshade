import Testing
import Foundation
@testable import Pulshade
@testable import PulshadeShared

/// What the profile review asked for: names and bios cleaned, PULSHADE look-alikes labelled, profile stamps that only
/// go up, and the Creator badge tied to the creator's key.
@MainActor
struct ProfileSafetyTests {
    @Test func namesLoseHiddenMarksNewLinesAndPiledAccents() {
        #expect(ProfileText.name("Ev\u{202E}il\u{200B} Kai") == "Evil Kai")
        #expect(ProfileText.name("two\nlines\there") == "two lines here")
        #expect(ProfileText.name(String(repeating: "a", count: 200)).count == ProfileText.maxName)
        #expect(ProfileText.name("Z\u{301}\u{302}\u{303}\u{304}\u{305}a") == "Z\u{301}\u{302}a", "no more than two accents on a letter")
        #expect(ProfileText.name("Zoë") == "Zoë")
        #expect(ProfileText.bio("  \u{200F}  ") == nil)
        #expect(ProfileText.bio(String(repeating: "b", count: 500))?.count == ProfileText.maxBio)
        #expect(ProfileText.bio("Line one\nLine two") == "Line one\nLine two")
    }

    @Test func namesThatReadAsPulshadeAreLabelled() {
        for fake in ["PULSHADE", "Pulshade Team", "pu1shade", "P U L S H A D E", "P.U.L.S.H.A.D.E", "РULSHАDЕ", "Pulshadé", "ＰＵＬＳＨＡＤＥ"] {
            #expect(ProfileText.impersonatesBrand(fake), "\(fake)")
            #expect(ProfileText.name(fake).hasSuffix(ProfileText.notBrand))
        }
        for real in ["Kai", "Pulse", "Shade", "Paul Shade"] {
            #expect(!ProfileText.impersonatesBrand(real), "\(real)")
        }
    }

    @Test func profileStampsOnlyGoUpEvenIfTheClockStepsBack() {
        let model = AppModel.demo()
        let now = Date()
        let a = model.nextProfileStamp(now: now)
        let b = model.nextProfileStamp(now: now.addingTimeInterval(-3600))
        let c = model.nextProfileStamp(now: now)
        #expect(a < b && b < c)
    }

    @Test func onlyTheCreatorsKeyGetsTheCreatorBadge() {
        #expect(DirectoryProfile.isCreator(handle: "zeekz", signingKey: DirectoryProfile.creatorKey))
        #expect(!DirectoryProfile.isCreator(handle: "zeekz", signingKey: Data(repeating: 7, count: 32)), "a relay can't hand it out")
        #expect(!DirectoryProfile.isCreator(handle: "kai_nights", signingKey: DirectoryProfile.creatorKey), "only on reserved names")
        #expect(DirectoryProfile.creatorKey.count == 32)
    }
}
