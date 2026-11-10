import Testing
import Foundation
import CoreGraphics
@testable import Pulshade

struct ChatBackgroundTests {
    @Test func eachThemeHasItsOwnBackground() {
        #expect(Set(Theme.all.map(\.backdrop)).count == Theme.all.count)
        let unset = ChatBackground()
        for theme in Theme.all { #expect(unset.shown(in: theme) == theme.backdrop) }
    }

    @Test func aPhotoThatIsntHereFallsBackToTheTheme() {
        var background = ChatBackground()
        background.style = .photo
        #expect(background.shown(in: .light) == Theme.light.backdrop)
        background.photo = Data([1])
        #expect(background.shown(in: .light) == .photo)
    }

    /// The photo always covers the whole chat, whatever shape the window is, and never leaves a gap at an edge.
    @Test func thePhotoFillsAnyShapeOfWindow() {
        let image = CGSize(width: 1600, height: 1200)
        for box in [CGSize(width: 390, height: 844), CGSize(width: 1400, height: 500), CGSize(width: 600, height: 600)] {
            for zoom in [1.0, 2.5, 4.0] {
                for focus in [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 1, y: 1)] {
                    let rect = ChatBackground.layout(image: image, in: box, zoom: zoom, focus: focus)
                    #expect(rect.minX <= 0.001 && rect.minY <= 0.001)
                    #expect(rect.maxX >= box.width - 0.001 && rect.maxY >= box.height - 0.001)
                    #expect(abs(rect.width / rect.height - image.width / image.height) < 0.001)
                }
            }
        }
    }

    @Test func theFocusPointSitsInTheMiddleWhenItCan() {
        let rect = ChatBackground.layout(image: CGSize(width: 2000, height: 2000), in: CGSize(width: 400, height: 800), zoom: 2,
                                         focus: CGPoint(x: 0.5, y: 0.5))
        #expect(abs(rect.midX - 200) < 0.001 && abs(rect.midY - 400) < 0.001)
    }

    @Test func oddOrNewerValuesOpenSafely() throws {
        let json = #"{"style":"aurora","zoom":99,"focusX":-3,"fade":"x","patternSize":0.1}"#
        let background = try JSONDecoder().decode(ChatBackground.self, from: Data(json.utf8))
        #expect(background.style == .theme)
        #expect(background.zoom == ChatBackground.zoomRange.upperBound)
        #expect(background.focusX == 0 && background.focusY == 0.5)
        #expect(background.fade == 0.25)
        #expect(background.patternSize == ChatBackground.patternRange.lowerBound)
    }

    @MainActor @Test func thePhotoNeverGoesInTheBackup() throws {
        var data = AppData()
        data.chatBackground.style = .photo
        data.chatBackground.photo = Data(repeating: 7, count: 100)
        let kept = AppModel.backupContents(of: data)
        #expect(kept.chatBackground.photo == nil)
        #expect(kept.chatBackground.style == .photo)
        let opened = try JSONDecoder.pulshade.decode(AppData.self, from: JSONEncoder.pulshade.encode(data))
        #expect(opened.chatBackground == data.chatBackground, "and it's kept in the vault itself")
    }
}
