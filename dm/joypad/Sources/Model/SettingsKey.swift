/// UserDefaults keys of the settings (read with @AppStorage in the views).
enum SettingsKey {
    static let mode = "mode"
    static let theme = "theme"
    static let deadzone = "deadzone"
    static let floatingSticks = "floatingSticks"
    static let pressHaptics = "pressHaptics"
    static let motion = "motion"
    static let rumble = "rumble"
    static let rumbleStrength = "rumbleStrength"
    static let lastAddress = "lastAddress"
    static let controlScale = "controlScale"
    /// Join the open games of the paired Macs by themselves (on by default).
    static let autoJoin = "autoJoin"
}
