import Foundation

final class AppSettings {
    static let shared = AppSettings()
    static let serverAddressKey = "KonomiTV.serverAddress.v1"
    static let connectionHistoryKey = "KonomiTV.connectionHistory.v1"

    struct ConnectionHistoryEntry: Equatable {
        let address: ServerAddress
        let lastConnectedAt: Date
        let isPinned: Bool
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Migrate the previously saved endpoint once. An explicitly emptied history stays empty.
        if defaults.object(forKey: Self.connectionHistoryKey) == nil {
            let migrated = serverAddress.map {
                ConnectionHistoryEntry(address: $0, lastConnectedAt: .distantPast, isPinned: false)
            }
            writeHistory(migrated.map { [$0] } ?? [])
        }
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

    /// Pinned endpoints come first; each section shows the most recently connected endpoint first.
    var connectionHistory: [ConnectionHistoryEntry] {
        var unique: [ServerAddress: ConnectionHistoryEntry] = [:]
        for value in defaults.array(forKey: Self.connectionHistoryKey) ?? [] {
            guard let record = value as? [String: Any],
                  let rawAddress = record["address"] as? String,
                  let address = try? ServerAddress(input: rawAddress),
                  let date = record["lastConnectedAt"] as? Date,
                  date.timeIntervalSinceReferenceDate.isFinite,
                  let pinned = record["isPinned"] as? Bool else { continue }
            let previous = unique[address]
            unique[address] = ConnectionHistoryEntry(
                address: address,
                lastConnectedAt: max(date, previous?.lastConnectedAt ?? date),
                isPinned: pinned || (previous?.isPinned ?? false)
            )
        }
        return unique.values.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            if lhs.lastConnectedAt != rhs.lastConnectedAt { return lhs.lastConnectedAt > rhs.lastConnectedAt }
            return lhs.address.url.absoluteString < rhs.address.url.absoluteString
        }
    }

    /// Called after a successful web navigation, never when a URL is merely entered.
    func recordConnection(_ address: ServerAddress, at date: Date = Date()) {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return }
        var history = connectionHistory
        let previous = history.first { $0.address == address }
        history.removeAll { $0.address == address }
        history.append(ConnectionHistoryEntry(address: address, lastConnectedAt: date, isPinned: previous?.isPinned ?? false))
        writeHistory(history)
    }

    func setConnectionPinned(_ address: ServerAddress, isPinned: Bool) {
        let history = connectionHistory.map { entry in
            entry.address == address
                ? ConnectionHistoryEntry(address: entry.address, lastConnectedAt: entry.lastConnectedAt, isPinned: isPinned)
                : entry
        }
        writeHistory(history)
    }

    /// Removes only the history entry. It does not disconnect the current server or delete login data.
    func deleteConnection(_ address: ServerAddress) {
        writeHistory(connectionHistory.filter { $0.address != address })
    }

    private func writeHistory(_ history: [ConnectionHistoryEntry]) {
        let records: [[String: Any]] = history.map { entry in
            ["address": entry.address.url.absoluteString,
             "lastConnectedAt": entry.lastConnectedAt,
             "isPinned": entry.isPinned]
        }
        defaults.set(records, forKey: Self.connectionHistoryKey)
    }
}
