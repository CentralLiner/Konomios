import Foundation

final class AppSettings {
    static let shared = AppSettings()
    static let serverAddressKey = "KonomiTV.serverAddress.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var serverAddress: ServerAddress? {
        get {
            guard let stored = defaults.string(forKey: Self.serverAddressKey) else { return nil }
            return try? ServerAddress(input: stored)
        }
        set {
            if let newValue {
                defaults.set(newValue.url.absoluteString, forKey: Self.serverAddressKey)
            } else {
                defaults.removeObject(forKey: Self.serverAddressKey)
            }
        }
    }
}
