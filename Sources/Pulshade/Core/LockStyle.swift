import Foundation

/// What kind of secret locks PULSHADE. The vault only ever sees a string, so a PIN is a passcode made of
/// digits: choosing one changes what the person types, not how anything is sealed. Wrong guesses are slowed
/// the same way for all of them.
enum LockStyle: String, CaseIterable, Identifiable {
    case pin6, pin4, passcode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pin6: "6-digit PIN"
        case .pin4: "4-digit PIN"
        case .passcode: "Passcode"
        }
    }

    var short: String {
        switch self {
        case .pin6: "6 digits"
        case .pin4: "4 digits"
        case .passcode: "Passcode"
        }
    }

    var isPIN: Bool { self != .passcode }

    /// Exact length of a PIN; nil for a passcode.
    var length: Int? {
        switch self {
        case .pin6: 6
        case .pin4: 4
        case .passcode: nil
        }
    }

    /// The word for the secret in screens: "PIN" or "passcode".
    var noun: String { isPIN ? "PIN" : "passcode" }

    /// Whether this is an acceptable new secret.
    func accepts(_ secret: String) -> Bool {
        if let length { return secret.count == length && secret.allSatisfy(\.isASCIIDigit) }
        return secret.count >= 6
    }

    /// What to tell the person when `accepts` said no.
    func problem(for secret: String) -> String {
        if let length { return "Enter exactly \(length) digits" }
        return secret.count < 6 ? "Use at least 6 characters" : "The passcodes don't match"
    }

    /// Digits only, and no longer than a PIN can be.
    func filtered(_ typed: String) -> String {
        guard let length else { return typed }
        return String(typed.filter(\.isASCIIDigit).prefix(length))
    }

    // MARK: Remembered choice

    /// Which style the unlock screen should offer first. This is only a hint about the keyboard to show:
    /// every secret is tried against every slot whatever it looks like, so it opens nothing by itself.
    private static let key = "lockStyle"

    static var remembered: LockStyle {
        get { UserDefaults.standard.string(forKey: key).flatMap(LockStyle.init(rawValue:)) ?? .passcode }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    /// Decoy and panic secrets must stay at least 6 long, so a 4-digit PIN isn't offered for them.
    static let forDisguise: [LockStyle] = [.pin6, .passcode]
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
