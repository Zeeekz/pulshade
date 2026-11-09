import SwiftUI
import UniformTypeIdentifiers
#if canImport(PulshadeShared)
import PulshadeShared
#endif

/// A file in a chat. The file itself is kept sealed on the relay: tapping fetches it into this phone's memory, opens it there
/// and shows it. Nothing is written to disk unless the person chooses "Save a copy".
struct FileBubble: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    var message: Message
    var mine: Bool
    @State private var opened: OpenedFile?

    private var attachment: Attachment { message.attachment! }
    private var progress: Double? { model.fileProgress[message.id] }
    private var failure: String? { model.fileFailed[message.id] }
    private var expired: Bool { attachment.expires <= RelayClock.now }
    /// Still on its way up: it's mine, hasn't been told to anyone yet, and nothing has failed.
    private var uploading: Bool { mine && message.status == .queued && failure == nil && progress != nil }

    private var sizeText: String { ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file) }

    private var subtitle: String {
        if let failure { return failure }
        if uploading, let progress { return "Sending… \(Int(progress * 100))%" }
        if let progress { return "Opening… \(Int(progress * 100))%" }
        if attachment.collected == true { return "Opened. It's been erased from the server" }
        if expired { return "No longer available" }
        return sizeText
    }

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(mine ? AnyShapeStyle(Ink.onAccent.opacity(0.8)) : AnyShapeStyle(theme.gradient))
                    if let progress {
                        Circle().trim(from: 0, to: max(0.03, progress))
                            .stroke(mine ? theme.colors[0] : Ink.onAccent, style: .init(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90)).padding(3)
                    }
                    Image(systemName: progress != nil ? "xmark" : (failure != nil ? "exclamationmark" : icon))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(mine ? AnyShapeStyle(theme.colors[0]) : AnyShapeStyle(Ink.onAccent.opacity(0.9)))
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.shownName)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(mine ? Ink.onAccent.opacity(0.92) : Ink.text)
                        .lineLimit(2).truncationMode(.middle)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(failure != nil ? Color.red.opacity(0.9) : (mine ? Ink.onAccent.opacity(0.65) : Ink.dim))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .frame(minWidth: 220, maxWidth: 280, alignment: .leading)
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(attachment.shownName), \(subtitle)")
        .accessibilityHint(progress != nil ? "Cancels" : "Opens the file")
        .sheet(item: $opened) { file in FileSheet(file: file) }
    }

    private var icon: String {
        let type = (attachment.type ?? "").lowercased()
        if type.hasPrefix("image/") { return "photo" }
        if type.hasPrefix("video/") { return "film" }
        if type.hasPrefix("audio/") { return "waveform" }
        if type.contains("pdf") { return "doc.richtext" }
        if type.contains("zip") || type.contains("compressed") { return "doc.zipper" }
        if type.hasPrefix("text/") { return "doc.text" }
        return "doc"
    }

    private func tap() {
        if progress != nil {
            // Cancels what's under way: an upload is taken back off the relay and the message goes.
            if let id = model.conversationID(of: message.id) { if uploading { model.cancelFile(message.id, in: id) } }
            return
        }
        if failure != nil, mine, let id = model.conversationID(of: message.id) { model.cancelFile(message.id, in: id); return }
        guard !expired, attachment.collected != true else { return }
        let erases = attachment.token != nil
        Task {
            if let data = try? await model.openFile(of: message) {
                opened = OpenedFile(name: attachment.shownName, type: attachment.type, data: data, erased: erases)
            }
        }
    }
}

/// A file held in memory while it is shown.
struct OpenedFile: Identifiable {
    let id = UUID()
    var name: String
    var type: String?
    var data: Data
    /// The relay has been told it's here and erases it once everyone has it: this is the only time it can be opened.
    var erased = false
}

/// What an opened file shows: a picture or text from memory, and, for anything else, what it is. "Save a copy" is the one
/// way a file reaches the disk, and only because the person asked.
private struct FileSheet: View {
    @Environment(\.dismiss) private var dismiss
    var file: OpenedFile
    @State private var saving = false

    private var image: PlatformImage? { (file.type ?? "").hasPrefix("image/") ? PlatformImage(data: file.data) : nil }
    private var text: String? {
        guard (file.type ?? "").hasPrefix("text/"), file.data.count <= 400_000 else { return nil }
        return String(data: file.data, encoding: .utf8)
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text(file.name).font(.system(size: 16, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Done") { dismiss() }
            }
            Group {
                if let image {
                    Image(platformImage: image).resizable().scaledToFit()
                } else if let text {
                    ScrollView { Text(text).font(.system(size: 13, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "doc").font(.system(size: 44)).foregroundStyle(Ink.dim)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(file.data.count), countStyle: .file))
                            .foregroundStyle(Ink.dim)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Text(file.erased
                 ? "Opened from memory only and erased from the server. Saving a copy makes an unencrypted file on this device."
                 : "Opened from memory only. Saving a copy puts an unencrypted file on this device.")
                .font(.system(size: 12)).foregroundStyle(Ink.dim).multilineTextAlignment(.center)
            Button("Save a copy…") { saving = true }
                .buttonStyle(.borderedProminent)
        }
        .padding(20)
        .frame(minWidth: 360, minHeight: 360)
        .background(Ink.base)
        .fileExporter(isPresented: $saving, document: RawFileDocument(data: file.data), contentType: .data, defaultFilename: file.name) { _ in }
    }
}

struct RawFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
