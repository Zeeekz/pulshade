import SwiftUI

/// Who's being reported. Without one, the form asks for their @handle.
struct ReportSubject: Identifiable {
    var id: Data { key }
    var key: Data
    var handle: String?
    var name: String
}

/// Reporting someone to the Pulshade team. The report is end-to-end encrypted to the team, so the relay can't
/// read it, and the reply is instant, like a support bot's.
struct ReportSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    var subject: ReportSubject?

    @State private var handle = ""
    @State private var reason: String?
    @State private var details = ""
    @State private var sending = false
    @State private var problem: String?
    @State private var sent = false
    @State private var includeHandle = false

    static let reasons = ["Spam or scams", "Harassment or threats", "Pretending to be someone else",
                          "Illegal or harmful content", "Something else"]

    var body: some View {
        SheetBody(width: 460) {
            VStack(alignment: .leading, spacing: 18) {
                SheetHeader(symbol: "flag.fill", title: sent ? "Report sent" : "Report")
                if sent { confirmation } else { form }
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let subject {
                HStack(spacing: 12) {
                    Avatar(image: nil, seed: Identity.fingerprint(of: subject.key), size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(subject.name.isEmpty ? "Anonymous" : subject.name).font(.system(size: 15, weight: .medium)).foregroundStyle(Ink.text)
                        if let h = subject.handle { Text("@\(h)").font(.system(size: 13)).foregroundStyle(Ink.dim) }
                    }
                }
            } else {
                Text("Who are you reporting?").font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.dim)
                TextField("", text: $handle, prompt: Text("@handle").foregroundStyle(Ink.faint))
                    .textFieldStyle(LargeFieldStyle())
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
            }
            Text("What's wrong?").font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.dim)
            VStack(spacing: 0) {
                ForEach(Array(Self.reasons.enumerated()), id: \.offset) { i, r in
                    if i > 0 { RowDivider() }
                    Button { withAnimation(.snappy) { reason = r } } label: {
                        HStack {
                            Text(r).font(.system(size: 15)).foregroundStyle(Ink.text)
                            Spacer()
                            if reason == r { Image(systemName: "checkmark").font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.accent) }
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 46)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Ink.surface, in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.line))
            TextField("", text: $details, prompt: Text("Anything that would help (optional)").foregroundStyle(Ink.faint), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(Ink.text)
                .lineLimit(3...6)
                .padding(14)
                .background(Ink.raised, in: .rect(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.line))
            if let mine = model.activeProfile.handle {
                HStack(spacing: 12) {
                    Text("Say it's from @\(mine)").font(.system(size: 14)).foregroundStyle(Ink.text)
                        .lineLimit(1).minimumScaleFactor(0.85)
                    Spacer(minLength: 8)
                    Toggle("Say it's from @\(mine)", isOn: $includeHandle).toggleStyle(GlowToggleStyle())
                }
            }
            Text(branded: "Only the PULSHADE team can read this. It's sent from a throwaway identity, so it doesn't say who you are unless you add your handle. The person you report is never told.")
                .font(.system(size: 12)).foregroundStyle(Ink.faint)
                .fixedSize(horizontal: false, vertical: true)
            if let problem {
                ProblemText(problem)
            }
            Button(action: send) { WorkingLabel(title: "Send report", working: sending) }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(sending || reason == nil || (subject == nil && DirectoryProfile.validHandle(handle) == nil))
        }
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                PulseMark(size: 34)
                VStack(alignment: .leading, spacing: 6) {
                    Text(branded: "PULSHADE Safety").font(.system(size: 14, weight: .semibold)).foregroundStyle(Ink.text)
                    Text(branded: "Thanks, we've got your report. A person on the PULSHADE team reviews every one, and we can remove handles and ban accounts that break the rules.")
                        .font(.system(size: 14)).foregroundStyle(Ink.dim)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("If you don't want to hear from them again, block them too.")
                        .font(.system(size: 14)).foregroundStyle(Ink.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(Ink.raised, in: .rect(cornerRadius: 12))
            }
            Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle())
        }
    }

    private func send() {
        guard let reason else { return }
        sending = true
        problem = nil
        Task {
            do {
                var target = subject
                if target == nil {
                    guard let found = try await model.findProfile(handle) else {
                        problem = "No one has that handle"
                        sending = false
                        return
                    }
                    target = ReportSubject(key: found.signingKey, handle: found.handle, name: found.name)
                }
                guard let target else { return }
                try await model.report(subjectKey: target.key, handle: target.handle, name: target.name,
                                       reason: reason, details: details, includeHandle: includeHandle)
                withAnimation(.snappy) { sent = true }
            } catch AppModel.ReportError.notSetUp {
                problem = "Reports aren't set up on this relay yet."
            } catch {
                problem = "Can't reach the relay. Try again in a moment."
            }
            sending = false
        }
    }
}
