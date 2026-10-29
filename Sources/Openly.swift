import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Explicit alias keeps the property wrapper distinct from newer SDK State macros.
private typealias ViewState<Value> = SwiftUI.State<Value>
private let applicationColumnWidth: CGFloat = 228

@main
struct OpenlyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Openly · 默认打开方式") {
            MainView().environmentObject(model)
                .frame(minWidth: 720, minHeight: 460)
                .tint(.primary)
        }
        .defaultSize(width: 800, height: 560)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button("刷新默认应用") { model.refresh() }
                    .keyboardShortcut("r")
                    .disabled(model.busy)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var showAdd = false
    @ViewState private var showHistory = false
    @ViewState private var newExtension = ""
    @ViewState private var dropTarget = false
    @FocusState private var searchFocused: Bool
    @FocusState private var extensionFocused: Bool

    var body: some View {
        let visible = model.visible
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                header
                searchBar
                if !model.selectedIDs.isEmpty { selectionBar }
                HStack(spacing: 16) {
                    Text("文件类型").frame(maxWidth: .infinity, alignment: .leading)
                    Text("默认应用").frame(width: applicationColumnWidth, alignment: .leading)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 10)
                Divider().padding(.horizontal, 20)
                if visible.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(visible) { kind in
                                TypeRow(kind: kind)
                                Divider().padding(.horizontal, 20)
                            }
                        }
                    }
                }
                footer(count: visible.count)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .overlay {
            if dropTarget {
                Rectangle().fill(Color(nsColor: .textBackgroundColor).opacity(0.94))
                    .overlay {
                        VStack(spacing: 12) {
                            Image(systemName: "arrow.down.doc").font(.system(size: 28, weight: .light))
                            Text("松开以识别文件类型").font(.system(size: 16, weight: .medium))
                        }
                    }
                    .overlay(Rectangle().strokeBorder(Color.primary, style: StrokeStyle(lineWidth: 2, dash: [6])))
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTarget, perform: receiveDrop)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshIfNeeded()
        }
        .alert("操作未完成", isPresented: Binding(get: { model.error != nil && !showHistory && !showAdd }, set: { if !$0 { model.error = nil } })) {
            Button("知道了", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .sheet(isPresented: $showHistory) { HistoryView().environmentObject(model) }
        .sheet(isPresented: $showAdd) { addSheet }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Openly")
                .font(.system(size: 18, weight: .semibold))
                .padding(.leading, 10)
                .padding(.top, 43)
                .padding(.bottom, 25)
            ForEach(FileGroup.allCases) { group in
                let selected = model.group == group
                Button {
                    model.group = group
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: group.symbol).frame(width: 16)
                        Text(group.rawValue).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .foregroundStyle(selected ? Color(nsColor: .textBackgroundColor) : Color.primary)
                    .background(selected ? Color.primary : Color.clear, in: RoundedRectangle(cornerRadius: 2))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.busy)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .padding(.bottom, 4)
            }
            Spacer(minLength: 24)
            Divider().padding(.horizontal, 10).padding(.bottom, 14)
            Button { showHistory = true } label: {
                Label("最近修改", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 12)
        .frame(width: 148)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 16) {
            Text(model.group == .all ? "默认打开方式" : model.group.rawValue)
                .font(.system(size: 20, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            Button {
                newExtension = ""
                showAdd = true
            } label: {
                Label("添加类型", systemImage: "plus")
            }
            .controlSize(.regular)
            .keyboardShortcut("n")
            .disabled(model.busy)
        }
        .padding(.horizontal, 20)
        .padding(.top, 40)
        .padding(.bottom, 22)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索类型、扩展名或应用", text: $model.query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .disabled(model.busy)
                .accessibilityLabel("搜索文件类型")
            if !model.query.isEmpty {
                Button { model.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
                .disabled(model.busy)
            } else {
                Text("⌘F").font(.system(size: 10)).foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.primary.opacity(searchFocused ? 0.6 : 0.14)))
        .padding(.horizontal, 20)
        .background(Button("") { searchFocused = true }.keyboardShortcut("f").hidden().accessibilityHidden(true))
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Text("已选 \(model.selectedIDs.count) 项")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .fixedSize()
            Button("全选") { model.selectAllVisible() }
                .accessibilityLabel("选择当前列表全部文件类型")
            Button("清除") { model.clearSelection() }
                .accessibilityLabel("清除文件类型选择")
            Spacer(minLength: 0)
            ApplicationPicker(kinds: model.selectedKinds, model: model)
                .frame(width: applicationColumnWidth, height: 28)
        }
        .font(.system(size: 11))
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
        .frame(height: 36)
        .background(Color.primary.opacity(0.055))
        .padding(.top, 12)
        .disabled(model.busy)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("没有匹配的文件类型").font(.system(size: 14, weight: .medium))
            Button("清除搜索与筛选") { model.query = ""; model.group = .all }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func footer(count: Int) -> some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 7) {
                if model.busy {
                    ProgressView().controlSize(.mini)
                    Text("正在设置默认应用…")
                } else {
                    Image(systemName: model.notice == nil ? "arrow.down.doc" : "checkmark")
                        .accessibilityHidden(true)
                    Text(model.notice ?? "Shift 连选 · ⌘ 多选 · 拖入文件查找").lineLimit(1).help(model.notice ?? "Shift 连选 · ⌘ 多选 · 拖入文件查找")
                }
                Spacer(minLength: 8)
                Text("\(count) 项").monospacedDigit().fixedSize()
                Divider().frame(height: 12).padding(.horizontal, 3)
                Button {
                    model.refresh()
                    model.notice = "已刷新默认应用"
                } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 22, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("刷新默认应用 ⌘R")
                .accessibilityLabel("刷新默认应用")
                .disabled(model.busy)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .frame(height: 36)
        }
    }

    private var addSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("添加文件类型").font(.system(size: 18, weight: .semibold))
            Text("输入扩展名，或将文件拖入主窗口。")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("例如：pdf、md、mkv", text: $newExtension)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("文件扩展名")
                .focused($extensionFocused)
                .onSubmit { addType() }
            HStack {
                Spacer()
                Button("取消") { showAdd = false }.keyboardShortcut(.cancelAction)
                Button("添加") { addType() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newExtension.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 344)
        .onAppear { extensionFocused = true }
        .alert("无法添加文件类型", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("知道了", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }

    private func addType() {
        guard !newExtension.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.addExtension(newExtension)
        if model.error == nil { showAdd = false }
    }

    private func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !model.busy, let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, error in
            Task { @MainActor in
                if let url { model.importFile(url) }
                else { model.error = error?.localizedDescription ?? "无法读取拖入的文件。" }
            }
        }
        return true
    }
}

