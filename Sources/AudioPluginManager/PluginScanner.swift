import Foundation
import Security

struct ScanResult {
    let plugins: [Plugin]
    let warnings: [String]
}

enum PluginScanner {
    private struct Location {
        let url: URL
        let format: PluginFormat
    }

    private struct Metadata {
        let name: String
        let vendor: String
        let version: String
        let vendorSource: VendorSource
    }

    private struct AudioComponentMetadata {
        let name: String?
        let vendor: String?
        let vendorSource: VendorSource
    }

    private enum VendorSource: Int {
        case audioComponentName = 0
        case audioComponentDescription = 1
        case moduleInfo = 2
        case codeSignature = 3
        case bundleIdentifier = 4
        case unknown = 5
    }

    private struct Candidate {
        let plugin: Plugin
        let vendorSource: VendorSource
    }

    private static var locations: [Location] {
        let home = FileManager.default.homeDirectoryForCurrentUser

        return [
            Location(
                url: URL(fileURLWithPath: "/Library/Audio/Plug-Ins/Components", isDirectory: true),
                format: .au
            ),
            Location(
                url: URL(fileURLWithPath: "/Library/Audio/Plug-Ins/VST3", isDirectory: true),
                format: .vst3
            ),
            Location(
                url: URL(fileURLWithPath: "/Library/Audio/Plug-Ins/VST", isDirectory: true),
                format: .vst
            ),
            Location(
                url: URL(fileURLWithPath: "/Library/Audio/Plug-Ins/CLAP", isDirectory: true),
                format: .clap
            ),
            Location(
                url: home.appendingPathComponent("Library/Audio/Plug-Ins/Components", isDirectory: true),
                format: .au
            ),
            Location(
                url: URL(
                    fileURLWithPath: "/Library/Application Support/Avid/Audio/Plug-Ins",
                    isDirectory: true
                ),
                format: .aax
            )
        ]
    }

    private static func pathExtension(for format: PluginFormat) -> String {
        switch format {
        case .au: return "component"
        case .vst3: return "vst3"
        case .vst: return "vst"
        case .clap: return "clap"
        case .aax: return "aaxplugin"
        }
    }

    static func scan() -> ScanResult {
        let fileManager = FileManager.default
        var candidates: [Candidate] = []
        var warnings: [String] = []
        var seenPaths = Set<String>()

        for location in locations {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: location.url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }

            let entries: [URL]
            do {
                entries = try fileManager.contentsOfDirectory(
                    at: location.url,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]
                )
            } catch {
                warnings.append("无法读取 \(location.url.path)：\(error.localizedDescription)")
                continue
            }

            let wantedExtension = pathExtension(for: location.format)

