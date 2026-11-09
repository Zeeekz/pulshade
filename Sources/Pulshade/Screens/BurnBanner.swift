import SwiftUI

/// What a Burn says when it is done, or still finishing on the server: over every screen, because the account is already gone
/// by then. A finished message goes by itself after a few seconds.
struct BurnBanner: View {
    @Environment(AppModel.self) private var model

    private var text: String? {
        if model.burnPending { return "Burned on this phone. Finishing the erase on the server." }
        return model.burnNotice
    }

    var body: some View {
        if let text {
            HStack(spacing: 10) {
                Image(systemName: model.burnPending ? "flame" : "checkmark.circle.fill").font(.system(size: 16, weight: .semibold))
                Text(text).font(.system(size: 14, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if !model.burnPending {
                    Button { model.burnNotice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
            }
            .foregroundStyle(Ink.text)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Ink.line))
            .padding(.horizontal, 16).padding(.top, 10)
            .frame(maxWidth: 520)
            .transition(.move(edge: .top).combined(with: .opacity))
            .task(id: model.burnNotice) {
                guard !model.burnPending, model.burnNotice != nil else { return }
                try? await Task.sleep(for: .seconds(12))
                withAnimation(.snappy) { model.burnNotice = nil }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
        }
    }
}
