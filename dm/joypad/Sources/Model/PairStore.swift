import Foundation
import Observation
import Security

/// The Macs this phone is paired with (README.md, "Pairing"), and the games it has seen on each. A Mac is known by the ID
/// its games advertise (TXT `mac`); its key lives in the Keychain, the rest in UserDefaults.
@MainActor
@Observable
final class PairStore {
    struct Game: Codable, Hashable, Identifiable {
        /// The title ID, or the name for a game that advertises none.
        var id: String
        var title: String
        var lastSeen: Date
        /// How the phone was last held for it ("pair", "left", "right").
        var mode: String?
    }

    struct Mac: Codable, Hashable, Identifiable {
        var id: UInt64
        var name: String
        var paired: Date
        var games: [Game] = []
    }

    private(set) var macs: [Mac] = []

    /// A random number kept across launches: the phone's ID to every Mac (its pairing, and its player when it comes back).
    nonisolated static let clientID: UInt64 = {
        let key = "clientID"
        let defaults = UserDefaults.standard
        if let text = defaults.string(forKey: key), let value = UInt64(text, radix: 16), value != 0 { return value }
        let value = UInt64.random(in: 1...UInt64.max)
        defaults.set(String(value, radix: 16), forKey: key)
        return value
    }()

    private static let defaultsKey = "pairedMacs"
    private static let keychainService = "io.github.nxnative.pad.pairing"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let list = try? JSONDecoder().decode([Mac].self, from: data) {
            // A Mac whose key went missing (a restored backup without the Keychain) has to pair again.
            macs = list.filter { Self.loadKey($0.id) != nil }
        }
    }

    func mac(_ id: UInt64) -> Mac? { macs.first { $0.id == id } }

    func key(for id: UInt64) -> Data? {
        guard mac(id) != nil else { return nil }
        return Self.loadKey(id)
    }

    func add(id: UInt64, name: String, key: Data) {
        Self.saveKey(id, key)
        if let i = macs.firstIndex(where: { $0.id == id }) {
            macs[i].name = name.isEmpty ? macs[i].name : name
            macs[i].paired = Date()
        } else {
            macs.append(Mac(id: id, name: name.isEmpty ? String(localized: "Mac") : name, paired: Date()))
        }
        save()
    }

    func forget(_ id: UInt64) {
        Self.deleteKey(id)
        macs.removeAll { $0.id == id }
        save()
    }

    /// A game seen open on a paired Mac: remembered, newest first.
    func saw(gameID: String, title: String, on macID: UInt64, macName: String?) {
        guard let i = macs.firstIndex(where: { $0.id == macID }) else { return }
        if let name = macName, !name.isEmpty, name != macs[i].name { macs[i].name = name }
        if let j = macs[i].games.firstIndex(where: { $0.id == gameID }) {
            let lastSeen = macs[i].games[j].lastSeen
            macs[i].games[j].title = title
            // Written at most once a minute: every browse result would otherwise rewrite the defaults.
            guard Date().timeIntervalSince(lastSeen) > 60 else { return }
            macs[i].games[j].lastSeen = Date()
        } else {
            macs[i].games.append(Game(id: gameID, title: title, lastSeen: Date()))
        }
        macs[i].games.sort { $0.lastSeen > $1.lastSeen }
        save()
    }

    func mode(gameID: String, on macID: UInt64) -> PadMode? {
        mac(macID)?.games.first { $0.id == gameID }?.mode.flatMap(PadMode.init(rawValue:))
    }

    func setMode(_ mode: PadMode, gameID: String, on macID: UInt64) {
        guard let i = macs.firstIndex(where: { $0.id == macID }), let j = macs[i].games.firstIndex(where: { $0.id == gameID }),
              macs[i].games[j].mode != mode.rawValue else { return }
        macs[i].games[j].mode = mode.rawValue
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(macs) { UserDefaults.standard.set(data, forKey: Self.defaultsKey) }
    }

    // MARK: Keychain

    private static func account(_ id: UInt64) -> String { String(format: "%016llx", id) }

    private static func query(_ id: UInt64) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService,
         kSecAttrAccount as String: account(id)]
    }

    /// Where a key goes when the Keychain refuses it (errSecMissingEntitlement: an unsigned build in the Simulator); a
    /// signed app on a phone always has its Keychain.
    private static func fallbackKey(_ id: UInt64) -> String { "pairKey." + account(id) }

    private static func loadKey(_ id: UInt64) -> Data? {
        if let data = UserDefaults.standard.data(forKey: fallbackKey(id)), data.count == 32 { return data }
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data, data.count == 32 else { return nil }
        return data
    }

    private static func saveKey(_ id: UInt64, _ key: Data) {
        SecItemDelete(query(id) as CFDictionary)
        var q = query(id)
        q[kSecValueData as String] = key
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        if SecItemAdd(q as CFDictionary, nil) == errSecMissingEntitlement {
            UserDefaults.standard.set(key, forKey: fallbackKey(id))
        } else {
            UserDefaults.standard.removeObject(forKey: fallbackKey(id))
        }
    }

    private static func deleteKey(_ id: UInt64) {
        SecItemDelete(query(id) as CFDictionary)
        UserDefaults.standard.removeObject(forKey: fallbackKey(id))
    }
}
