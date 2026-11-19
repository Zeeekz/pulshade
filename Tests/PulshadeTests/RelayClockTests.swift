import Testing
import Foundation
@testable import Pulshade

/// The relay's clock is learnt from response headers. One header must never move it by days: that is enough to
/// expire a disappearing message early or bring an old one back.
@Suite struct RelayClockTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aSmallCorrectionAppliesAtOnce() {
        let next = RelayClock.next(offset: 0, pending: nil, measured: 3, now: t0)
        #expect(next.offset == 3)
        #expect(next.pending == nil)
    }

    @Test func noiseUnderTwoSecondsIsIgnored() {
        let next = RelayClock.next(offset: 4, pending: nil, measured: 1, now: t0)
        #expect(next.offset == 0, "a difference of a second is just rounding")
        #expect(next.pending == nil)
    }

    @Test func oneLargeSampleDoesNotMoveTheClock() {
        let next = RelayClock.next(offset: 12, pending: nil, measured: 3 * 86_400, now: t0)
        #expect(next.offset == 12, "one header is not evidence")
        #expect(next.pending.map { abs($0.measured - 259_200) < 1 } == true, "\(String(describing: next.pending))")
    }

    @Test func twoAgreeingSamplesMoveIt() {
        let pending = RelayClock.Pending(measured: 3 * 86_400, at: t0)
        let next = RelayClock.next(offset: 12, pending: pending, measured: 3 * 86_400 + 2,
                                   now: t0.addingTimeInterval(60))
        #expect(next.offset == 3 * 86_400 + 2)
        #expect(next.pending == nil)
    }

    @Test func twoDisagreeingSamplesDoNot() {
        let pending = RelayClock.Pending(measured: 3 * 86_400, at: t0)
        let next = RelayClock.next(offset: 12, pending: pending, measured: 6 * 86_400,
                                   now: t0.addingTimeInterval(60))
        #expect(next.offset == 12, "a relay that changes its story moves nothing")
        #expect(next.pending.map { abs($0.measured - 518_400) < 1 } == true, "a relay that changes its story moves nothing")
    }

    @Test func aStaleSampleIsNotEvidence() {
        let pending = RelayClock.Pending(measured: 3 * 86_400, at: t0)
        let next = RelayClock.next(offset: 12, pending: pending, measured: 3 * 86_400,
                                   now: t0.addingTimeInterval(RelayClockTests.anHour))
        #expect(next.offset == 12)
    }

    @Test func theCorrectionIsBounded() {
        let next = RelayClock.next(offset: 0, pending: nil, measured: 1_000 * 86_400, now: t0)
        #expect(next.offset == 0)
        #expect(next.pending.map { abs($0.measured - 604_800) < 1 } == true, "no more than a week, whatever it claims")
    }

    private static let anHour: TimeInterval = 3_600
}