            for url in entries where url.pathExtension.lowercased() == wantedExtension {
                let path = url.standardizedFileURL.path
                guard seenPaths.insert(path).inserted else { continue }

                let info = infoPlist(for: url)
                let metadata = metadata(for: url, format: location.format, info: info)

                let plugin = Plugin(
                    name: metadata.name,
                    vendor: metadata.vendor,
                    format: location.format,
                    version: metadata.version,
                    path: path,
                    size: nil
                )
                candidates.append(Candidate(plugin: plugin, vendorSource: metadata.vendorSource))
            }
        }

        let canonicalVendors = canonicalVendorNames(for: candidates)
        var plugins = candidates.map { candidate -> Plugin in
            var plugin = candidate.plugin
            let key = VendorNormalizer.key(plugin.vendor)
            if let canonical = canonicalVendors[key] {
                plugin.vendor = canonical
            }
            plugin.name = displayName(plugin.name, vendor: plugin.vendor)
            return plugin
        }

        plugins.sort { lhs, rhs in
            let vendorOrder = lhs.vendor.localizedStandardCompare(rhs.vendor)
            if vendorOrder != .orderedSame {
                return vendorOrder == .orderedAscending
            }
            let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }

        return ScanResult(plugins: plugins, warnings: warnings)
    }

    static func size(of url: URL) -> Int64 {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return 0
        }

        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileAllocatedSizeKey,
            .totalFileAllocatedSizeKey,
            .fileSizeKey
        ]

        guard isDirectory.boolValue else {
            return allocatedSize(of: url, keys: keys)
        }

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                continue
            }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }

    private static func allocatedSize(of url: URL, keys: Set<URLResourceKey>) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isSymbolicLink != true else {
            return 0
        }
        return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
    }

    private static func metadata(
        for url: URL,
        format: PluginFormat,
        info: [String: Any]?
    ) -> Metadata {
        var name = baseName(for: url, info: info)
        var vendor: String?
        var vendorSource = VendorSource.unknown

        if format == .au || format == .aax,
           let component = audioComponentMetadata(info) {
            if let componentName = component.name {
                name = componentName
            }
            vendor = component.vendor
            vendorSource = component.vendorSource
        }

        if vendor == nil, format == .vst3,
           let moduleInfoVendor = moduleInfoVendor(for: url) {
            vendor = moduleInfoVendor
            vendorSource = .moduleInfo
        }

        if vendor == nil,
           let signedVendor = signingVendor(for: url) {
            vendor = signedVendor
            vendorSource = .codeSignature
        }

        if vendor == nil,
           let identifierVendor = bundleIdentifierVendor(info) {
            vendor = identifierVendor
            vendorSource = .bundleIdentifier
        }

        return Metadata(
            name: name,
            vendor: vendor ?? "未知",
            version: versionString(info),
            vendorSource: vendor == nil ? .unknown : vendorSource
        )
    }

    private static func infoPlist(for bundleURL: URL) -> [String: Any]? {
        let plistURL = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist", isDirectory: false)

        guard let data = try? Data(contentsOf: plistURL) else {
            return nil
        }

        guard let propertyList = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) else {
            return nil
        }

        return propertyList as? [String: Any]
    }

    private static func audioComponentMetadata(_ info: [String: Any]?) -> AudioComponentMetadata? {
        guard let components = info?["AudioComponents"] as? [[String: Any]],
              !components.isEmpty else {
            return nil
        }

        var firstName: String?
        var firstDescription: String?

        for component in components {
            let componentName = nonEmpty(component["name"] as? String)
            let componentDescription = nonEmpty(component["description"] as? String)

            if firstName == nil {
                firstName = componentName
            }
            if firstDescription == nil {
                firstDescription = componentDescription
            }

            guard let componentName,
                  let colon = componentName.firstIndex(of: ":") else {
                continue
            }

            let vendor = nonEmpty(String(componentName[..<colon]))
            let pluginName = nonEmpty(String(componentName[componentName.index(after: colon)...]))

            if let vendor, let pluginName {
                return AudioComponentMetadata(
                    name: pluginName,
                    vendor: vendor,
                    vendorSource: .audioComponentName
                )
            }
        }

        return AudioComponentMetadata(
            name: firstName,
            vendor: firstDescription,
            vendorSource: firstDescription == nil ? .unknown : .audioComponentDescription
        )
    }

    private static func baseName(for url: URL, info: [String: Any]?) -> String {
        if let displayName = nonEmpty(info?["CFBundleDisplayName"] as? String) {
            return displayName
        }
        if let bundleName = nonEmpty(info?["CFBundleName"] as? String) {
            return bundleName
        }
        return url.deletingPathExtension().lastPathComponent
    }

    private static func versionString(_ info: [String: Any]?) -> String {
        if let shortVersion = nonEmpty(info?["CFBundleShortVersionString"] as? String) {
            return shortVersion
        }
        if let bundleVersion = info?["CFBundleVersion"] {
            let value = String(describing: bundleVersion)
            if !value.isEmpty {
                return value
            }
        }
        return ""
    }

    private static func moduleInfoVendor(for bundleURL: URL) -> String? {
        let moduleInfoURL = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("moduleinfo.json", isDirectory: false)

        guard let data = try? Data(contentsOf: moduleInfoURL),
              let object = parseJSONLeniently(data) as? [String: Any],
              let classes = object["Classes"] as? [[String: Any]] else {
            return nil
        }

        for pluginClass in classes {
            if let vendor = nonEmpty(pluginClass["Vendor"] as? String) {
                return vendor
            }
        }
        return nil
    }

    /// Some moduleinfo.json files contain trailing commas. Repair those before parsing.
    private static func parseJSONLeniently(_ data: Data) -> Any? {
        if let object = try? JSONSerialization.jsonObject(with: data) {
            return object
        }

        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        let repaired = text.replacingOccurrences(
            of: #",(\s*[}\]])"#,
            with: "$1",
            options: .regularExpression
        )

        guard let repairedData = repaired.data(using: .utf8) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: repairedData)
    }

    private static func signingVendor(for url: URL) -> String? {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode)

        guard createStatus == errSecSuccess, let staticCode else {
            return nil
        }

        var signingInformation: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        )

        guard infoStatus == errSecSuccess,
              let information = signingInformation as? [String: Any],
              let certificates = information[kSecCodeInfoCertificates as String] as? [SecCertificate] else {
            return nil
        }

        let prefix = "Developer ID Application: "
        for certificate in certificates {
            guard let summary = SecCertificateCopySubjectSummary(certificate) as String?,
                  summary.hasPrefix(prefix) else {
                continue
            }

            var company = String(summary.dropFirst(prefix.count))
            company = company.replacingOccurrences(
                of: #"\s+\([A-Za-z0-9]+\)$"#,
                with: "",
                options: .regularExpression
            )

            if let company = nonEmpty(company) {
                return company
            }
        }

        return nil
    }

    private static func bundleIdentifierVendor(_ info: [String: Any]?) -> String? {
        guard let bundleIdentifier = nonEmpty(info?["CFBundleIdentifier"] as? String) else {
            return nil
        }

        let parts = bundleIdentifier.split(separator: ".", omittingEmptySubsequences: true)
        let noise: Set<String> = [
            "com", "org", "net", "edu", "gov", "co", "uk", "de", "fr", "jp", "cn",
            "io", "app", "audio", "music", "local", "www"
        ]

        for part in parts where !noise.contains(part.lowercased()) {
            return String(part)
        }

        return parts.first.map(String.init)
    }

    private static func canonicalVendorNames(for candidates: [Candidate]) -> [String: String] {
        var best: [String: (name: String, rank: Int)] = [:]

        for candidate in candidates {
            let vendor = candidate.plugin.vendor
            guard vendor != "未知" else { continue }

            let key = VendorNormalizer.key(vendor)
            guard !key.isEmpty else { continue }

            let rank = candidate.vendorSource.rawValue
            if let current = best[key] {
                if rank < current.rank
                    || (rank == current.rank && vendor.count < current.name.count) {
                    best[key] = (vendor, rank)
                }
            } else {
                best[key] = (vendor, rank)
            }
        }

        return best.mapValues(\.name)
    }

    private static func displayName(_ name: String, vendor: String) -> String {
        let collapsedName = collapsedWhitespace(name)
        let collapsedVendor = collapsedWhitespace(vendor)

        guard !collapsedVendor.isEmpty,
              collapsedName.lowercased().hasPrefix(collapsedVendor.lowercased()) else {
            return collapsedName
        }

        let remainder = collapsedName.dropFirst(collapsedVendor.count)
        guard remainder.first == " " || remainder.first == ":" else {
            return collapsedName
        }

        let rest = String(remainder)
            .trimmingCharacters(in: CharacterSet(charactersIn: " :"))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return rest.isEmpty ? collapsedName : collapsedWhitespace(rest)
    }

    private static func collapsedWhitespace(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
