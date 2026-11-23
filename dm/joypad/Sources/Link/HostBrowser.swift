import Foundation
import Network
import Observation

/// Finds games that offer an NX Pad receiver on the local network (Bonjour `_nxpad._udp`).
@MainActor
@Observable
final class HostBrowser {
    struct Host: Identifiable, Hashable {
        let endpoint: NWEndpoint
        /// The Bonjour service name, usually the Mac's name.
        let name: String
        /// The game, from the TXT record's `game` key.
        let title: String?
        /// The Mac's ID (`mac`), which a pairing is kept by; nil for a host of protocol 1, which knows no pairing.
        let macID: UInt64?
        /// The Mac's name (`host`).
        let macName: String?
        /// The game's title ID (`tid`), which the phone remembers its games by.
        let titleID: String?

        var id: String { name }
        /// The game, as the phone remembers it.
        var gameKey: String { titleID ?? title ?? name }
        var displayTitle: String { title ?? name }

        init?(result: NWBrowser.Result) {
            guard case let .service(name, _, _, _) = result.endpoint else { return nil }
            endpoint = result.endpoint
            self.name = name
            var txt = NWTXTRecord()
            if case let .bonjour(record) = result.metadata { txt = record }
            title = txt["game"].flatMap { $0.isEmpty ? nil : $0 }
            macID = txt["mac"].flatMap { UInt64($0, radix: 16) }.flatMap { $0 == 0 ? nil : $0 }
            macName = txt["host"].flatMap { $0.isEmpty ? nil : $0 }
            titleID = txt["tid"].flatMap { $0.isEmpty || $0 == "0000000000000000" ? nil : $0 }
        }
    }

    private(set) var hosts: [Host] = []
    private(set) var problem: String?
    /// Whether `hosts` is what the network shows now: the empty list a stopped browser leaves (the app in the background,
    /// a browse that failed) says nothing about which games closed.
    var isBrowsing: Bool { browser != nil }
    /// Every change of the list, on the main actor.
    @ObservationIgnored var onChange: (([Host]) -> Void)?
    @ObservationIgnored private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let params = NWParameters()
        params.includePeerToPeer = false
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: Wire.serviceType, domain: nil), using: params)
        b.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.browserChanged(state) }
        }
        b.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.update(results) }
        }
        b.start(queue: .main)
        browser = b
    }

    func stop() {
        browser?.cancel()
        browser = nil
        if !hosts.isEmpty {
            hosts = []
            onChange?(hosts)
        }
    }

    private func browserChanged(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            problem = nil
        case .waiting(let error):
            problem = Self.describe(error)
        case .failed(let error):
            problem = Self.describe(error)
            stop()
            // Local Network access granted just now, Wi-Fi back: try again shortly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                MainActor.assumeIsolated { self?.start() }
            }
        default:
            break
        }
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        var byName: [String: Host] = [:]
        for result in results {
            if let host = Host(result: result) { byName[host.name] = host }
        }
        hosts = byName.values.sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
        onChange?(hosts)
    }

    private static func describe(_ error: NWError) -> String {
        if case let .dns(code) = error, code == -65570 {   // kDNSServiceErr_PolicyDenied: Local Network access is off
            return String(localized: "Allow Local Network access for NX Pad in Settings to find games.")
        }
        return error.localizedDescription
    }
}
