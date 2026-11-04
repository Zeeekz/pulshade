import Testing
import Foundation
@testable import Pulshade

struct StoryTests {
    @Test func audiencesIncludeTheRightPeople() {
        #expect(StoryAudience.everyone.includes("a"))
        #expect(StoryAudience.only(["a"]).includes("a") && !StoryAudience.only(["a"]).includes("b"))
        #expect(!StoryAudience.except(["a"]).includes("a") && StoryAudience.except(["a"]).includes("b"))
    }

    @Test func storiesSavedBeforeLifetimesLastADay() throws {
        let old = #"{"id":"6B29FC40-CA47-1067-B31D-00DD010662DA","author":"me","style":{"text":{"_0":"hi","palette":0}},"date":0,"seen":false}"#
        let story = try JSONDecoder().decode(Story.self, from: Data(old.utf8))
        #expect(story.lifetime == nil && story.audience == nil && story.shownTo == .everyone)
        #expect(story.expires == story.date.addingTimeInterval(86_400))
    }

    @Test func aStoryFromAnOlderAppStillDecodes() throws {
        let payload = Payload.story(id: UUID(), style: .text("hi", palette: 0), date: Date())
        let decoded = try JSONDecoder.pulshade.decode(Payload.self, from: JSONEncoder.pulshade.encode(payload))
        guard case let .story(_, _, _, lasts) = decoded else { Issue.record("not a story"); return }
        #expect(lasts == nil)
    }
}
