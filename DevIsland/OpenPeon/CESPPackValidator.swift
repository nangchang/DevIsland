import Foundation

enum CESPPackValidator {
    private static let namePattern = #"^[a-z0-9][a-z0-9_-]*$"#
    private static let semverPattern = #"^[0-9]+(\.[0-9]+){0,2}([+-][0-9A-Za-z.-]+)?$"#
    private static let supportedExtensions: Set<String> = ["wav", "mp3", "ogg"]
    private static let playbackSupportedExtensions: Set<String> = ["wav", "mp3"]
    private static let maxAudioFileSize: Int64 = 1_000_000
    private static let maxPackSize: Int64 = 50_000_000

    static func loadPack(at rootURL: URL, fileManager: FileManager = .default) -> CESPPack? {
        let manifestURL = rootURL.appendingPathComponent("openpeon.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(CESPManifest.self, from: data) else {
            return nil
        }
        return CESPPack(
            rootURL: rootURL,
            manifest: manifest,
            validation: validate(manifest: manifest, rootURL: rootURL, fileManager: fileManager)
        )
    }

    static func validate(
        manifest: CESPManifest,
        rootURL: URL,
        fileManager: FileManager = .default
    ) -> CESPValidationResult {
        var result = CESPValidationResult()

        if manifest.cespVersion != "1.0" {
            result.errors.append("Unsupported CESP version: \(manifest.cespVersion)")
        }
        if !matches(manifest.name, pattern: namePattern) {
            result.errors.append("Pack name must use lowercase letters, numbers, dashes, or underscores.")
        }
        if !matches(manifest.version, pattern: semverPattern) {
            result.errors.append("Pack version must be semver-compatible.")
        }
        if manifest.categories.isEmpty {
            result.errors.append("Pack must define at least one category.")
        }

        let rootPath = rootURL.standardizedFileURL.path
        var totalSize: Int64 = 0

        if let enumerator = fileManager.enumerator(at: rootURL, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let fileURL as URL in enumerator {
                guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
                      let size = values.fileSize else { continue }
                totalSize += Int64(size)
                if totalSize > maxPackSize {
                    result.errors.append("Pack exceeds 50 MB.")
                    break
                }
            }
        }

        for (categoryName, category) in manifest.categories {
            if CESPCategory(rawValue: categoryName) == nil {
                result.warnings.append("Unknown CESP category: \(categoryName)")
            }
            if category.sounds.isEmpty {
                result.errors.append("\(categoryName) must define at least one sound.")
            }

            for sound in category.sounds {
                let path = sound.file
                let url = rootURL.appendingPathComponent(path).standardizedFileURL
                let ext = url.pathExtension.lowercased()

                if path.isEmpty || path.hasPrefix("/") {
                    result.errors.append("\(path) must be a relative path.")
                    continue
                }
                if path.split(separator: "/").contains("..") {
                    result.errors.append("\(path) must not contain '..'.")
                    continue
                }
                if !url.path.hasPrefix(rootPath + "/") {
                    result.errors.append("\(path) resolves outside the pack directory.")
                    continue
                }
                if !supportedExtensions.contains(ext) {
                    result.errors.append("\(path) uses an unsupported audio extension.")
                    continue
                }
                if ext == "ogg" || !playbackSupportedExtensions.contains(ext) {
                    result.warnings.append("\(path) is recognized by CESP but not playable by the macOS MVP player.")
                }
                guard fileManager.fileExists(atPath: url.path) else {
                    result.errors.append("\(path) is missing.")
                    continue
                }
                if let attrs = try? fileManager.attributesOfItem(atPath: url.path),
                   let size = attrs[.size] as? NSNumber,
                   size.int64Value > maxAudioFileSize {
                    result.errors.append("\(path) exceeds 1 MB.")
                }
            }
        }

        return result
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}
