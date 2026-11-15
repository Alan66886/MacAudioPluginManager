import Foundation

enum PluginFormat: String, CaseIterable, Sendable {
    case au = "AU"
    case vst3 = "VST3"
    case vst = "VST"
    case clap = "CLAP"
    case aax = "AAX"

    var sortIndex: Int {
        switch self {
        case .au: return 0
        case .vst3: return 1
        case .vst: return 2
        case .clap: return 3
        case .aax: return 4
        }
    }
}

struct Plugin: Identifiable, Sendable {
    var id: String { path }

    var name: String
    var vendor: String
    let format: PluginFormat
    let version: String
    let path: String
    var size: Int64?

    var displayVersion: String {
        version.isEmpty ? "—" : version
    }

    var displaySize: String {
        guard let size else { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

struct VendorCount: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let count: Int
}

struct PluginRow: Identifiable {
    let id: String
    let vendor: String
    let name: String
    let entries: [Plugin]

    var orderedEntries: [Plugin] {
        entries.sorted { $0.format.sortIndex < $1.format.sortIndex }
    }

    func entry(for format: PluginFormat) -> Plugin? {
        entries.first { $0.format == format }
    }

    var totalSize: Int64 {
        entries.reduce(0) { $0 + ($1.size ?? 0) }
    }

    var hasCompleteSize: Bool {
        entries.allSatisfy { $0.size != nil }
    }

    var displaySize: String {
        guard hasCompleteSize else { return "—" }
        return ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }

    var displayVersion: String {
        var seen = Set<String>()
        var versions: [String] = []

        for entry in orderedEntries where !entry.version.isEmpty {
            if seen.insert(entry.version).inserted {
                versions.append(entry.version)
            }
        }

        return versions.isEmpty ? "—" : versions.joined(separator: " / ")
    }

    var nameSortKey: String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
    }

    var vendorSortKey: String {
        vendor.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
    }

    var versionSortKey: PluginVersionKey {
        orderedEntries.map { PluginVersionKey($0.version) }.max() ?? PluginVersionKey("")
    }

    static func makeRows(from plugins: [Plugin]) -> [PluginRow] {
        let grouped = Dictionary(grouping: plugins) { plugin in
            key(vendor: plugin.vendor, name: plugin.name)
        }

        let rows = grouped.map { key, entries -> PluginRow in
            let ordered = entries.sorted { $0.format.sortIndex < $1.format.sortIndex }
            let preferred = ordered.first ?? entries[0]
            return PluginRow(
                id: key,
                vendor: preferred.vendor,
                name: preferred.name,
                entries: ordered
            )
        }

        return rows.sorted { lhs, rhs in
            let vendorOrder = lhs.vendor.localizedStandardCompare(rhs.vendor)
            if vendorOrder != .orderedSame {
                return vendorOrder == .orderedAscending
            }
            let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }

    static func key(vendor: String, name: String) -> String {
        "\(VendorNormalizer.key(vendor))\u{1F}\(normalizedKeyPart(name))"
    }

    static func normalizedKeyPart(_ value: String) -> String {
        value
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
    }
}


enum RowCheckState {
    case none
    case all
    case mixed
}

enum PluginSelection {
    static func state(for row: PluginRow, selectedIDs: Set<String>) -> RowCheckState {
        let selectedCount = row.entries.reduce(0) {
            $0 + (selectedIDs.contains($1.id) ? 1 : 0)
        }

        if selectedCount == 0 { return .none }
        if selectedCount == row.entries.count { return .all }
        return .mixed
    }

    static func toggle(row: PluginRow, selectedIDs: inout Set<String>) {
        let ids = Set(row.entries.map(\.id))
        if ids.isSubset(of: selectedIDs) {
            selectedIDs.subtract(ids)
        } else {
            selectedIDs.formUnion(ids)
        }
    }

    static func setSelected(_ selected: Bool, for entry: Plugin, selectedIDs: inout Set<String>) {
        if selected {
            selectedIDs.insert(entry.id)
        } else {
            selectedIDs.remove(entry.id)
        }
    }
}

enum VendorNormalizer {
    private static let legalSuffixes: Set<String> = [
        "inc", "llc", "ltd", "limited", "gmbh", "bv", "ug", "corp",
        "corporation", "company", "co", "sarl", "sa", "ag", "oy", "ab",
        "as", "plc", "pte", "haftungsbeschrankt"
    ]

    // Only alias vendors whose products are demonstrably the same by name.
    // The row key still requires the normalized plugin names to match.
    private static let aliases: [String: String] = [
        "threebodytech": "pluginalliance",   // Kirchhoff EQ
        "teamhciso": "pluginalliance",       // Black Box Analog Design
        "29palms": "masteringthemix",        // BASSROOM / LEVELS / RESO / ...
        "steveduda": "xferrecords",          // OTT / Serum 2
        "aidenshihadeh": "simplesoundbank",  // simpleSF2
        "tokyodawnlabs": "tokyodawnrecords", // TDR Prism
        "tomberton": "bertom",               // EQ Curve Analyzer 2
        "matthewtytel": "vitalaudio",        // Vital
        "dirkbreebaart": "toneboosters"      // Spectrogram
    ]

    static func key(_ vendor: String) -> String {
        var words = vendor
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }

        while let last = words.last, legalSuffixes.contains(last) {
            words.removeLast()
        }

        let base = words.joined()
        return aliases[base] ?? base
    }
}

struct PluginVersionKey: Comparable, Hashable {
    let components: [Int]
    let raw: String

    init(_ version: String) {
        raw = version
        let parsed = version
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
        components = parsed.isEmpty ? [0] : parsed
    }

    static func < (lhs: PluginVersionKey, rhs: PluginVersionKey) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)

        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right {
                return left < right
            }
        }

        return lhs.raw.localizedStandardCompare(rhs.raw) == .orderedAscending
    }
}
