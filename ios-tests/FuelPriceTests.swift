import Foundation
import Testing
@testable import FuelLockCompanion

struct FuelPriceTests {

    private let sampleJSON = """
    {
      "updated": 1795747650,
      "regions": [
        {
          "region": "VIC",
          "prices": [
            {
              "name": "7-Eleven Truganina",
              "type": "E10",
              "price": 179.9,
              "suburb": "Truganina",
              "state": "VIC",
              "postcode": "3029",
              "lat": -37.83808,
              "lng": 144.72777
            },
            {
              "name": "7-Eleven Truganina",
              "type": "U91",
              "price": 183.9,
              "suburb": "Truganina",
              "state": "VIC",
              "postcode": "3029",
              "lat": -37.83808,
              "lng": 144.72777
            }
          ]
        },
        {
          "region": "VIC-2",
          "prices": [
            {
              "name": "7-Eleven Frankston",
              "type": "U91",
              "price": 185.9,
              "suburb": "Frankston",
              "state": "VIC",
              "postcode": "3199",
              "lat": -38.14726,
              "lng": 145.13604
            }
          ]
        },
        {
          "region": "VIC-3",
          "prices": [
            {
              "name": "7-Eleven Werribee",
              "type": "U91",
              "price": 186.5,
              "suburb": "Werribee",
              "state": "VIC",
              "postcode": "3030",
              "lat": -37.9001,
              "lng": 144.6601
            }
          ]
        }
      ]
    }
    """

    @Test func decodesAndExtractsTopThreeRankedStations() throws {
        let data = try #require(sampleJSON.data(using: .utf8))
        let decoded = try JSONDecoder().decode(ProjectZeroThreeResponse.self, from: data)
        #expect(decoded.updated == 1795747650)

        let u91 = FuelPriceService.extractStations(from: decoded, fuelType: .u91, region: .vic)
        #expect(u91.count == 3)
        #expect(u91[0].rank == 1)
        #expect(u91[0].station.name == "7-Eleven Truganina")
        #expect(u91[0].station.formattedPrice == "183.9")
        #expect(u91[1].rank == 2)
        #expect(u91[1].station.suburb == "Frankston")
        #expect(u91[2].rank == 3)
        #expect(u91[2].station.suburb == "Werribee")

        let e10 = FuelPriceService.extractStations(from: decoded, fuelType: .e10, region: .vic)
        #expect(e10.count == 1)
        #expect(e10[0].rank == 1)
    }

    @Test func networkStatusHostStripsCIDRAndWhitespace() {
        #expect(NetworkStatus.host(" 10.7.0.1/32 ") == "10.7.0.1")
        #expect(NetworkStatus.host("10.7.0.1") == "10.7.0.1")
    }

    @Test func networkStatusTunnelIsUpRules() {
        #expect(NetworkStatus.tunnelIsUp(route: .dedicated, fallbackMatch: false, probe: nil) == true)
        #expect(NetworkStatus.tunnelIsUp(route: .other, fallbackMatch: false, probe: nil) == false)
        #expect(NetworkStatus.tunnelIsUp(route: .other, fallbackMatch: true, probe: nil) == true)
        #expect(NetworkStatus.tunnelIsUp(route: .fullTunnel(interface: "utun4", source: "10.7.1.1"), fallbackMatch: false, probe: .refused) == true)
        #expect(NetworkStatus.tunnelIsUp(route: .fullTunnel(interface: "utun4", source: "10.7.1.1"), fallbackMatch: false, probe: .timedOut) == false)
    }

    @Test func pairingFileKindDetectsRemoteAndLockdown() throws {
        let remotePlist = try PropertyListSerialization.data(
            fromPropertyList: ["private_key": Data([1, 2, 3]), "public_key": Data([4, 5, 6])],
            format: .xml,
            options: 0
        )
        let remoteKind = PairingFileKind.of(data: remotePlist)
        #expect(remoteKind.hasRemotePairing == true)
        #expect(remoteKind.hasLockdown == false)
        #expect(remoteKind.isUsable == true)

        let lockdownPlist = try PropertyListSerialization.data(
            fromPropertyList: ["HostCertificate": Data([1]), "HostPrivateKey": Data([2])],
            format: .xml,
            options: 0
        )
        let lockdownKind = PairingFileKind.of(data: lockdownPlist)
        #expect(lockdownKind.hasRemotePairing == false)
        #expect(lockdownKind.hasLockdown == true)
        #expect(lockdownKind.isUsable == true)

        let invalid = PairingFileKind.of(data: Data("not a plist".utf8))
        #expect(invalid.isUsable == false)
    }
}
