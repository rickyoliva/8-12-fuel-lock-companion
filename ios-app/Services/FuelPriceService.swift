import Foundation

/// Fetches and caches live 7-Eleven fuel prices from Project Zero Three.
@MainActor
final class FuelPriceService: ObservableObject {

    static let endpoint = URL(string: "https://projectzerothree.info/api.php?format=json")!
    static let userAgent = "8-12-Fuel-Lock-Companion/1.0 (iOS)"
    /// Polite cooldown between automatic fetches so Cloudflare isn't hammered.
    static let automaticCooldown: TimeInterval = 5 * 60

    @Published private(set) var response: ProjectZeroThreeResponse?
    @Published private(set) var lastFetchedAt: Date?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let session: URLSession
    private let cacheURL: URL

    struct CachedPayload: Codable {
        let fetchedAt: Date
        let response: ProjectZeroThreeResponse
    }

    init(session: URLSession? = nil, cacheURL: URL? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.timeoutIntervalForRequest = 15
            config.httpAdditionalHeaders = [
                "User-Agent": Self.userAgent,
                "Accept": "application/json"
            ]
            self.session = URLSession(configuration: config)
        }

        if let cacheURL {
            self.cacheURL = cacheURL
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL.temporaryDirectory
            self.cacheURL = caches.appendingPathComponent("projectzerothree_cache.json")
        }

        loadCache()
    }

    /// Top 1–3 stations for the selected fuel type and region, sorted by rank.
    func stations(for fuelType: FuelType, region: FuelRegion) -> [RankedFuelStation] {
        guard let response else { return [] }
        return Self.extractStations(from: response, fuelType: fuelType, region: region)
    }

    nonisolated static func extractStations(
        from response: ProjectZeroThreeResponse,
        fuelType: FuelType,
        region: FuelRegion
    ) -> [RankedFuelStation] {
        var result: [RankedFuelStation] = []
        for (index, key) in region.rankedKeys.enumerated() {
            guard let regionEntry = response.regions.first(where: { $0.region == key }),
                  let station = regionEntry.prices.first(where: {
                      $0.type.caseInsensitiveCompare(fuelType.rawValue) == .orderedSame
                  })
            else { continue }
            result.append(RankedFuelStation(rank: index + 1, station: station))
        }
        return result
    }

    /// Fetches fresh prices if needed, respecting the automatic cooldown unless `force` is true.
    func refresh(force: Bool = false) async {
        guard !isLoading else { return }
        if !force, let lastFetchedAt, Date().timeIntervalSince(lastFetchedAt) < Self.automaticCooldown, response != nil {
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            var request = URLRequest(url: Self.endpoint)
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, urlResponse) = try await session.data(for: request)
            if let http = urlResponse as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw FuelPriceError.httpStatus(http.statusCode)
            }

            let decoded = try JSONDecoder().decode(ProjectZeroThreeResponse.self, from: data)
            let now = Date()

            // Only rewrite cache if `updated` changed or we had no cache yet,
            // while still updating `lastFetchedAt` to honor the cooldown.
            let shouldWriteCache = response?.updated != decoded.updated
            response = decoded
            lastFetchedAt = now
            if shouldWriteCache {
                saveCache(CachedPayload(fetchedAt: now, response: decoded))
            }
        } catch {
            if response != nil {
                errorMessage = "Couldn't refresh prices (\(error.localizedDescription)). Showing cached prices."
            } else {
                errorMessage = "Couldn't load fuel prices (\(error.localizedDescription))."
            }
        }
    }

    var updatedDate: Date? {
        guard let updated = response?.updated else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(updated))
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? JSONDecoder().decode(CachedPayload.self, from: data)
        else { return }
        response = cached.response
        lastFetchedAt = cached.fetchedAt
    }

    private func saveCache(_ payload: CachedPayload) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    enum FuelPriceError: LocalizedError {
        case httpStatus(Int)

        var errorDescription: String? {
            switch self {
            case .httpStatus(let code):
                return "Server returned HTTP \(code)"
            }
        }
    }
}
