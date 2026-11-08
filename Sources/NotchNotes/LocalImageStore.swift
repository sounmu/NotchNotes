import AppKit
import Foundation
import MarkdownEngine

final class LocalImageStore: EmbeddedImageFileProvider, @unchecked Sendable {
    private struct ImageAssetRecord: Codable {
        var id: String
        var displayName: String
        var storedFilename: String
        var originalPath: String?
        var sourceKind: String
        var createdAt: Date
    }

    private let directoryURL: URL
    private let manifestURL: URL
    private let lock = NSLock()
    private var records: [String: ImageAssetRecord]
    private var version = 0
    private let imageExtension = "png"

    init(directory: URL? = nil) {
        let supportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directoryURL = directory ?? supportURL.appendingPathComponent("NotchNotes/Images", isDirectory: true)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        manifestURL = directoryURL.appendingPathComponent("manifest.json")
        records = Self.loadRecords(from: manifestURL)
    }

    func saveImage(from pasteboard: NSPasteboard) -> String? {
        if let fileURL = PasteboardImageReader.imageFileURL(from: pasteboard),
           let data = try? Data(contentsOf: fileURL),
           NSImage(data: data) != nil {
            return save(
                data: pngData(fromImageData: data) ?? data,
                originalName: fileURL.deletingPathExtension().lastPathComponent,
                originalFileURL: fileURL,
                sourceKind: "file"
            )
        }

        guard let pngData = PasteboardImageReader.imageData(from: pasteboard) else {
            return nil
        }

        return save(
            data: pngData,
            originalName: "pasted-image",
            originalFileURL: nil,
            sourceKind: "clipboardImage"
        )
    }

    func saveImage(data: Data, name: String) -> String? {
        guard let png = pngData(fromImageData: data) else { return nil }
        return save(data: png, originalName: name, originalFileURL: nil, sourceKind: "editorUpload")
    }

    func editorImageData(reference: String) -> Data? {
        let parts = reference.components(separatedBy: "|")
        guard !parts.contains(where: { $0.contains("/") || $0.contains("\\") || $0 == ".." }) else { return nil }
        let request = EmbeddedImageRequest(name: parts[0], id: parts.count > 1 ? parts[1] : nil)
        guard let url = storedFileURL(for: request) else { return nil }
        return try? Data(contentsOf: url)
    }

    func image(for reference: EmbeddedImageRequest) -> NSImage? {
        let candidateNames = [reference.id, reference.name].compactMap { $0 }

        for candidateName in candidateNames {
            let url = imageURL(for: candidateName)
            if let image = NSImage(contentsOf: url) {
                return image
            }
        }

        return nil
    }

    func storedFileURL(for reference: EmbeddedImageRequest) -> URL? {
        guard let candidateName = recordCandidateNames(for: reference).first(where: { !$0.isEmpty }) else {
            return nil
        }

        lock.lock()
        let record = records[candidateName]
        lock.unlock()

        if let record {
            let url = directoryURL.appendingPathComponent(record.storedFilename)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }

        let fallbackURL = imageURL(for: candidateName)
        return FileManager.default.fileExists(atPath: fallbackURL.path) ? fallbackURL : nil
    }

    func originalFileURL(for reference: EmbeddedImageRequest) -> URL? {
        guard let candidateName = recordCandidateNames(for: reference).first(where: { !$0.isEmpty }) else {
            return nil
        }

        lock.lock()
        let path = records[candidateName]?.originalPath
        lock.unlock()

        guard let path else { return nil }
        let url = URL(fileURLWithPath: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func fingerprint() -> AnyHashable {
        lock.lock()
        defer { lock.unlock() }
        return version
    }

    private func save(data: Data, originalName: String, originalFileURL: URL?, sourceKind: String) -> String? {
        let displayName = sanitizedDisplayName(originalName)
        let id = UUID()
        let storedFilename = "\(id.uuidString).\(imageExtension)"
        let url = imageURL(for: id.uuidString)

        do {
            try data.write(to: url, options: .atomic)
            let record = ImageAssetRecord(
                id: id.uuidString,
                displayName: displayName,
                storedFilename: storedFilename,
                originalPath: originalFileURL?.path,
                sourceKind: sourceKind,
                createdAt: Date()
            )
            lock.lock()
            records[id.uuidString] = record
            let recordsToSave = records
            version += 1
            lock.unlock()
            saveRecords(recordsToSave)
            return "![[\(displayName)|\(id.uuidString)]]"
        } catch {
            return nil
        }
    }

    private func recordCandidateNames(for reference: EmbeddedImageRequest) -> [String] {
        [reference.id, reference.name].compactMap { $0 }
    }

    private func imageURL(for idOrName: String) -> URL {
        if idOrName.lowercased().hasSuffix(".\(imageExtension)") {
            return directoryURL.appendingPathComponent(idOrName)
        }

        return directoryURL.appendingPathComponent("\(idOrName).\(imageExtension)")
    }

    private func sanitizedDisplayName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmed.isEmpty ? "pasted-image" : trimmed
        return fallback
            .replacingOccurrences(of: "|", with: "-")
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private func pngData(fromImageData data: Data) -> Data? {
        guard let image = NSImage(data: data),
              let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }

        return bitmap.representation(using: .png, properties: [:])
    }

    private static func loadRecords(from url: URL) -> [String: ImageAssetRecord] {
        guard let data = try? Data(contentsOf: url),
              let records = try? JSONDecoder().decode([ImageAssetRecord].self, from: data) else {
            return [:]
        }

        return Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
    }

    private func saveRecords(_ records: [String: ImageAssetRecord]) {
        let sortedRecords = records.values.sorted { $0.createdAt < $1.createdAt }
        guard let data = try? JSONEncoder().encode(sortedRecords) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }
}
