import Foundation

/// Apple's Developer Disk Image (Cryptex for iOS 26.4+ and Personalized fallback),
/// downloaded on first use from `doronz88/DeveloperDiskImage`.
enum DeveloperDiskImage {

    enum Variant: CaseIterable {
        case personalized
        case cryptex

        fileprivate var folder: String {
            switch self {
            case .personalized: "Xcode_iOS_DDI_Personalized"
            case .cryptex: "Xcode_iOS_DDI_Cryptex"
            }
        }

        fileprivate var files: [String] {
            switch self {
            case .personalized:
                ["BuildManifest.plist", "Image.dmg", "Image.dmg.trustcache"]
            case .cryptex:
                [
                    "BuildManifest.plist",
                    "Image.dmg",
                    "Image.dmg.trustcache",
                    "Image.dmg.cryptex_info",
                    "Image.dmg.root_hash",
                ]
            }
        }

        var directory: URL {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? URL.documentsDirectory
            switch self {
            case .personalized:
                return docs.appendingPathComponent("DDI", isDirectory: true)
            case .cryptex:
                return docs.appendingPathComponent("DDI-Cryptex", isDirectory: true)
            }
        }

        var logName: String {
            switch self {
            case .personalized: "personalized image"
            case .cryptex: "cryptex"
            }
        }
    }

    static var installsAsCryptex: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 26, minorVersion: 4, patchVersion: 0)
        )
    }

    static var variants: [Variant] {
        installsAsCryptex ? [.cryptex, .personalized] : [.personalized]
    }

    static var preferred: Variant { variants[0] }

    static var imagePath: String { Variant.personalized.directory.appendingPathComponent("Image.dmg").path }
    static var trustcachePath: String { Variant.personalized.directory.appendingPathComponent("Image.dmg.trustcache").path }
    static var manifestPath: String { Variant.personalized.directory.appendingPathComponent("BuildManifest.plist").path }
    static var cryptexDirectory: String { Variant.cryptex.directory.path }

    static var isDownloaded: Bool { isDownloaded(preferred) }

    static func isDownloaded(_ variant: Variant) -> Bool {
        variant.files.allSatisfy { name in
            let path = variant.directory.appendingPathComponent(name).path
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return (attributes?[.size] as? Int ?? 0) > 0
        }
    }

    static func downloadMissing(
        _ variant: Variant = preferred,
        log: ((String) -> Void)? = nil,
        progress: @escaping (Double) -> Void
    ) async throws {
        let directory = variant.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let missing = variant.files.filter { name in
            let path = directory.appendingPathComponent(name).path
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return (attributes?[.size] as? Int ?? 0) == 0
        }
        guard !missing.isEmpty else {
            progress(1)
            return
        }

        let baseURL = "https://github.com/doronz88/DeveloperDiskImage/raw/refs/heads/main/PersonalizedImages/\(variant.folder)"
        for (index, name) in missing.enumerated() {
            progress(Double(index) / Double(missing.count))
            guard let url = URL(string: "\(baseURL)/\(name)") else {
                throw DDIError.message("Couldn't build the download URL for \(name).")
            }
            let (tmp, response) = try await URLSession.shared.download(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw DDIError.message("Downloading \(name) failed (HTTP \(code)).")
            }
            let destination = directory.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tmp, to: destination)
            log?("DDI: downloaded \(name) (\(variant.logName)).")
        }
        progress(1)
    }

    enum DDIError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let text) = self { return text }
            return nil
        }
    }
}
