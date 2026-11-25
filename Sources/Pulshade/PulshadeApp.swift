import SwiftUI

// Pulshade is an iPhone app. The Swift package also builds the code on macOS, but only so `swift test` can run.
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
        // Whatever a crash or a quit left of a clip is overwritten and deleted before anything else.
        TempFiles.sweep()
        // Set early so taps on notifications are handled even right after launch.
        Notifier.shared.attach()
        #if os(iOS)
        AnnouncementWatch.register()
        BackgroundUpload.register()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(\.theme, model.theme)
                .tint(model.theme.accent)
                .preferredColorScheme(model.theme.scheme)
                // A code scanned with the Camera app. It waits here if Pulshade is locked.
                .onOpenURL { model.open($0) }
                // Pulshade's own web links tapped inside Pulshade (in a chat, say) open here, not in the browser.
                .environment(\.openURL, OpenURLAction { url in
                    guard WebLinks.parse(url) != nil else { return .systemAction }
                    model.open(url)
                    return .handled
                })
                #if os(iOS)
                .onReceive(NotificationCenter.default.publisher(for: .pulshadePushToken)) { _ in model.refreshPush() }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .background: model.didEnterBackground()
                    case .active: model.willEnterForeground()
                    default: break
                    }
                }
                #endif
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
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
            .overlay {
                // Detach is saying its goodbyes: nothing of the account shows while it does.
                if model.detaching {
                    ZStack {
                        Ink.void.ignoresSafeArea()
                        VStack(spacing: 14) {
                            ProgressView().tint(.white)
                            Text("Detaching…").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.8))
                        }
                    }
                    .accessibilityAddTraits(.isModal)
                }
            }
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
            #if os(iOS)
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
            if model.isOpen { Backdrop() } else { Aurora() }
            switch model.phase {
            case .welcome:
                WelcomeView().transition(.blurReplace)
            case .locked:
                UnlockView().transition(.blurReplace)
            case .unlocked:
                if model.covered {
                    // Still running underneath, so messages arrive and receipts go out; only the passcode shows.
                    UnlockView().transition(.blurReplace)
                } else {
                    VStack(spacing: 0) {
                        if model.connecting || model.relayUnreachable {
                            ConnectionStrip().transition(.move(edge: .top).combined(with: .opacity))
                        }
                        MainView()
                    }
                    // A 4-digit PIN from an older build is changed before anything else.
                    .sheet(isPresented: Binding(get: { model.isOpen && model.hasShortPIN }, set: { _ in })) {
                        ChangePasscodeSheet(style: .pin6, required: true)
                            .environment(model)
                            .interactiveDismissDisabled()
                    }
                    .transition(.blurReplace.combined(with: ScaleTransition(1.03)))
                }
            }
        }
        .overlay(alignment: .top) { BurnBanner() }
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
            // Not while something is open over the app (the story editor, the photo picker): taking the content out
            // of the window and back closes it. Coming back from the photo picker bumped the epoch, and the story
            // editor vanished a moment after it opened.
            if !controller.hasModalOpen { controller.reseat() }
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

        /// Whether a full-screen cover, sheet or system picker is up over the content.
        var hasModalOpen: Bool {
            hosting.presentedViewController != nil || presentedViewController != nil
                || view.window?.rootViewController?.presentedViewController != nil
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
