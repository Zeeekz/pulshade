import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import PhotosUI
#else
import AppKit
#endif

/// Photos and videos from the library for a chat message, straight from the attach menu ("Upload media"): up to ten
/// photos, and one video, picked together. Photos come back as cleaned JPEGs, the video as a clip held in memory
/// (mapped from the picker's own file, never copied to a file of ours), still to be made ready for the chat.
@MainActor
enum ChatMediaPicker {
    struct Picked {
        var photos: [Data] = []
        var clip: MemoryClip?
        /// Videos past the first: a message carries one.
        var extraVideos = 0
        /// Items that couldn't be read (an iCloud video while offline, say, or one too big to hold).
        var failed = 0
        /// Photos past what the message has room for (ten in all).
        var dropped = 0

        /// What to tell the person about what was left out, if anything.
        var note: String? {
            var parts: [String] = []
            if extraVideos > 0 { parts.append("Only one video can go at a time, so the first one you picked was added.") }
            if dropped > 0 {
                parts.append(dropped == 1 ? "A message takes up to 10 photos, so one was left out."
                                          : "A message takes up to 10 photos, so \(dropped) were left out.")
            }
            if failed > 0 {
                parts.append(failed == 1 ? "One item couldn't be loaded. If it's kept in iCloud, check you're online and try again."
                                         : "\(failed) items couldn't be loaded. If they're kept in iCloud, check you're online and try again.")
            }
            return parts.isEmpty ? nil : parts.joined(separator: " ")
        }
    }

    /// The biggest video held in memory, as for stories (it's mapped, so mostly the phone's storage).
    nonisolated static let largestVideo = 1_500_000_000

    static func present(limit: Int, maxSide: CGFloat, done: @escaping (Picked) -> Void) {
        #if os(iOS)
        PhotoLibrarySheet.present(limit: limit, maxSide: maxSide, done: done)
        #else
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .movie]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        // Read and cleaned off the main thread, so the window doesn't hang over a handful of big photos.
        Task {
            let picked = await Task.detached(priority: .userInitiated) { load(urls, limit: limit, maxSide: maxSide) }.value
            done(picked)
        }
        #endif
    }

    #if os(macOS)
    private nonisolated static func load(_ urls: [URL], limit: Int, maxSide: CGFloat) -> Picked {
        var picked = Picked()
        for url in urls {
            let isMovie = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .movie) == true
            if isMovie {
                if picked.clip != nil { picked.extraVideos += 1; continue }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                if size > 0, size <= largestVideo, let bytes = try? Data(contentsOf: url, options: .mappedIfSafe) {
                    picked.clip = MemoryClip(bytes)
                } else {
                    picked.failed += 1
                }
            } else if picked.photos.count < limit {
                if let bytes = try? Data(contentsOf: url, options: .mappedIfSafe), ImageLimits.isReasonable(bytes),
                   let image = NSImage(data: bytes), let data = cleanJPEG(image, maxSide: maxSide) {
                    picked.photos.append(data)
                } else {
                    picked.failed += 1
                }
            } else {
                picked.dropped += 1
            }
        }
        return picked
    }
    #endif
}

#if os(iOS)
/// Apple's photo picker, shown from UIKit like `LibraryPicker` (SwiftUI's own was closed under other sheets before it
/// could answer), with several items allowed and photos and videos mixed.
@MainActor
private final class PhotoLibrarySheet: NSObject, PHPickerViewControllerDelegate {
    private static var current: PhotoLibrarySheet?
    private var done: ((ChatMediaPicker.Picked) -> Void)?
    private var maxSide: CGFloat = 1600

    static func present(limit: Int, maxSide: CGFloat, done: @escaping (ChatMediaPicker.Picked) -> Void) {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .any(of: [.images, .videos])
        configuration.selectionLimit = max(1, limit)
        configuration.selection = .ordered
        // An HDR or otherwise unusual clip is turned into an ordinary one by iOS before the app sees it.
        configuration.preferredAssetRepresentationMode = .compatible
        guard var top = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })?.keyWindow?.rootViewController else { return }
        while let next = top.presentedViewController { top = next }
        let controller = PHPickerViewController(configuration: configuration)
        let sheet = PhotoLibrarySheet()
        sheet.done = done
        sheet.maxSide = maxSide
        controller.delegate = sheet
        current = sheet
        top.present(controller, animated: true)
    }

    nonisolated func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        let providers = results.map(\.itemProvider)
        Task { @MainActor in
            picker.dismiss(animated: true)
            guard !providers.isEmpty, let done = self.done else { Self.current = nil; return }
            self.done = nil
            let movies = providers.contains { $0.hasItemConformingToTypeIdentifier(UTType.movie.identifier) }
            // Said at once: a video kept in iCloud is downloaded first, which can take a while.
            LoadingHUD.show(movies ? "Getting your video…" : "Getting your photos…")
            let picked = await Self.load(providers, maxSide: self.maxSide)
            LoadingHUD.hide()
            Self.current = nil
            done(picked)
        }
    }

    private static func load(_ providers: [NSItemProvider], maxSide: CGFloat) async -> ChatMediaPicker.Picked {
        var picked = ChatMediaPicker.Picked()
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                if picked.clip != nil { picked.extraVideos += 1; continue }
                if let clip = await clip(from: provider) { picked.clip = clip } else { picked.failed += 1 }
            } else if provider.canLoadObject(ofClass: UIImage.self) {
                if let data = await photo(from: provider, maxSide: maxSide) { picked.photos.append(data) } else { picked.failed += 1 }
            } else {
                picked.failed += 1
            }
        }
        return picked
    }

    /// The picker's file is only there until its callback returns, so it's mapped into memory then.
    private nonisolated static func clip(from provider: NSItemProvider) async -> MemoryClip? {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, _ in
                guard let url, let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                      size > 0, size <= ChatMediaPicker.largestVideo,
                      let bytes = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: MemoryClip(bytes))
            }
        }
    }

    /// Read and cleaned (no location or camera details, at most `maxSide`) off the main thread.
    private nonisolated static func photo(from provider: NSItemProvider, maxSide: CGFloat) async -> Data? {
        await withCheckedContinuation { continuation in
            provider.loadObject(ofClass: UIImage.self) { object, _ in
                guard let image = object as? UIImage else { continuation.resume(returning: nil); return }
                continuation.resume(returning: cleanJPEG(image, maxSide: maxSide))
            }
        }
    }
}
#endif
