import Foundation
import UniformTypeIdentifiers

/// Manages the standard `Documents/pairingFile.plist` storage path,
/// legacy migration from `pairing.mobiledevicepairing`, and pairing file import.
enum PairingFileStore {
    static let standardFilename = "pairingFile.plist"
    static let legacyFilename = "pairing.mobiledevicepairing"

    static var supportedContentTypes: [UTType] {
        var types: [UTType] = [.propertyList, .xml, .data]
        if let pairingType = UTType(filenameExtension: "mobiledevicepairing") {
            types.insert(pairingType, at: 0)
        }
        return types
    }

    static func standardURL(in documentsDirectory: URL) -> URL {
        documentsDirectory.appendingPathComponent(standardFilename)
    }

    static func legacyURL(in documentsDirectory: URL) -> URL {
        documentsDirectory.appendingPathComponent(legacyFilename)
    }

    enum ImportError: LocalizedError, Equatable {
        case invalidPairingFile
        case unreadableFile(String)

        var errorDescription: String? {
            switch self {
            case .invalidPairingFile:
                return "That file doesn't look like an iOS pairing file."
            case .unreadableFile(let detail):
                return "Couldn't import pairing file: \(detail)"
            }
        }
    }

    struct ImportResult: Equatable {
        let kind: PairingFileKind
        let filename: String
    }

    /// Migrates a legacy `pairing.mobiledevicepairing` file to `pairingFile.plist`
    /// if the standard file does not yet exist (or is empty). Returns `true` if migrated.
    @discardableResult
    static func migrateLegacyIfNeeded(in documentsDirectory: URL, fileManager: FileManager = .default) -> Bool {
        let target = standardURL(in: documentsDirectory)
        let legacy = legacyURL(in: documentsDirectory)

        if hasNonEmptyFile(at: target, fileManager: fileManager) {
            return false
        }
        guard hasNonEmptyFile(at: legacy, fileManager: fileManager) else {
            return false
        }

        do {
            try fileManager.createDirectory(at: documentsDirectory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: target.path) {
                try fileManager.removeItem(at: target)
            }
            try fileManager.moveItem(at: legacy, to: target)
            return true
        } catch {
            // Fall back to copy if move fails across volumes/permissions
            if let data = try? Data(contentsOf: legacy) {
                do {
                    try data.write(to: target, options: .atomic)
                    try? fileManager.removeItem(at: legacy)
                    return true
                } catch {
                    return false
                }
            }
            return false
        }
    }

    static func hasNonEmptyFile(at url: URL, fileManager: FileManager = .default) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return false }
        let attrs = try? fileManager.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int) ?? 0
        return size > 0
    }

    /// Validates and writes a pairing file from `sourceURL` to `destinationURL`.
    /// Handles security-scoped URLs and in-place URLs where `sourceURL == destinationURL`.
    static func importFile(
        from sourceURL: URL,
        to destinationURL: URL,
        fileManager: FileManager = .default
    ) throws -> ImportResult {
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }

        let data: Data
        do {
            data = try Data(contentsOf: sourceURL)
        } catch {
            throw ImportError.unreadableFile(error.localizedDescription)
        }

        let kind = PairingFileKind.of(data: data)
        guard kind.isUsable else {
            throw ImportError.invalidPairingFile
        }

        if sourceURL.standardizedFileURL != destinationURL.standardizedFileURL {
            do {
                try fileManager.createDirectory(
                    at: destinationURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: destinationURL, options: .atomic)
            } catch {
                throw ImportError.unreadableFile(error.localizedDescription)
            }
        }

        return ImportResult(kind: kind, filename: sourceURL.lastPathComponent)
    }
}
