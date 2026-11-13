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
    /// Under the `pulshade.` prefix like the other settings kept outside the vault, so a wipe removes it. Builds
    /// before this one stored it as `lockStyle`: it is read from there once and moved.
    static let key = "pulshade.lockStyle"
    static let legacyKey = "lockStyle"

    static var remembered: LockStyle {
        get {
            let defaults = UserDefaults.standard
            if let now = defaults.string(forKey: key) { return LockStyle(rawValue: now) ?? .passcode }
            guard let old = defaults.string(forKey: legacyKey) else { return .passcode }
            defaults.removeObject(forKey: legacyKey)
            if LockStyle(rawValue: old) != nil { defaults.set(old, forKey: key) }
            return LockStyle(rawValue: old) ?? .passcode
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            UserDefaults.standard.removeObject(forKey: legacyKey)
        }
    }

    /// What a new secret can be, for the real account as for a decoy or panic passcode: at least 6 long, so a 4-digit
    /// PIN is no longer offered. `.pin4` stays only so the lock screen can show the keypad someone set up earlier.
    static let forNewSecret: [LockStyle] = [.pin6, .passcode]
    static let forDisguise = forNewSecret

    /// The style to start from when choosing a new secret: the remembered one, except a 4-digit PIN becomes 6 digits.
    var forChoosing: LockStyle { self == .pin4 ? .pin6 : self }

    /// The shortest secret the real account takes, whatever the screen allowed.
    static let minimumLength = 6

    /// Whether the secret is a run of one digit or counting up or down by one ("111111", "123456", "987654").
    static func isPattern(_ secret: String) -> Bool {
        let digits = secret.compactMap(\.wholeNumberValue)
        guard digits.count == secret.count, digits.count >= 4 else { return false }
        let steps = Set(zip(digits, digits.dropFirst()).map { $1 - $0 })
        return steps == [0] || steps == [1] || steps == [-1]
    }

    /// Advice on a secret being chosen, nil when there's nothing to say.
    static func guidance(for secret: String, style: LockStyle) -> String? {
        guard !secret.isEmpty else { return nil }
        if isPattern(secret) { return "Easy to guess: pick digits that aren't a pattern." }
        if style.isPIN { return "6 digits is the least. A passcode with letters and 10 or more characters is far harder to guess." }
        return secret.count < 10 ? "Longer is stronger: 10 or more characters is best." : nil
    }
}

/// "Wipe after too many wrong attempts": off unless chosen. Kept outside the vault (it has to be known while locked), in
/// the settings Pulshade keeps for the lock screen, so Burn and Detach remove it. The count itself is `failedAttempts`,
/// which lives in the Keychain and so survives the app being closed. It counts every wrong guess against every slot the
/// same way, so it says nothing about whether a decoy or panic passcode exists, and a right one of any kind starts it again.
enum WipeAfterFailures {
    static let key = "pulshade.wipeAfterAttempts"
    /// Off, then how many wrong tries in a row.
    static let choices = [0, 5, 10, 20]

    static var limit: Int {
        get { UserDefaults.standard.integer(forKey: key) }
        set {
            if newValue <= 0 { UserDefaults.standard.removeObject(forKey: key) }
            else { UserDefaults.standard.set(newValue, forKey: key) }
        }
    }

    /// Whether this many wrong tries in a row is enough to wipe.
    static func reached(_ attempts: Int) -> Bool {
        let n = limit
        return n > 0 && attempts >= n
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
