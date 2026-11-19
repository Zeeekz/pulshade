import Testing
import Foundation
@testable import Pulshade

/// The lockout for a locked note must survive closing and reopening the sheet, or it is a free reset.
@Suite struct NoteAttemptsTests {
    @Test func lockoutSurvivesReopening() {
        let id = UUID().uuidString
        #expect(NoteAttempts.wait(for: id) == .distantPast)
        #expect(NoteAttempts.failed(id) == 1)
        #expect(NoteAttempts.failed(id) == 2)
        #expect(NoteAttempts.wait(for: id) == .distantPast, "two misses is not a lockout")
        #expect(NoteAttempts.failed(id) == 3)
        #expect(NoteAttempts.wait(for: id) > Date(), "the third miss makes it wait")
    }

    @Test func openingForgetsTheFailures() {
        let id = UUID().uuidString
        _ = NoteAttempts.failed(id)
        _ = NoteAttempts.failed(id)
        _ = NoteAttempts.failed(id)
        #expect(NoteAttempts.wait(for: id) > Date())
        NoteAttempts.opened(id)
        #expect(NoteAttempts.wait(for: id) == .distantPast)
        #expect(NoteAttempts.failed(id) == 1, "the count starts again")
    }
}
