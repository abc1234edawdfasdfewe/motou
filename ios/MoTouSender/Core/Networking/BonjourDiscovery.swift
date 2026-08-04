import Foundation
import Observation

/// Bonjour browser for the Android receiver's `_motou._tcp` NSD service.
@MainActor
@Observable
final class BonjourDiscovery: NSObject {
    static let serviceType = "_motou._tcp."

    private(set) var devices: [DiscoveredDevice] = []
    private(set) var isSearching = false
    private(set) var errorMessage: String?

    @ObservationIgnored private let browser = NetServiceBrowser()
    @ObservationIgnored private var services: [String: NetService] = [:]

    override init() {
        super.init()
        browser.delegate = self
    }

    deinit {
        browser.stop()
        services.values.forEach { $0.stop() }
    }

    func start() {
        guard !isSearching else { return }
        errorMessage = nil
        isSearching = true
        browser.searchForServices(ofType: Self.serviceType, inDomain: "local.")
    }

    func stop() {
        guard isSearching || !services.isEmpty else { return }
        browser.stop()
        services.values.forEach { $0.stop() }
        services.removeAll()
        devices.removeAll()
        isSearching = false
    }

    private func found(_ service: NetService) {
        let id = serviceID(service)
        guard services[id] == nil else { return }
        services[id] = service
        service.delegate = self
        service.resolve(withTimeout: 8)
    }

    private func lost(_ service: NetService) {
        let id = serviceID(service)
        services.removeValue(forKey: id)?.stop()
        devices.removeAll { $0.id == id }
    }

    private func resolved(_ service: NetService) {
        var host = service.hostName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, (1...65_535).contains(service.port) else { return }

        let id = serviceID(service)
        let device = DiscoveredDevice(
            id: id,
            name: service.name.isEmpty ? "墨投设备" : service.name,
            host: host,
            port: service.port
        )
        devices.removeAll { $0.id == id }
        devices.append(device)
        devices.sort {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func serviceID(_ service: NetService) -> String {
        "\(service.name)|\(service.type)|\(service.domain)"
    }
}

extension BonjourDiscovery: @preconcurrency NetServiceBrowserDelegate {
    func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        isSearching = true
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        isSearching = false
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didNotSearch errorDict: [String: NSNumber]
    ) {
        isSearching = false
        errorMessage = "Bonjour 搜索失败（\(errorDict)）"
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        found(service)
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        lost(service)
    }
}

extension BonjourDiscovery: @preconcurrency NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        resolved(sender)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        // Discovery continues; a transient failure for one advertisement should not
        // hide already-resolved devices or stop the browser.
        errorMessage = "无法解析设备 \(sender.name)（\(errorDict)）"
    }
}
