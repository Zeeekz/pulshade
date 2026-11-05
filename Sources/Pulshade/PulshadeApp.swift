import SwiftUI
#if os(macOS)
import AppKit
import ServiceManagement
#endif

@main
struct PulshadeApp: App {
    @State private var model: AppModel = {
        #if DEBUG
        if AppModel.demoRequested { return AppModel.demo() }
        #endif
        return AppModel()
    }()
    #if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(PushDelegate.self) private var pushDelegate
    #endif

    init() {
        #if os(macOS)
        NSApplication.shared.setActivationPolicy(.regular)
        #endif
        // Set early so taps on notifications are handled even right after launch.
        Notifier.shared.attach()
        #if os(iOS)
        AnnouncementWatch.register()
        #endif
    }

    var body: some Scene {
        #if os(macOS)
        WindowGroup(id: "main") {
            RootView()
                .environment(model)
                .environment(\.theme, model.theme)
                .tint(model.theme.accent)
                .preferredColorScheme(model.theme.scheme)
                .onChange(of: model.theme.scheme, initial: true) { _, scheme in
                    NSApplication.shared.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
                }
                .frame(minWidth: 980, minHeight: 640)
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
                .onOpenURL { model.open($0) }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.save()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("PULSHADE") {
                Button("Lock") { model.lock() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(model.phase != .unlocked)
            }
        }

        MenuBarExtra(isInserted: Binding(get: { model.showsMenuBarIcon }, set: { _ in })) {
            MenuBarContent()
                .environment(model)
        } label: {
            MenuBarLabel(unread: model.phase == .unlocked ? model.unreadTotal : 0)
        }
        #else
        WindowGroup {
            RootView()
                .environment(model)
                .environment(\.theme, model.theme)
                .tint(model.theme.accent)
                .preferredColorScheme(model.theme.scheme)
                // A code scanned with the Camera app. It waits here if Pulshade is locked.
                .onOpenURL { model.open($0) }
                .onReceive(NotificationCenter.default.publisher(for: .pulshadePushToken)) { _ in model.refreshPush() }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .background: model.didEnterBackground()
                    case .active: model.willEnterForeground()
                    default: break
                    }
                }
        }
        #endif
    }
}

#if os(macOS)
/// The pulse in the menu bar. A count appears beside it when something's unread.
private struct MenuBarLabel: View {
    var unread: Int

    var body: some View {
        Image(nsImage: Self.pulse)
        if unread > 0 { Text("\(unread)") }
    }

    /// The Pulshade heartbeat, drawn as a template so macOS tints it to match the menu bar.
    static let pulse: NSImage = {
        let image = NSImage(size: NSSize(width: 20, height: 16), flipped: true) { rect in
            let path = NSBezierPath()
            let points: [(CGFloat, CGFloat)] = [(0, 0.5), (0.3, 0.5), (0.42, 0.06), (0.58, 0.94), (0.7, 0.5), (1, 0.5)]
            for (i, p) in points.enumerated() {
                let pt = NSPoint(x: rect.minX + 1 + p.0 * (rect.width - 2), y: rect.minY + 1 + p.1 * (rect.height - 2))
                i == 0 ? path.move(to: pt) : path.line(to: pt)
            }
            path.lineWidth = 1.8
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }()
}

/// Starting Pulshade when you log in, so the menu bar icon is always there.
enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }

    @discardableResult
    static func set(_ on: Bool) -> Bool {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return true
        } catch {
            return false
        }
    }
}

private struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.phase == .unlocked {
            let unread = model.unreadConversations
            if unread.isEmpty {
                Text("No new messages")
            } else {
                // Names only appear if notifications are allowed to show them.
                let showNames = model.data.security.notificationContent != .hidden
                ForEach(Array(unread.prefix(8))) { c in
                    Button(showNames ? "\(c.title)  ·  \(c.unread)" : "New message  ·  \(c.unread)") { show(c.id) }
                }
            }
            Divider()
            Button("Open PULSHADE") { show(nil) }
            Button("Lock") { model.lock() }
        } else {
            Button("Open PULSHADE") { show(nil) }
        }
        Divider()
        Button("Quit PULSHADE") { NSApp.terminate(nil) }
    }

    private func show(_ id: Conversation.ID?) {
        if NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) == nil { openWindow(id: "main") }
        NSApp.activate(ignoringOtherApps: true)
        if let id { model.open(id) }
    }
}

