import Combine
import Foundation

struct TrashFailure: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let reason: String
    let code: String
}

struct TrashFailureReport: Identifiable {
    let id = UUID()
    let failures: [TrashFailure]

    var message: String {
        let details = failures.map { failure in
            """
            \(failure.name)
            \(failure.path)
            \(failure.reason)（\(failure.code)）
            """
        }

        return (details + [
            "提示：/Library 下的插件需要管理员权限；这一版没有实现提权，所以可能无法移动。"
        ]).joined(separator: "\n\n")
    }
}

private struct TrashOutcome {
    let succeeded: [String]
    let failures: [TrashFailure]
}

@MainActor
final class PluginStore: ObservableObject {
    @Published private(set) var plugins: [Plugin] = []
    @Published var searchText = ""
    @Published var vendorFilter = ""
    @Published var selectedIDs = Set<String>()
    @Published var isScanning = false
    @Published var isCalculatingSizes = false
    @Published var isTrashing = false
    @Published var statusText = ""
    @Published var scanWarnings: [String] = []
    @Published var showTrashConfirmation = false
    @Published var trashReport: TrashFailureReport?

    private var scanTask: Task<Void, Never>?
    private var sizeTask: Task<Void, Never>?
    private var generation = UUID()
    private var didStart = false

    var rows: [PluginRow] {
        PluginRow.makeRows(from: plugins)
    }

    var vendors: [VendorCount] {
        Dictionary(grouping: rows, by: \.vendor)
            .map { VendorCount(name: $0.key, count: $0.value.count) }
            .sorted { lhs, rhs in
                if lhs.name == "未知" { return false }
                if rhs.name == "未知" { return true }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    var filteredRows: [PluginRow] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        return rows.filter { row in
            if !vendorFilter.isEmpty, row.vendor != vendorFilter {
                return false
            }
            guard !query.isEmpty else { return true }

            if row.name.localizedCaseInsensitiveContains(query)
                || row.vendor.localizedCaseInsensitiveContains(query) {
                return true
            }

            return row.entries.contains {
                $0.path.localizedCaseInsensitiveContains(query)
            }
        }
    }

    var selectedEntries: [Plugin] {
        plugins.filter { selectedIDs.contains($0.id) }
    }

    var trashConfirmationMessage: String {
        let selectedRows = rows.compactMap { row -> (PluginRow, [Plugin])? in
            let entries = row.entries.filter { selectedIDs.contains($0.id) }
            return entries.isEmpty ? nil : (row, entries)
        }

        guard !selectedRows.isEmpty else { return "" }

        let formatCount = selectedRows.reduce(0) { $0 + $1.1.count }
        let lines = selectedRows.prefix(8).map { row, entries in
            "• \(row.name)：\(entries.map { $0.format.rawValue }.joined(separator: " / "))"
        }
        let more = selectedRows.count > 8 ? "\n… 等 \(selectedRows.count) 个插件" : ""

        return """
        将 \(formatCount) 个格式（\(selectedRows.count) 个插件）移到废纸篓。

        \(lines.joined(separator: "\n"))\(more)

        可以从废纸篓还原。
        """
    }

    func startIfNeeded() {
        guard !didStart else { return }
        didStart = true
        scan()
    }

    func scan() {
        scanTask?.cancel()
        sizeTask?.cancel()

        let newGeneration = UUID()
        generation = newGeneration

        isScanning = true
        isCalculatingSizes = false
        isTrashing = false
        statusText = "正在扫描…"
        scanWarnings = []
        plugins = []
        selectedIDs = []
        vendorFilter = ""
        showTrashConfirmation = false

        scanTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                PluginScanner.scan()
            }.value

            guard !Task.isCancelled,
                  let self,
                  self.generation == newGeneration else {
                return
            }

            self.plugins = result.plugins
            self.isScanning = false
            let rowCount = PluginRow.makeRows(from: result.plugins).count
            self.statusText = "共 \(rowCount) 个插件 · \(result.plugins.count) 个格式"

            if !result.warnings.isEmpty {
                self.scanWarnings = result.warnings
                self.statusText += " · \(result.warnings.count) 个目录读取失败"
            }

            self.computeSizes(for: result.plugins, generation: newGeneration)
        }
    }

    func toggleRow(_ row: PluginRow) {
        PluginSelection.toggle(row: row, selectedIDs: &selectedIDs)
    }

    private func computeSizes(for plugins: [Plugin], generation: UUID) {
        isCalculatingSizes = true

        sizeTask = Task { [weak self] in
            let sizes: [String: Int64] = await Task.detached(priority: .utility) { () -> [String: Int64] in
                var result: [String: Int64] = [:]
                for plugin in plugins {
                    if Task.isCancelled {
                        return [:]
                    }
                    result[plugin.id] = PluginScanner.size(of: URL(fileURLWithPath: plugin.path))
                }
                return result
            }.value

            guard let self,
                  !Task.isCancelled,
                  self.generation == generation else {
                return
            }

            var updatedPlugins = self.plugins
            for index in updatedPlugins.indices {
                if let size = sizes[updatedPlugins[index].id] {
                    updatedPlugins[index].size = size
                }
            }

            self.plugins = updatedPlugins
            self.isCalculatingSizes = false
        }
    }

    func trashSelected() {
        let targets = selectedEntries
        guard !targets.isEmpty, !isTrashing else { return }

        isTrashing = true
        statusText = "正在移到废纸篓…"
        let currentGeneration = generation

        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                var succeeded: [String] = []
                var failures: [TrashFailure] = []

                for plugin in targets {
                    let url = URL(fileURLWithPath: plugin.path)
                    var resultingURL: NSURL?

                    do {
                        try FileManager.default.trashItem(
                            at: url,
                            resultingItemURL: &resultingURL
                        )
                        succeeded.append(plugin.id)
                    } catch {
                        let nsError = error as NSError
                        failures.append(
                            TrashFailure(
                                name: "\(plugin.name) · \(plugin.format.rawValue)",
                                path: plugin.path,
                                reason: error.localizedDescription,
                                code: "\(nsError.domain) \(nsError.code)"
                            )
                        )
                    }
                }

                return TrashOutcome(succeeded: succeeded, failures: failures)
            }.value

            guard self.generation == currentGeneration else { return }

            self.isTrashing = false

            if !outcome.succeeded.isEmpty {
                let removedIDs = Set(outcome.succeeded)
                self.plugins.removeAll { removedIDs.contains($0.id) }
                self.selectedIDs.subtract(removedIDs)

                if !self.vendorFilter.isEmpty,
                   !self.vendors.contains(where: { $0.name == self.vendorFilter }) {
                    self.vendorFilter = ""
                }
            }

            if outcome.failures.isEmpty {
                self.statusText = "已把 \(outcome.succeeded.count) 个格式移到废纸篓，可从废纸篓还原。"
            } else {
                self.trashReport = TrashFailureReport(failures: outcome.failures)
                if outcome.succeeded.isEmpty {
                    self.statusText = "未能移动：\(outcome.failures.count) 个格式"
                } else {
                    self.statusText = "已移动 \(outcome.succeeded.count) 个格式，另有 \(outcome.failures.count) 个失败。"
                }
            }
        }
    }
}
