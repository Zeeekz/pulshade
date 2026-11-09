#if os(iOS)
import AVFoundation
import CallKit
import PushKit
import UIKit

/// Makes the iPhone ring for a call, the way a phone call does: the system's own call screen, a ringtone that loops,
/// and answer and decline buttons on the lock screen.
///
/// The relay sends a call push (PushKit) when a call's first envelope lands in one of this phone's mailboxes. Apple
/// wakes Pulshade for it and Pulshade has to put up the call screen straight away. The push says nothing about who is
/// calling (the relay can't know), so the screen first says "PULSHADE, incoming call"; the caller's name is filled in
/// when the call's envelope has been fetched and opened. Pulshade's own lock still applies: if it is locked, the call
/// can be answered on the call screen but only connects once Pulshade has been opened and unlocked.
///
/// The call history isn't kept: the system's Phone app never learns who called.
@MainActor
final class CallRinger: NSObject {
    static let shared = CallRinger()

    /// This phone's call token, as hex, once Apple has issued it. It goes to the relay and nowhere else.
    nonisolated(unsafe) static var voipToken: String?
    /// The call on the system's screen was answered there, so the system owns the audio session until it ends.
    nonisolated(unsafe) static var answeredOnScreen = false

    weak var model: AppModel?

    private var registry: PKPushRegistry?
    private lazy var provider: CXProvider = {
        let config = CXProviderConfiguration()
        config.supportsVideo = false
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        // Keeps who called out of the Phone app's recent calls.
        config.includesCallsInRecents = false
        let provider = CXProvider(configuration: config)
        provider.setDelegate(self, queue: .main)
        return provider
    }()

    /// The call on the system's screen.
    private var uuid: UUID?
    /// The call's id once its envelope has arrived and been matched to the screen.
    private var invite: UUID?
    /// Answered on the call screen before the call's envelope arrived: it is taken as soon as it does.
    private var answeredEarly = false
    private var waiting: Task<Void, Never>?
    /// Declined on the call screen before the call's envelope arrived: it is declined as soon as it does, for a minute.
    private var declinedUntil: Date?

    /// Whether a call that has just arrived was already declined on the system's screen.
    func consumeEarlyDecline() -> Bool {
        defer { declinedUntil = nil }
        return declinedUntil.map { $0 > Date() } ?? false
    }

    /// Registers for call pushes. Early at launch: a call push that wakes a closed app has to find this ready.
    func start() {
        guard registry == nil else { return }
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.registry = registry
        _ = provider
    }

    // MARK: From the app

    /// A call's envelope has been opened. If the system's screen is up for it, it learns the name.
    /// Returns whether the screen took the call, which means no banner is needed.
    @discardableResult
    func inviteArrived(id: UUID, name: String) -> Bool {
        guard let uuid, invite == nil else { return false }
        invite = id
        waiting?.cancel()
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: name)
        update.localizedCallerName = name
        update.hasVideo = false
        provider.reportCall(with: uuid, updated: update)
        if answeredEarly {
            answeredEarly = false
            model?.answerCall()
        }
        return true
    }

    /// The call was picked up in Pulshade's own window while the system's screen was up: that screen goes.
    func answeredInApp() {
        guard let uuid, !Self.answeredOnScreen else { return }
        provider.reportCall(with: uuid, endedAt: Date(), reason: .answeredElsewhere)
        clear()
    }

    /// The call ended (hung up, declined, missed, or the other side left). The system's screen goes with it.
    func callEnded(missed: Bool) {
        guard let uuid else { return }
        provider.reportCall(with: uuid, endedAt: Date(), reason: missed ? .unanswered : .remoteEnded)
        clear()
    }

    private func clear() {
        waiting?.cancel()
        uuid = nil
        invite = nil
        answeredEarly = false
        Self.answeredOnScreen = false
    }

    // MARK: A call push

    fileprivate func incomingPush(then done: @escaping () -> Void) {
        let id = UUID()
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: "PULSHADE")
        update.localizedCallerName = "PULSHADE"
        update.hasVideo = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        let busy = uuid != nil
        if !busy { uuid = id }
        provider.reportNewIncomingCall(with: id, update: update) { [weak self] error in
            MainActor.assumeIsolated {
                guard let self else { done(); return }
                if busy {
                    // Apple wants every call push answered with a call screen. A second one while one is up is
                    // shown for an instant and ended.
                    self.provider.reportCall(with: id, endedAt: Date(), reason: .unanswered)
                } else if error != nil {
                    // Do Not Disturb or a Focus kept the call quiet: Pulshade still gets the call as a banner.
                    self.uuid = nil
                } else {
                    self.watchForInvite(id)
                }
                done()
            }
        }
        model?.callPushArrived()
    }

    /// If the call's envelope never comes (the caller hung up, or it can't be reached), the screen doesn't ring on.
    private func watchForInvite(_ id: UUID) {
        waiting?.cancel()
        waiting = Task { [weak self] in
            // Rings as long as the caller does. A call that was answered gets longer still: Pulshade may have to be
            // unlocked and reach the relay before the call's envelope can be fetched.
            try? await Task.sleep(for: .seconds(90))
            guard !Task.isCancelled, let self, self.uuid == id, self.invite == nil else { return }
            if self.answeredEarly {
                try? await Task.sleep(for: .seconds(90))
                guard !Task.isCancelled, self.uuid == id, self.invite == nil else { return }
            }
            self.provider.reportCall(with: id, endedAt: Date(), reason: .unanswered)
            self.clear()
        }
    }
}

// MARK: - The call push

extension CallRinger: PKPushRegistryDelegate {
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        Self.voipToken = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        NotificationCenter.default.post(name: .pulshadePushToken, object: nil)
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        Self.voipToken = nil
        NotificationCenter.default.post(name: .pulshadePushToken, object: nil)
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
                                  for type: PKPushType, completion: @escaping () -> Void) {
        guard type == .voIP else { completion(); return }
        MainActor.assumeIsolated { CallRinger.shared.incomingPush(then: completion) }
    }
}

// MARK: - The call screen

extension CallRinger: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        MainActor.assumeIsolated {
            let ringing = CallRinger.shared.uuid != nil
            CallRinger.shared.clear()
            if ringing { CallRinger.shared.model?.hangUp() }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        MainActor.assumeIsolated {
            let ringer = CallRinger.shared
            Self.answeredOnScreen = true
            if ringer.invite != nil {
                ringer.model?.answerCall()
            } else {
                ringer.answeredEarly = true
            }
            // Locked, Pulshade can't open the call's envelope: it asks to be opened.
            if ringer.model?.phase != .unlocked {
                Notifier.shared.post(("PULSHADE", "Open PULSHADE to connect your call"), conversation: UUID(), sound: false)
            }
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        MainActor.assumeIsolated {
            let ringer = CallRinger.shared
            let known = ringer.invite != nil
            ringer.clear()
            // Declined or hung up on the call screen: the same as doing it in Pulshade. Before the call's envelope has
            // come, it is remembered and declined when it does.
            if known { ringer.model?.hangUp() } else { ringer.declinedUntil = Date().addingTimeInterval(60) }
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        MainActor.assumeIsolated {
            if let model = CallRinger.shared.model, model.call?.muted != action.isMuted { model.toggleMute() }
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {}

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {}
}
#endif