struct TypeRow: View {
    @EnvironmentObject var model: AppModel
    let kind: FileKind

    var body: some View {
        let selected = model.selectedIDs.contains(kind.id)
        HStack(spacing: 16) {
            Button {
                let modifiers = (NSApp.currentEvent?.modifierFlags ?? []).union(NSEvent.modifierFlags)
                model.select(kind, extending: modifiers.contains(.shift), toggling: modifiers.contains(.command))
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: selected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 13))
                        .foregroundStyle(selected ? Color.primary : Color.secondary)
                        .frame(width: 14)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(kind.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(kind.subtitle)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.busy)
            .accessibilityLabel("\(kind.title)，\(kind.subtitle)")
            .accessibilityValue(selected ? "已选择" : "未选择")
            .accessibilityHint("按住 Shift 连续选择，按住 Command 切换选择")
            .accessibilityAddTraits(selected ? .isSelected : [])
            ApplicationPicker(kind: kind, model: model)
                .frame(width: applicationColumnWidth, height: 28)
                .disabled(model.busy)
        }
        .padding(.horizontal, 20)
        .frame(height: 54)
        .background(selected ? Color.primary.opacity(0.075) : Color.clear)
    }
}

// AppKit populates candidates only when a menu opens, keeping list rendering cheap.
// Single-type and batch controls share the same menu and application-selection path.
private struct ApplicationPicker: NSViewRepresentable {
    let kinds: [FileKind]
    let model: AppModel
    let isBatch: Bool