#endif

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    @State private var active = true
    /// iPhone: the screen is being recorded, mirrored or shared.
    @State private var captured = false
    #if os(iOS)
    /// Bumped each time the app comes to the front, so the screenshot shield is put back together.
    @State private var shieldEpoch = 0
    #endif

    var body: some View {
        shielded
            #if os(macOS)
            .background(WindowConfigurator(blockCapture: model.blockCapture))
            #endif
            .overlay {
                // Privacy curtain: hides everything the moment Pulshade isn't the front app.
                if (!active && model.blurWhenInactive) || (captured && model.blockCapture) {
                    ZStack {
                        Rectangle().fill(.ultraThinMaterial)
                        Ink.void.opacity(0.55)
                        PulseMark(size: 120)
                    }
                    .ignoresSafeArea()
                    .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.25), value: active)
            #if os(macOS)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in active = false }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in active = true }
            .onAppear { model.openMainWindow = { openWindow(id: "main") } }
            #else
            // In the app switcher iOS shows a snapshot; covering the app first keeps chats out of it.
            .onChange(of: scenePhase, initial: true) { _, phase in
                active = phase == .active
                captured = Self.screenCaptured
                if phase == .active {
                    // Opening from a notification on a locked phone could leave the shielded layer black until the
                    // app switcher redrew it. Rebuild it now and again once the unlock animation is over.
                    shieldEpoch += 1
                    Task { try? await Task.sleep(for: .milliseconds(450)); shieldEpoch += 1 }
                }
            }
            // iOS can't keep a recording or a mirrored screen from showing the app, so it's covered instead.
            .onReceive(NotificationCenter.default.publisher(for: UIScreen.capturedDidChangeNotification)) { _ in
                captured = Self.screenCaptured
            }
            .simultaneousGesture(TapGesture().onEnded { model.noteActivity() })
            // Drag down on any list or chat to slide the keyboard away; tap outside a text box to close it.
            .scrollDismissesKeyboard(.interactively)
            .onAppear { KeyboardDismisser.shared.install() }
            #endif
    }

    /// iPhone: screenshots can't be stopped, so the app is drawn where they come out blank.
    @ViewBuilder private var shielded: some View {
        #if os(iOS)
        CaptureShield(on: model.blockCapture, epoch: shieldEpoch, content: AnyView(
            content.environment(model).environment(\.theme, model.theme).tint(model.theme.accent)
        ))
        .ignoresSafeArea()
        #else
        content
        #endif
    }

    #if os(iOS)
    private static var screenCaptured: Bool {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.isCaptured }.contains(true)
    }
    #endif

    private var content: some View {
        ZStack {
            if model.phase == .unlocked { Backdrop(intensity: 0.35 + 1.6 * model.theme.glow) } else { Aurora() }
            switch model.phase {
            case .welcome:
                WelcomeView().transition(.blurReplace)
            case .locked:
                UnlockView().transition(.blurReplace)
            case .unlocked:
                VStack(spacing: 0) {
                    if model.connecting || model.relayUnreachable {
                        ConnectionStrip().transition(.move(edge: .top).combined(with: .opacity))
                    }
                    MainView()
                }
                .transition(.blurReplace.combined(with: ScaleTransition(1.03)))
            }
        }
    }
}

#if os(iOS)
/// Draws its content inside the layer iOS keeps out of screenshots and recordings (the one behind a password
/// field), so they come out blank. iOS doesn't promise that layer; where it isn't found, content draws as usual.
private struct CaptureShield: UIViewControllerRepresentable {
    var on: Bool
    var epoch = 0
    var content: AnyView

    func makeUIViewController(context: Context) -> Controller { Controller(content) }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.hosting.rootView = content
        if controller.epoch != epoch {
            controller.epoch = epoch
            controller.reseat()
        }
        controller.shield(on)
    }

    final class Controller: UIViewController {
        let hosting: UIHostingController<AnyView>
        private let field = UITextField()
        private lazy var canvas: UIView? = {
            field.isSecureTextEntry = true
            let found = field.subviews.first { NSStringFromClass(type(of: $0)).contains("Canvas") } ?? field.subviews.first
            found?.subviews.forEach { $0.removeFromSuperview() }
            found?.isUserInteractionEnabled = true
            return found
        }()
        private var shielding: Bool?
        var epoch = 0

        init(_ content: AnyView) {
            hosting = UIHostingController(rootView: content)
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            hosting.view.backgroundColor = .clear
            addChild(hosting)
            shield(shielding ?? true)
            hosting.didMove(toParent: self)
        }

        /// Takes the content out of the shielded layer so the next `shield` puts it back and redraws it.
        func reseat() {
            guard isViewLoaded else { return }
            hosting.view.removeFromSuperview()
            canvas?.removeFromSuperview()
            shielding = nil
        }

        func shield(_ on: Bool) {
            guard isViewLoaded else { shielding = on; return }
            guard shielding != on || hosting.view.superview == nil else { return }
            shielding = on
            var host: UIView = view
            if on, let canvas {
                if canvas.superview !== view {
                    canvas.frame = view.bounds
                    canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                    view.addSubview(canvas)
                }
                host = canvas
            }
            guard hosting.view.superview !== host else { return }
            hosting.view.removeFromSuperview()
            hosting.view.frame = host.bounds
            hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            host.addSubview(hosting.view)
            host.setNeedsLayout()
            host.layoutIfNeeded()
        }
    }
}
#endif

#if os(macOS)
/// Applies window-level privacy: with capture blocked, screenshots and recordings show nothing.
private struct WindowConfigurator: NSViewRepresentable {
    var blockCapture: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            view.window?.sharingType = blockCapture ? .none : .readOnly
        }
    }
}
#endif
