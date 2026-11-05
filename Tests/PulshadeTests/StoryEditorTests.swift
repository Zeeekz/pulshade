import Testing
import Foundation
import CoreImage
@testable import Pulshade

@MainActor
struct StoryEditorTests {
    private func hello() -> StoryTextOverlay {
        var item = StoryTextOverlay()
        item.text = "Hello"
        item.size = 0.12
        return item
    }

    @Test func textIsDrawnAtTheStoryFrameAndEmptyTextIsLeftOut() throws {
        let words = try #require(StoryOverlayRender.text([hello()]))
        #expect(words.extent.size == StoryOverlayRender.size)
        #expect(StoryOverlayRender.text([StoryTextOverlay()]) == nil)
        #expect(StoryOverlayRender.text([]) == nil)
    }

    @Test func textChangesAPhotoAndCropsItToTheFrame() throws {
        let photo = StoryMediaTests.photo()
        let words = try #require(StoryOverlayRender.text([hello()]))
        let plain = try #require(StoryFilter.none.bake(into: photo))
        let withText = try #require(StoryFilter.none.bake(into: photo, text: words))
        #expect(plain != withText)
        let size = try #require(CIImage(data: withText)).extent.size
        #expect(abs(size.width / size.height - 9.0 / 16.0) < 0.01)
    }

    @Test func aTextStoryBecomesAPicture() throws {
        let made = try #require(StoryOverlayRender.textStory([hello()], palette: 1, seed: "x"))
        let size = try #require(CIImage(data: made)).extent.size
        #expect(size == StoryOverlayRender.size)
    }

    @Test func textGoesOverEveryFrameOfAClip() async throws {
        let words = try #require(StoryOverlayRender.text([hello()]))
        let url = try await StoryMediaTests.clip(seconds: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let plain = try await StoryVideo.export(from: url, filter: .none)
        let withText = try await StoryVideo.export(from: url, filter: .none, text: words)
        #expect(!withText.isEmpty && plain != withText)
    }

    @Test func colourBackgroundsKeepTextReadable() {
        #expect(StoryInk.readable(on: 0) == .black)   // white block, dark words
        #expect(StoryInk.readable(on: 1) == .white)   // black block, light words
    }
}
