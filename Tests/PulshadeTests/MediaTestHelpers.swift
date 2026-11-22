import Foundation
@testable import Pulshade

/// Received photos, clips and voice notes live in the sealed media pool, with only a reference in the message or story.
/// These put the bytes back, so a test can compare what arrived with what was sent.
@MainActor
extension AppModel {
    func shown(_ story: Story) -> StoryStyle {
        switch story.style {
        case let .image(_, caption): .image(storyData(for: story) ?? Data(), caption: caption)
        case let .video(_, caption): .video(storyData(for: story) ?? Data(), caption: caption)
        case .text: story.style
        }
    }

    func shown(_ message: Message) -> Message {
        var out = message
        if message.imageFile != nil { out.image = imageData(for: message) }
        if message.videoFile != nil { out.video = videoData(for: message) }
        if message.voice?.audioFile != nil { out.voice?.audio = voiceAudio(for: message) ?? Data() }
        out.imageFile = nil
        out.videoFile = nil
        out.voice?.audioFile = nil
        return out
    }
}
