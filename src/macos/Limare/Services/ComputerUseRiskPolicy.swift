import Foundation

/// Apps computer_use never operates: password managers, Keychain, System Settings and the
/// system's security prompts. The model asks the user to do those steps.
public enum ComputerUseRiskPolicy {
    public static let credentialSecurityBundleIDs: Set<String> = [
        "com.apple.keychainaccess",
        "com.apple.systempreferences",
        "com.apple.preferences",
        "com.apple.pass-viewer",
        "com.apple.passwords",
        "com.apple.securityassistant",
        "com.apple.securityagent",
        "com.apple.coreauthui",
        "com.1password.1password",
        "com.bitwarden.desktop",
        "com.dashlane.dashlane",
        "com.keepassxc.keepassxc"
    ]
}
