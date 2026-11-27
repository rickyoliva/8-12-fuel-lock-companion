import Foundation
import Testing
@testable import FuelLockCompanion

struct OnboardingAndPairingTests {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FuelLockTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func sampleRemotePairingData() throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: [
                "private_key": Data([1, 2, 3, 4]),
                "public_key": Data([5, 6, 7, 8])
            ],
            format: .xml,
            options: 0
        )
    }

    // MARK: - PairingFileStore Tests

    @Test func standardFilenameIsPairingFilePlist() {
        #expect(PairingFileStore.standardFilename == "pairingFile.plist")
        #expect(PairingFileStore.legacyFilename == "pairing.mobiledevicepairing")
    }

    @Test func migratesLegacyPairingFileToStandardPath() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let legacyURL = PairingFileStore.legacyURL(in: dir)
        let standardURL = PairingFileStore.standardURL(in: dir)
        let payload = try sampleRemotePairingData()
        try payload.write(to: legacyURL)

        let migrated = PairingFileStore.migrateLegacyIfNeeded(in: dir)
        #expect(migrated == true)
        #expect(FileManager.default.fileExists(atPath: standardURL.path))
        #expect(!FileManager.default.fileExists(atPath: legacyURL.path))
        #expect(try Data(contentsOf: standardURL) == payload)
    }

    @Test func migrationDoesNotOverwriteExistingStandardFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let legacyURL = PairingFileStore.legacyURL(in: dir)
        let standardURL = PairingFileStore.standardURL(in: dir)
        let standardData = Data("existing-standard".utf8)
        let legacyData = try sampleRemotePairingData()
        try standardData.write(to: standardURL)
        try legacyData.write(to: legacyURL)

        let migrated = PairingFileStore.migrateLegacyIfNeeded(in: dir)
        #expect(migrated == false)
        #expect(try Data(contentsOf: standardURL) == standardData)
    }

    @Test func importsValidPairingFileAndHandlesInPlace() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let sourceURL = dir.appendingPathComponent("SideInstallerExport.mobiledevicepairing")
        let destURL = PairingFileStore.standardURL(in: dir)
        let payload = try sampleRemotePairingData()
        try payload.write(to: sourceURL)

        let result = try PairingFileStore.importFile(from: sourceURL, to: destURL)
        #expect(result.kind.hasRemotePairing == true)
        #expect(result.filename == "SideInstallerExport.mobiledevicepairing")
        #expect(try Data(contentsOf: destURL) == payload)

        // Re-importing in-place (destURL -> destURL) succeeds without corrupting file
        let inPlace = try PairingFileStore.importFile(from: destURL, to: destURL)
        #expect(inPlace.kind.hasRemotePairing == true)
        #expect(try Data(contentsOf: destURL) == payload)
    }

    @Test func rejectsInvalidPairingFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let invalidURL = dir.appendingPathComponent("bad.plist")
        let destURL = PairingFileStore.standardURL(in: dir)
        try Data("not a valid plist".utf8).write(to: invalidURL)

        #expect(throws: PairingFileStore.ImportError.invalidPairingFile) {
            try PairingFileStore.importFile(from: invalidURL, to: destURL)
        }
        #expect(!FileManager.default.fileExists(atPath: destURL.path))
    }

    // MARK: - OnboardingState Tests

    @Test func onboardingStagedProgressionAndDisclaimerGating() {
        var state = OnboardingState()
        #expect(state.expandedStep == .localDevVPN)
        #expect(state.canContinueToApp == false)

        // Skip VPN -> collapses step 1, advances to pairing file
        state.skipVPN()
        state.advance(vpnDetected: false, pairingExists: false)
        #expect(state.isStepSkipped(.localDevVPN, vpnDetected: false, pairingExists: false) == true)
        #expect(state.isStepComplete(.localDevVPN, vpnDetected: false, pairingExists: false) == true)
        #expect(state.expandedStep == .pairingFile)
        #expect(state.canContinueToApp == false)

        // Pairing file detected -> advances to disclaimer
        state.advance(vpnDetected: false, pairingExists: true)
        #expect(state.isStepComplete(.pairingFile, vpnDetected: false, pairingExists: true) == true)
        #expect(state.expandedStep == .disclaimer)
        #expect(state.canContinueToApp == false)

        // Acknowledge disclaimer -> enables Continue to app & advances to ready
        state.acknowledgeDisclaimer()
        state.advance(vpnDetected: false, pairingExists: true)
        #expect(state.canContinueToApp == true)
        #expect(state.expandedStep == .ready)
    }

    // MARK: - Picker Options Tests

    @Test func fuelAndRegionPickerOptionsMatchExpectedOrder() {
        #expect(FuelType.allCases.map(\.rawValue) == ["E10", "U91", "U95", "U98", "Diesel", "LPG"])
        #expect(FuelRegion.allCases.map(\.rawValue) == ["All", "VIC", "NSW", "QLD", "WA"])
    }
}