    init(kind: FileKind, model: AppModel) {
        self.kinds = [kind]
        self.model = model
        self.isBatch = false
    }

    init(kinds: [FileKind], model: AppModel) {
        self.kinds = kinds
        self.model = model
        self.isBatch = true
    }

    func makeCoordinator() -> Coordinator { Coordinator(kinds: kinds, model: model, isBatch: isBatch) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: isBatch)
        button.isBordered = false
        button.font = .systemFont(ofSize: 12)
        button.controlSize = .regular
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.cell?.lineBreakMode = .byTruncatingTail
        button.menu?.delegate = context.coordinator
        button.menu?.autoenablesItems = false
        context.coordinator.update(button, kinds: kinds, model: model)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.update(button, kinds: kinds, model: model)
    }

    @MainActor
    final class Coordinator: NSObject, NSMenuDelegate {
        private var kinds: [FileKind]
        private struct Choice {
            let app: URL
            let kinds: [FileKind]
        }
        private var model: AppModel
        private let isBatch: Bool
        private weak var button: NSPopUpButton?
        private var displayedPath: String?
        private var displayedName: String?

        init(kinds: [FileKind], model: AppModel, isBatch: Bool) {
            self.kinds = kinds
            self.model = model
            self.isBatch = isBatch
        }

        private var current: URL? { kinds.first.flatMap { model.defaults[$0.id] } }
        private var title: String { isBatch ? "统一打开方式…" : model.appName(current) }

        func update(_ button: NSPopUpButton, kinds: [FileKind], model: AppModel) {
            self.kinds = kinds
            self.model = model
            self.button = button
            button.isEnabled = !model.busy && !kinds.isEmpty
            button.setAccessibilityLabel(isBatch
                ? "为所选 \(kinds.count) 项统一设置默认应用"
                : "\(kinds.first?.title ?? "文件类型")的默认应用：\(title)")
            guard displayedName != title || displayedPath != current?.path else { return }
            displayedName = title
            displayedPath = current?.path
            if let menu = button.menu { restoreLabel(in: menu) }
        }

        private func restoreLabel(in menu: NSMenu) {
            menu.removeAllItems()
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            if !isBatch {
                item.image = menuIcon(current)
                item.representedObject = current
            }
            menu.addItem(item)
            button?.select(item)
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            guard !model.busy, !kinds.isEmpty else { return }
            let menuKinds = kinds
            menu.removeAllItems()
            if isBatch {
                // NSPopUpButton hides the first item in a pull-down menu.
                menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
            }
            let note = NSMenuItem(title: isBatch
                ? "为所选 \(menuKinds.count) 项设置默认应用"
                : "应用于同类型的所有文件", action: nil, keyEquivalent: "")
            note.isEnabled = false
            if !isBatch { note.toolTip = kinds.first?.id }
            menu.addItem(note)
            menu.addItem(.separator())
            let selectedURL = current?.standardizedFileURL
            let candidates = isBatch ? model.commonApps(for: menuKinds) : model.apps(for: menuKinds[0])
            if candidates.isEmpty || (!isBatch && selectedURL == nil) {
                let empty = NSMenuItem(title: isBatch ? "没有共同可用的应用" : "尚未设置", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                menu.addItem(empty)
                if !isBatch && selectedURL == nil {
                    empty.state = .on
                    button?.select(empty)
                }
            }
            for app in candidates {
                let item = NSMenuItem(title: model.appName(app), action: #selector(selectMenuItem(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = Choice(app: app, kinds: menuKinds)
                let matches = menuKinds.allSatisfy { model.defaults[$0.id]?.standardizedFileURL == app.standardizedFileURL }
                item.state = matches ? .on : .off
                menu.addItem(item)
                if !isBatch && matches { button?.select(item) }
            }
            menu.addItem(.separator())
            let other = NSMenuItem(title: "选择其他应用…", action: #selector(chooseApplication(_:)), keyEquivalent: "")
            other.target = self
            other.representedObject = menuKinds
            menu.addItem(other)
        }

        func menuDidClose(_ menu: NSMenu) {
            // Wait until AppKit has dispatched the chosen item's action before replacing it.
            DispatchQueue.main.async { [weak self, weak menu] in
                guard let self, let menu else { return }
                self.restoreLabel(in: menu)
            }
        }

        @objc private func selectMenuItem(_ sender: NSMenuItem) {
            guard !model.busy, let choice = sender.representedObject as? Choice else { return }
            apply(choice.app, to: choice.kinds)
        }

        private func apply(_ app: URL, to targets: [FileKind]) {
            guard !model.busy, !targets.isEmpty else { return }
            let model = model
            let batch = isBatch
            Task {
                if batch { await model.change(targets, to: app) }
                else { await model.change(targets[0], to: app) }
            }
        }

        @objc private func chooseApplication(_ sender: NSMenuItem) {
            guard !model.busy, let targets = sender.representedObject as? [FileKind], !targets.isEmpty else { return }
            let panel = NSOpenPanel()
            panel.title = isBatch ? "选择打开所选 \(targets.count) 种类型的应用" : "选择打开\(targets[0].title)的应用"
            panel.prompt = isBatch ? "统一设为默认应用" : "设为默认应用"
            panel.allowedContentTypes = [.applicationBundle]
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.begin { response in
                if response == .OK, let url = panel.url {
                    self.apply(url, to: targets)
                }
            }
        }

        private func menuIcon(_ url: URL?) -> NSImage? {
            guard let image = model.icon(for: url)?.copy() as? NSImage else { return nil }
            image.size = NSSize(width: 20, height: 20)
            image.isTemplate = false
            return image
        }
    }
}

struct AppIcon: View {
    @EnvironmentObject var model: AppModel
    let url: URL?
    let size: CGFloat

    var body: some View {
        Group {
            if let icon = model.icon(for: url) {
                Image(nsImage: icon).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: "app.dashed").resizable().scaledToFit().foregroundStyle(.secondary).padding(3)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("最近修改").font(.system(size: 18, weight: .semibold))
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()
            if model.history.isEmpty {
                VStack(spacing: 8) {
                    Text("暂无修改记录").font(.system(size: 14, weight: .medium))
                    Text("修改默认应用后，可在这里撤销。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.history) { record in
                            HStack(spacing: 12) {
                                AppIcon(url: URL(fileURLWithPath: record.newPath), size: 28)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(record.title).font(.system(size: 12, weight: .medium))
                                    Text("\(model.appName(record.oldPath.map { URL(fileURLWithPath: $0) })) → \(model.appName(URL(fileURLWithPath: record.newPath)))")
                                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                    Text(record.date.formatted(date: .abbreviated, time: .shortened))
                                        .font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                if record.restoredAt != nil {
                                    Text("已撤销").font(.system(size: 11)).foregroundStyle(.secondary)
                                } else if record.oldPath == nil {
                                    Text("无原始应用").font(.system(size: 11)).foregroundStyle(.secondary)
                                } else {
                                    Button("撤销") { Task { await model.undo(record) } }
                                        .controlSize(.small)
                                        .disabled(model.busy)
                                        .accessibilityLabel("撤销\(record.title)的默认应用修改")
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                            Divider().padding(.horizontal, 20)
                        }
                    }
                }
            }
            Divider()
            Text("仅记录在 Openly 中完成的修改 · 最近 50 条")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .padding(.horizontal, 20).frame(height: 32)
        }
        .frame(width: 560, height: 400)
        .alert("无法撤销", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("知道了", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}
