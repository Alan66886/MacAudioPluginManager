import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: PluginStore
    @State private var detailRowID: String?
    @State private var sortOrder: [KeyPathComparator<PluginRow>] = []

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            HSplitView {
                vendorSidebar
                    .frame(minWidth: 180, idealWidth: 210, maxWidth: 280)
                pluginList
                    .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            statusBar
        }
        .frame(minWidth: 960, minHeight: 520)
        .task {
            store.startIfNeeded()
        }
        .confirmationDialog(
            "移到废纸篓？",
            isPresented: $store.showTrashConfirmation,
            titleVisibility: .visible
        ) {
            Button("移到废纸篓", role: .destructive) {
                store.trashSelected()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(store.trashConfirmationMessage)
        }
        .alert(item: $store.trashReport) { report in
            Alert(
                title: Text("无法移到废纸篓"),
                message: Text(report.message),
                dismissButton: .default(Text("好"))
            )
        }
        .onChange(of: store.searchText) { _, _ in
            clearSelectionAndDetails()
        }
        .onChange(of: store.vendorFilter) { _, _ in
            clearSelectionAndDetails()
        }
        .onChange(of: store.rows.map(\.id)) { _, ids in
            if let detailRowID, !ids.contains(detailRowID) {
                self.detailRowID = nil
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("搜索名称、厂商或路径", text: $store.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 14))

            if !store.searchText.isEmpty {
                Button {
                    store.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("清除搜索")
            }

            if store.isScanning {
                ProgressView()
                    .controlSize(.small)
                Text("扫描中")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("重新扫描") {
                store.scan()
            }
            .disabled(store.isScanning || store.isTrashing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var vendorSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("厂商")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 9)
                .padding(.bottom, 3)

            List(selection: $store.vendorFilter) {
                HStack(spacing: 8) {
                    Label("全部插件", systemImage: "square.grid.2x2")
                    Spacer(minLength: 8)
                    Text("\(store.rows.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .tag("")
                .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))

                ForEach(store.vendors) { vendor in
                    HStack(spacing: 8) {
                        Text(vendor.name)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(vendor.name)
                        Text("\(vendor.count)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    .tag(vendor.name)
                    .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 20)
        }
    }

    private var displayedRows: [PluginRow] {
        guard !sortOrder.isEmpty else { return store.filteredRows }
        return store.filteredRows.sorted(using: sortOrder)
    }

    private var pluginList: some View {
        VStack(spacing: 0) {
            Table(displayedRows, selection: $detailRowID, sortOrder: $sortOrder) {
                TableColumn("卸载") { row in
                    RowCheckbox(state: checkState(for: row)) {
                        store.toggleRow(row)
                    }
                }
                .width(min: 34, ideal: 36, max: 40)

                TableColumn("名称", value: \.nameSortKey) { row in
                    Text(row.name)
                        .lineLimit(1)
                        .help(row.name)
                }
                .width(min: 140, ideal: 170, max: 260)

                TableColumn("厂商", value: \.vendorSortKey) { row in
                    Text(row.vendor)
                        .lineLimit(1)
                        .help(row.vendor)
                }
                .width(min: 90, ideal: 115, max: 180)

                TableColumn("格式") { row in
                    FormatSelectionCell(row: row, selectedIDs: $store.selectedIDs)
                }
                .width(min: 228, ideal: 232, max: 250)

                TableColumn("版本", value: \.versionSortKey) { row in
                    Text(row.displayVersion)
                        .font(.caption.monospacedDigit())
                        .lineLimit(1)
                        .help(row.displayVersion)
                }
                .width(min: 62, ideal: 72, max: 100)

                TableColumn("大小", value: \.totalSize) { row in
                    Text(row.displaySize)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 65, ideal: 75, max: 90)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .overlay {
                if store.filteredRows.isEmpty {
                    emptyState
                }
            }

            if let detailRow {
                Divider()
                detailView(detailRow)
            }

            Divider()

            HStack(spacing: 10) {
                Text("\(store.filteredRows.count) 个插件")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button(role: .destructive) {
                    store.showTrashConfirmation = true
                } label: {
                    Label("移到废纸篓", systemImage: "trash")
                }
                .disabled(store.selectedIDs.isEmpty || store.isTrashing)
                .help("只移动勾选了格式的插件到 Finder 废纸篓，可从废纸篓还原")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
    }

    private var detailRow: PluginRow? {
        guard let detailRowID else { return nil }
        return store.rows.first { $0.id == detailRowID }
    }

    private func detailView(_ row: PluginRow) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.name)
                    .font(.headline)
                Text(row.vendor)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(row.displaySize)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ForEach(row.orderedEntries) { entry in
                HStack(spacing: 8) {
                    Text(entry.format.rawValue)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .leading)

                    Text(entry.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(entry.path)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.06))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            if store.isScanning {
                ProgressView()
                Text("正在扫描插件…")
                    .foregroundStyle(.secondary)
            } else if store.rows.isEmpty {
                Image(systemName: "waveform.slash")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text("没有找到插件")
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text("没有匹配的插件")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            if store.isTrashing || store.isCalculatingSizes {
                ProgressView()
                    .controlSize(.small)
            }

            Text(store.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if !store.scanWarnings.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help(store.scanWarnings.joined(separator: "\n"))
            }

            Spacer()

            if !store.selectedIDs.isEmpty {
                Text("已选 \(store.selectedIDs.count) 个格式")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.bar)
    }

    private func checkState(for row: PluginRow) -> RowCheckState {
        PluginSelection.state(for: row, selectedIDs: store.selectedIDs)
    }

    private func clearSelectionAndDetails() {
        store.selectedIDs.removeAll()
        detailRowID = nil
    }
}

private struct RowCheckbox: View {
    let state: RowCheckState
    let action: () -> Void

    var body: some View {
        CheckboxMark(
            checked: state == .all,
            mixed: state == .mixed,
            size: 14
        )
        .frame(width: 34, height: 22, alignment: .leading)
        .contentShape(Rectangle())
        // Table row selection otherwise swallows the first click on this cell.
        .highPriorityGesture(TapGesture().onEnded(action))
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(state == .all ? "取消选择此插件的全部格式" : "选择此插件的全部格式")
        .accessibilityAction { action() }
    }
}

private struct FormatSelectionCell: View {
    let row: PluginRow
    @Binding var selectedIDs: Set<String>

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PluginFormat.allCases, id: \.self) { format in
                let entry = row.entry(for: format)
                let isSelected = entry.map { selectedIDs.contains($0.id) } ?? false

                HStack(spacing: 3) {
                    CheckboxMark(
                        checked: isSelected,
                        enabled: entry != nil,
                        size: 12
                    )
                    Text(format.rawValue)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(entry == nil ? Color.secondary.opacity(0.45) : Color.primary)
                }
                .frame(width: 44, height: 22, alignment: .leading)
                .contentShape(Rectangle())
                // Keep format toggles responsive even when the row is not selected.
                .highPriorityGesture(
                    TapGesture().onEnded {
                        guard let entry else { return }
                        PluginSelection.setSelected(!isSelected, for: entry, selectedIDs: &selectedIDs)
                    }
                )
                .accessibilityElement(children: .ignore)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(
                    "\(format.rawValue)，\(entry == nil ? "未安装" : (isSelected ? "已选择" : "未选择"))"
                )
                .accessibilityAction {
                    guard let entry else { return }
                    PluginSelection.setSelected(!isSelected, for: entry, selectedIDs: &selectedIDs)
                }
            }
        }
    }
}

private struct CheckboxMark: View {
    let checked: Bool
    var mixed = false
    var enabled = true
    var size: CGFloat = 13

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(fillColor)
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(borderColor, lineWidth: 1)
                }

            if mixed {
                Rectangle()
                    .fill(.white)
                    .frame(width: size * 0.55, height: 1.5)
            } else if checked {
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.62, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }

    private var fillColor: Color {
        if checked || mixed {
            return .accentColor
        }
        if !enabled {
            return Color.secondary.opacity(0.08)
        }
        return Color.clear
    }

    private var borderColor: Color {
        enabled ? Color.secondary.opacity(0.55) : Color.secondary.opacity(0.22)
    }
}
