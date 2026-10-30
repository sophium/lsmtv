import Foundation

/// Screenshot and UI-test hooks, inert unless the app is launched with
/// `-debugHooks 1`. Normal launches never read any of these keys.
enum DebugHooks {
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "debugHooks")
    }

    static func string(_ key: String) -> String? {
        isEnabled ? UserDefaults.standard.string(forKey: key) : nil
    }

    static func bool(_ key: String) -> Bool {
        isEnabled && UserDefaults.standard.bool(forKey: key)
    }

    private static var consumed: Set<String> = []

    /// Launch-time hooks return true at most once per process, so re-entering
    /// a tab cannot replay them.
    static func consume(_ key: String) -> Bool {
        guard isEnabled, !consumed.contains(key),
              UserDefaults.standard.bool(forKey: key) else { return false }
        consumed.insert(key)
        return true
    }

    static func consumeString(_ key: String) -> String? {
        guard isEnabled, !consumed.contains(key),
              let value = UserDefaults.standard.string(forKey: key) else { return nil }
        consumed.insert(key)
        return value
    }
}
