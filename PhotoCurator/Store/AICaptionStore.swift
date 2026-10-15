import Foundation

/// Caches AI-generated passport-stamp captions by place name, so the same
/// place isn't re-requested (and re-billed) on every app launch or
/// `WorldMapView` render. Plain `UserDefaults`, not the Keychain — these
/// are short, non-sensitive display strings, not a secret like the API
/// key itself.
enum AICaptionStore {
    private static let key = "app.photocurator.ai-stamp-captions"

    private static func load() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    static func caption(for place: String) -> String? {
        load()[place]
    }

    static func save(_ caption: String, for place: String) {
        var all = load()
        all[place] = caption
        UserDefaults.standard.set(all, forKey: key)
    }
}
