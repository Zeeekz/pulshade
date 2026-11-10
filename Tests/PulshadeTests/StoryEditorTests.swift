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
        let clip = try await StoryMediaTests.clip(seconds: 1)
        let plain = try await StoryVideo.export(from: clip, filter: .none)
        let withText = try await StoryVideo.export(from: clip, filter: .none, text: words)
        #expect(!withText.isEmpty && plain != withText)
    }

    @Test func colourBackgroundsKeepTextReadable() {
        #expect(StoryInk.readable(on: 0) == .black)   // white block, dark words
        #expect(StoryInk.readable(on: 1) == .white)   // black block, light words
    }

    @Test func touchesFindTextWhereItIsDrawnScaledAndTurned() {
        let centre = CGPoint(x: 200, y: 300), size = CGSize(width: 100, height: 40)
        #expect(StoryOverlayCanvas.hits(CGPoint(x: 240, y: 300), center: centre, size: size, scale: 1, rotation: 0))
        #expect(!StoryOverlayCanvas.hits(CGPoint(x: 300, y: 300), center: centre, size: size, scale: 1, rotation: 0))
        // Scaled up three times, the far end of the words is still theirs.
        #expect(StoryOverlayCanvas.hits(CGPoint(x: 340, y: 300), center: centre, size: size, scale: 3, rotation: 0))
        // Turned a quarter, the words run up and down: along their length is a hit, across it is not.
        #expect(StoryOverlayCanvas.hits(CGPoint(x: 200, y: 245), center: centre, size: size, scale: 1, rotation: .pi / 2))
        #expect(!StoryOverlayCanvas.hits(CGPoint(x: 250, y: 300), center: centre, size: size, scale: 1, rotation: .pi / 2))
        // Tiny text still takes a finger.
        #expect(StoryOverlayCanvas.hits(CGPoint(x: 220, y: 300), center: centre, size: CGSize(width: 8, height: 8), scale: 0.3, rotation: 0))
    }

    @Test func turnsClickUprightAndSizesStretchPastTheirLimits() {
        #expect(StoryOverlayCanvas.snapTurn(0.04) == (0, true))
        #expect(StoryOverlayCanvas.snapTurn(.pi / 2 - 0.05).1)
        #expect(StoryOverlayCanvas.snapTurn(0.3) == (0.3, false))
        #expect(StoryOverlayCanvas.softScale(2) == 2)
        let big = StoryOverlayCanvas.softScale(40)
        #expect(big > 6 && big < 9, "past the largest size it stretches only a little: \(big)")
        let small = StoryOverlayCanvas.softScale(0.01)
        #expect(small < 0.3 && small > 0.2, "and the same at the smallest: \(small)")
    }

    @Test func rubberBandingGivesWayLessAndLess() {
        #expect(RubberBand.clamp(5, 0...10, span: 4) == 5)
        let a = RubberBand.clamp(12, 0...10, span: 4), b = RubberBand.clamp(30, 0...10, span: 4)
        #expect(a > 10 && b > a && b < 14, "\(a) \(b)")
        #expect(RubberBand.clamp(-1000, 0...10, span: 4) > -4)
        #expect(RubberBand.clamp(12, 0...10, span: 0) == 10)
    }
}
