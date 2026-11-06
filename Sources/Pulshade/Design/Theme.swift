import SwiftUI

/// One of the complete looks: every surface, text colour and accent comes from here.
struct Theme: Identifiable, Equatable {
    let id: String
    let name: String
    let scheme: ColorScheme
    let colors: [Color]
    let ink: Palette
    /// How strongly the drifting glow behind the app shows through. Zero keeps the background flat.
    var glow: Double = 0

    var accent: Color { colors[0] }
    /// A restrained two-tone version of the accent, for primary buttons and your own bubbles.
    var gradient: LinearGradient {
        LinearGradient(colors: [colors[0], colors[0].mix(with: colors[1], by: 0.35)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    /// The full palette, kept for the logo and onboarding artwork.
    var vivid: LinearGradient {
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    var angular: AngularGradient {
        AngularGradient(colors: colors + [colors[0]], center: .center)
    }
    /// Accent tinted for backgrounds of selected things.
    var wash: Color { colors[0].opacity(scheme == .light ? 0.12 : 0.14) }

    static let light = Theme(id: "light", name: "Light", scheme: .light,
                             colors: [.hex(0x3D6BFF), .hex(0x6A4CFF), .hex(0x1FA8E8)],
                             ink: Palette(void: .hex(0xEDEDF1), base: .hex(0xF7F7F9), surface: .hex(0xFFFFFF),
                                          raised: .hex(0xF0F0F4), hover: .hex(0xE6E6EC), line: .black.opacity(0.08),
                                          text: .black.opacity(0.88), dim: .black.opacity(0.56), faint: .black.opacity(0.38),
                                          onAccent: .white))
    static let dark = Theme(id: "dark", name: "Dark", scheme: .dark,
                            colors: [.hex(0x4FD8BC), .hex(0x6E63F2), .hex(0xA35BE6)],
                            ink: Palette(void: .hex(0x08080A), base: .hex(0x0D0D10), surface: .hex(0x141417),
                                         raised: .hex(0x1C1C20), hover: .hex(0x232328), line: .white.opacity(0.065),
                                         text: .white.opacity(0.93), dim: .white.opacity(0.58), faint: .white.opacity(0.34),
                                         onAccent: .black))
    /// Deep midnight violet with a slow glow moving behind glass-like panels, and a violet-to-rose accent.
    static let pulse = Theme(id: "pulse", name: "Pulse", scheme: .dark,
                             colors: [.hex(0x9D7BFF), .hex(0xF06BC4), .hex(0x5FD3E8)],
                             ink: Palette(void: .hex(0x070515), base: .hex(0x0A0818).opacity(0.58), surface: .hex(0x17132E).opacity(0.74),
                                          raised: .hex(0x221D40).opacity(0.85), hover: .hex(0x2D2654), line: .hex(0xCBB8FF).opacity(0.11),
                                          text: .hex(0xF4F0FF).opacity(0.95), dim: .hex(0xD9CFFF).opacity(0.62),
                                          faint: .hex(0xC9BCF5).opacity(0.38), onAccent: .white),
                             glow: 1)

    /// A warm, paper-like light theme: cream surfaces with a terracotta accent.
    static let sand = Theme(id: "sand", name: "Sand", scheme: .light,
                            colors: [.hex(0xC4552F), .hex(0xE08A3C), .hex(0x8A5A44)],
                            ink: Palette(void: .hex(0xEAE3D6), base: .hex(0xF6F1E7), surface: .hex(0xFCF9F3),
                                         raised: .hex(0xEFE8DA), hover: .hex(0xE4DCCB), line: .hex(0x4A3A22).opacity(0.12),
                                         text: .hex(0x2A2118).opacity(0.92), dim: .hex(0x2A2118).opacity(0.6),
                                         faint: .hex(0x2A2118).opacity(0.4), onAccent: .white))
    /// A flat deep-navy dark theme with a clear blue accent.
    static let midnight = Theme(id: "midnight", name: "Midnight", scheme: .dark,
                                colors: [.hex(0x6FA8FF), .hex(0x4E6BFF), .hex(0x4FC3F7)],
                                ink: Palette(void: .hex(0x050A14), base: .hex(0x0A101C), surface: .hex(0x111A2B),
                                             raised: .hex(0x182339), hover: .hex(0x1F2C47), line: .hex(0x9DB8FF).opacity(0.09),
                                             text: .hex(0xF0F4FF).opacity(0.93), dim: .hex(0xDCE5FF).opacity(0.58),
                                             faint: .hex(0xC6D3F5).opacity(0.36), onAccent: .hex(0x06101F)))

    static let all: [Theme] = [light, sand, dark, midnight, pulse]

    /// Ids from before there were three themes were all dark, so they open as Dark.
    static func named(_ id: String) -> Theme { all.first { $0.id == id } ?? dark }
}

/// The colours of one theme's surfaces and text.
struct Palette: Equatable {
    var void, base, surface, raised, hover, line, text, dim, faint: Color
    /// Text and icons drawn on the accent.
    var onAccent: Color
}

/// Signature colours people pick for themselves. Bright enough to glow on the dark background.
enum Signature {
    static let colors: [Color] = [
        .hex(0x2EF2C8), .hex(0x5C9DFF), .hex(0x8B5CFF), .hex(0xD45CFF), .hex(0xFF5FA2),
        .hex(0xFF6B4A), .hex(0xFFB547), .hex(0xC6F24A), .hex(0x4AE36B), .hex(0xE6E8F0),
    ]

    static func color(_ index: Int?, seed: String) -> Color {
        colors[(index ?? abs(seed.stableHash)) % colors.count]
    }
}

/// The current theme's surfaces and text. Reading these inside a view's body ties the view to the theme,
/// so it redraws when the theme changes.
enum Ink {
    /// Where the current theme comes from: the app model, once it exists.
    nonisolated(unsafe) static var source: () -> Theme = { .dark }
    private static var palette: Palette { source().ink }

    static var void: Color { palette.void }
    static var base: Color { palette.base }
    static var surface: Color { palette.surface }
    static var raised: Color { palette.raised }
    static var hover: Color { palette.hover }
    static var line: Color { palette.line }
    static var text: Color { palette.text }
    static var dim: Color { palette.dim }
    static var faint: Color { palette.faint }
    static var onAccent: Color { palette.onAccent }
    static var scheme: ColorScheme { source().scheme }
    /// The heartbeat cut through the logo, dark in every theme like the app icon.
    static let mark = Color.hex(0x08080A)
}

/// Section title used at the top of each area.
struct Heading: View {
    var title: String
    var body: some View {
        Text(title)
            .font(.system(size: 20, weight: .bold))
            .foregroundStyle(Ink.text)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension Color {
    static func hex(_ value: UInt32) -> Color {
        Color(red: Double((value >> 16) & 0xFF) / 255,
              green: Double((value >> 8) & 0xFF) / 255,
              blue: Double(value & 0xFF) / 255)
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.dark
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

// MARK: - Reusable styling

/// A quiet card: solid surface with a hairline edge.
struct Glass: ViewModifier {
    var radius: CGFloat = 12
    func body(content: Content) -> some View {
        content
            .background(Ink.surface.opacity(0.92), in: .rect(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Ink.line))
    }
}

extension View {
    func glass(_ radius: CGFloat = 12) -> some View { modifier(Glass(radius: min(radius, 14))) }
}

/// The primary action: accent fill, dark glyph, a soft lift.
struct GlowButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled
    var size: CGFloat = 44

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.36, weight: .semibold))
            .foregroundStyle(Ink.onAccent.opacity(0.85))
            .frame(minWidth: size, minHeight: size)
            .padding(.horizontal, 2)
            .background(theme.gradient, in: .rect(cornerRadius: size * 0.32))
            .shadow(color: theme.accent.opacity(configuration.isPressed ? 0.1 : 0.22), radius: 8, y: 2)
            .opacity(enabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

/// A full-width call to action: the main thing to do on a screen.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Ink.onAccent.opacity(0.9))
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(theme.accent, in: .rect(cornerRadius: 12))
            .opacity(enabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
            .contentShape(.rect)
    }
}

/// A full-width alternative to the primary button.
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Ink.text)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(configuration.isPressed ? Ink.hover : Ink.raised, in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.line))
            .opacity(enabled ? 1 : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
            .contentShape(.rect)
    }
}

/// A quiet square-ish icon button.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 34
    var active = false
    @Environment(\.theme) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(active ? AnyShapeStyle(theme.accent) : AnyShapeStyle(Ink.dim))
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.3)
                .fill(active ? AnyShapeStyle(theme.wash) : AnyShapeStyle(configuration.isPressed ? Ink.hover : Ink.raised)))
            .overlay(RoundedRectangle(cornerRadius: size * 0.3).strokeBorder(Ink.line))
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: size * 0.3))
    }
}

/// A round icon button for the top bar. `prominent` fills it with the accent, for the main action.
struct BarButtonStyle: ButtonStyle {
    var prominent = false
    /// Colours the glyph, such as the burn gradient; plain buttons use the dim ink.
    var tint: AnyShapeStyle?
    var size: CGFloat = 38
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.43, weight: .semibold))
            .foregroundStyle(prominent ? AnyShapeStyle(Color.black.opacity(0.82)) : (tint ?? AnyShapeStyle(Ink.dim)))
            .frame(width: size, height: size)
            .background {
                Circle().fill(prominent ? AnyShapeStyle(theme.accent) : AnyShapeStyle(configuration.isPressed ? Ink.hover : Ink.raised))
            }
            .overlay { if !prominent { Circle().strokeBorder(Ink.line) } }
            .shadow(color: prominent ? theme.accent.opacity(0.35) : .clear, radius: 8, y: 2)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .opacity(enabled ? 1 : 0.4)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
            .contentShape(Circle())
    }
}

struct PulseFieldStyle: TextFieldStyle {
    @Environment(\.theme) private var theme
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .foregroundStyle(Ink.text)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(Ink.raised, in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Ink.line))
    }
}
