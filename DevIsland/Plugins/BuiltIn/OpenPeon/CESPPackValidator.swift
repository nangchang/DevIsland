import Foundation

enum CESPPackValidator {
    private static let namePattern = #"^[a-z0-9][a-z0-9_-]*$"#
    private static let semverPattern = #"^[0-9]+(\.[0-9]+){0,2}([+-][0-9A-Za-z.-]+)?$"#
    private static let supportedExtensions: Set<String> = ["wav", "mp3", "ogg"]
    private static let playbackSupportedExtensions: Set<String> = ["wav", "mp3"]
    private static let maxAudioFileSize: Int64 = 1_000_000
    static let maxPackSize: Int64 = 50_000_000

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
        validate(manifest: manifest, fileIndex: makeFileIndex(rootURL: rootURL, fileManager: fileManager))
    }

    /// Rule evaluation over a pre-collected pack file index. Path/size/existence facts are
    /// resolved into `CESPPackFileIndex` beforehand so the same rules run over either a
    /// `FileManager`-backed scan (host Settings) or a scoped-broker scan (the plugin runtime).
    static func validate(manifest: CESPManifest, fileIndex: CESPPackFileIndex) -> CESPValidationResult {
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
        if fileIndex.totalByteCount > maxPackSize {
            result.errors.append("Pack exceeds 50 MB.")
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
                let ext = (path as NSString).pathExtension.lowercased()

                if path.isEmpty || path.hasPrefix("/") {
                    result.errors.append("\(path) must be a relative path.")
                    continue
                }
                if path.split(separator: "/").contains("..") {
                    result.errors.append("\(path) must not contain '..'.")
                    continue
                }
                if !supportedExtensions.contains(ext) {
                    result.errors.append("\(path) uses an unsupported audio extension.")
                    continue
                }
                if ext == "ogg" || !playbackSupportedExtensions.contains(ext) {
                    // CESP permits OGG, but the MVP player is AVAudioPlayer-backed and
                    // only promises WAV/MP3 playback on stock macOS.
                    result.warnings.append("\(path) is recognized by CESP but not playable by the macOS MVP player.")
                }
                guard let size = fileIndex.fileSizesByRelativePath[path] else {
                    result.errors.append("\(path) is missing.")
                    continue
                }
                if size > maxAudioFileSize {
                    result.errors.append("\(path) exceeds 1 MB.")
                }
            }
        }

        return result
    }

    /// Recursively walks `rootURL` summing regular-file sizes and recording each file's size
    /// keyed by its pack-root-relative path. Directory escape is impossible because relative
    /// paths are derived from real entries under `rootURL`.
    private static func makeFileIndex(rootURL: URL, fileManager: FileManager) -> CESPPackFileIndex {
        var sizes: [String: Int64] = [:]
        var total: Int64 = 0
        let rootPath = rootURL.standardizedFileURL.path

        if let enumerator = fileManager.enumerator(at: rootURL, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let fileURL as URL in enumerator {
                guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
                      let fileSize = values.fileSize else { continue }
                let size = Int64(fileSize)
                total += size
                let path = fileURL.standardizedFileURL.path
                if path.hasPrefix(rootPath + "/") {
                    sizes[String(path.dropFirst(rootPath.count + 1))] = size
                }
                if total > maxPackSize {
                    break
                }
            }
        }

        return CESPPackFileIndex(fileSizesByRelativePath: sizes, totalByteCount: total)
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}
