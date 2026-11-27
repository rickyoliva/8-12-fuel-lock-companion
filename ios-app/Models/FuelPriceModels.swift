import CoreLocation
import Foundation

/// Fuel types supported by Project Zero Three and 7-Eleven Fuel Lock.
enum FuelType: String, CaseIterable, Identifiable, Codable {
    case e10 = "E10"
    case u91 = "U91"
    case u95 = "U95"
    case u98 = "U98"
    case diesel = "Diesel"
    case lpg = "LPG"

    var id: String { rawValue }
}

/// Regions exposed by Project Zero Three (top 1–3 stations per region).
enum FuelRegion: String, CaseIterable, Identifiable, Codable {
    case all = "All"
    case vic = "VIC"
    case nsw = "NSW"
    case qld = "QLD"
    case wa = "WA"

    var id: String { rawValue }

    /// The API region keys for rank #1, #2, and #3 in order.
    var rankedKeys: [String] {
        [rawValue, "\(rawValue)-2", "\(rawValue)-3"]
    }
}

/// Raw API response from `https://projectzerothree.info/api.php?format=json`.
struct ProjectZeroThreeResponse: Codable, Equatable {
    let updated: Int
    let regions: [RegionPrices]

    struct RegionPrices: Codable, Equatable {
        let region: String
        let prices: [FuelStation]
    }
}

/// A single station entry inside a Project Zero Three region list.
struct FuelStation: Codable, Equatable, Identifiable {
    let name: String
    let type: String
    let price: Double
    let suburb: String
    let state: String
    let postcode: String
    let lat: Double
    let lng: Double

    var id: String {
        "\(name)-\(type)-\(postcode)-\(lat)-\(lng)"
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    var formattedPrice: String {
        String(format: "%.1f", price)
    }

    var locationSummary: String {
        "\(suburb), \(state) \(postcode)"
    }
}

/// A station paired with its rank (1 = cheapest, 2/3 = runners-up) for a region & fuel type.
struct RankedFuelStation: Identifiable, Equatable {
    let rank: Int
    let station: FuelStation

    var id: String {
        "\(rank)-\(station.id)"
    }
}
