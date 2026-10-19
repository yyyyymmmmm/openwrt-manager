import Foundation
import Observation
import OpenWrtKit

@MainActor @Observable
final class RouterStore {
    private(set) var profiles: [RouterProfile] = []
    private(set) var activeProfile: RouterProfile?
    private(set) var isDemo = false
    private(set) var connectionID = UUID()
    private(set) var snapshot: RouterSnapshot?
    private(set) var leases: [DHCPLease] = []
    private(set) var radios: [WirelessRadio] = []
    private(set) var services: [RouterService] = []
    private(set) var overviewError: String?
    private(set) var devicesError: String?
    private(set) var wirelessError: String?
    private(set) var servicesError: String?
    private(set) var storageError: String?
    private(set) var isRefreshing = false
    private(set) var hasLoaded = false
    private(set) var overviewUpdatedAt: Date?
    private(set) var devicesUpdatedAt: Date?
    private(set) var wirelessUpdatedAt: Date?
    private(set) var servicesUpdatedAt: Date?

    @ObservationIgnored private var transport: RouterTransport?
    @ObservationIgnored private var reader: RouterReader?
    @ObservationIgnored private let credentials = CredentialStore()
    @ObservationIgnored private let defaults: UserDefaults
    private let profilesKey = "router-profiles.v1"

    var hasConnection: Bool { isDemo || activeProfile != nil }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: profilesKey) {
            do { profiles = try JSONDecoder().decode([RouterProfile].self, from: data) }
            catch { storageError = "保存的路由器列表无法读取。原始记录仍保留在设备上。" }
        }
    }

    func credential(for profile: RouterProfile) throws -> StoredCredential? {
        try credentials.read(id: profile.id)
    }

    /// Return a certificate notice through the error so the UI can ask once,
    /// then retry with that exact fingerprint. Nothing is persisted on failure.
    func connect(profile: RouterProfile, password: String, fingerprint: String?) async throws {
        let address = try URLNormalizer.normalize(profile.address)
        let candidateTransport = RouterTransport(address: address, fingerprint: fingerprint)
        let client = UbusClient(address: address, session: candidateTransport.session)
        let session: UbusSession
        do {
            session = try await client.login(username: profile.username, password: password)
            try Task.checkCancellation()
        } catch {
            let notice = candidateTransport.delegate.certificateNotice
            candidateTransport.close()
            if let notice { throw AppFailure.certificate(notice) }
            throw error
        }
        var saved = profile
        saved.address = address.url.absoluteString
        saved.lastConnected = Date()
        if saved.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { saved.name = address.host }
        do {
            try credentials.save(StoredCredential(password: saved.rememberPassword ? password : nil,
                                                 certificateFingerprint: fingerprint), id: saved.id)
        } catch {
            candidateTransport.close()
            throw error
        }
        let oldReader = reader
        let oldTransport = transport
        transport = candidateTransport
        reader = RouterReader(client: client, session: session)
        activeProfile = saved
        isDemo = false
        connectionID = UUID()
        clearData()
        profiles.removeAll { $0.id == saved.id }
        profiles.insert(saved, at: 0)
        persist()
        if let oldReader { Task { await oldReader.logout(); oldTransport?.close() } }
        else { oldTransport?.close() }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        if isDemo { loadDemo(); return }
        guard let reader else { return }
        let generation = connectionID
        isRefreshing = true
        defer { if generation == connectionID { isRefreshing = false } }
        async let overview = capture { try await reader.snapshot() }
        async let devices = capture { try await reader.leases() }
        async let wireless = capture { try await reader.wireless() }
        async let serviceList = capture { try await reader.services() }
        let results = await (overview, devices, wireless, serviceList)
        guard generation == connectionID, !Task.isCancelled else { return }
        switch results.0 {
        case .success(let value): snapshot = value; overviewError = nil; overviewUpdatedAt = Date()
        case .failure(let error): overviewError = FriendlyError.message(error)
        }
        switch results.1 {
        case .success(let value): leases = value; devicesError = nil; devicesUpdatedAt = Date()
        case .failure(let error): devicesError = FriendlyError.message(error)
        }
        switch results.2 {
        case .success(let value): radios = value; wirelessError = nil; wirelessUpdatedAt = Date()
        case .failure(let error): wirelessError = FriendlyError.message(error)
        }
        switch results.3 {
        case .success(let value): services = value; servicesError = nil; servicesUpdatedAt = Date()
        case .failure(let error): servicesError = FriendlyError.message(error)
        }
        hasLoaded = true
    }

    func disconnect() {
        let oldReader = reader
        let oldTransport = transport
        reader = nil; transport = nil
        activeProfile = nil; isDemo = false; connectionID = UUID()
        clearData()
        if let oldReader { Task { await oldReader.logout(); oldTransport?.close() } }
        else { oldTransport?.close() }
    }

    func remove(_ profile: RouterProfile) throws {
        try credentials.delete(id: profile.id)
        profiles.removeAll { $0.id == profile.id }
        persist()
        if activeProfile?.id == profile.id { disconnect() }
    }

    func enterDemo() {
        disconnect()
        isDemo = true; connectionID = UUID()
        loadDemo()
    }

    private func persist() {
        do {
            defaults.set(try JSONEncoder().encode(profiles), forKey: profilesKey)
            storageError = nil
        } catch { storageError = "路由器列表未能保存，下次打开可能需要重新添加。" }
    }

    private func clearData() {
        snapshot = nil; leases = []; radios = []; services = []
        overviewError = nil; devicesError = nil; wirelessError = nil; servicesError = nil
        overviewUpdatedAt = nil; devicesUpdatedAt = nil; wirelessUpdatedAt = nil; servicesUpdatedAt = nil
        hasLoaded = false; isRefreshing = false
    }

    private func loadDemo() {
        snapshot = DemoData.snapshot
        leases = DemoData.leases; radios = DemoData.radios; services = DemoData.services
        let now = Date()
        overviewUpdatedAt = now; devicesUpdatedAt = now; wirelessUpdatedAt = now; servicesUpdatedAt = now
        hasLoaded = true
    }

    private nonisolated func capture<T: Sendable>(_ operation: @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await operation()) }
        catch { return .failure(error) }
    }
}
