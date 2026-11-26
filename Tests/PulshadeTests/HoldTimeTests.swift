import Foundation
import Testing
@testable import Pulshade

/// The Burn tab's hold times: defaults, saved values and the ranges they are kept to.
struct HoldTimeTests {
    @Test func defaultsAreTwoFiveAndFive() {
        let s = SecuritySettings()
        #expect(s.lockHold == 2)
        #expect(s.detachHold == 5)
        #expect(s.burnHold == 5)
    }

    @Test func settingsFromBeforeGetTheDefaults() throws {
        let s = try JSONDecoder().decode(SecuritySettings.self, from: Data(#"{"autoLockMinutes":5}"#.utf8))
        #expect(s.lockHold == 2)
        #expect(s.detachHold == 5)
        #expect(s.burnHold == 5)
    }

    @Test func savedTimesComeBack() throws {
        var s = SecuritySettings()
        s.lockHold = 0
        s.detachHold = 2.5
        s.burnHold = 3
        let back = try JSONDecoder().decode(SecuritySettings.self, from: JSONEncoder().encode(s))
        #expect(back.lockHold == 0)
        #expect(back.detachHold == 2.5)
        #expect(back.burnHold == 3)
    }

    @Test func outOfRangeTimesAreKeptInRange() throws {
        let json = #"{"lockHold":9,"detachHold":0,"burnHold":-1}"#
        let s = try JSONDecoder().decode(SecuritySettings.self, from: Data(json.utf8))
        #expect(s.lockHold == 2)
        #expect(s.detachHold == 2)
        #expect(s.burnHold == 2)
    }
}

/// Once the hold times are chosen the Burn tab stops offering them; older settings haven't chosen yet.
struct HoldTimesChosenTests {
    @Test func chosenIsKeptAndStartsOff() throws {
        #expect(!SecuritySettings().holdTimesChosen)
        #expect(try !JSONDecoder().decode(SecuritySettings.self, from: Data(#"{"lockHold":1}"#.utf8)).holdTimesChosen)
        var s = SecuritySettings()
        s.holdTimesChosen = true
        #expect(try JSONDecoder().decode(SecuritySettings.self, from: JSONEncoder().encode(s)).holdTimesChosen)
    }
}
