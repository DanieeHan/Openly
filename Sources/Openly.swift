import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Explicit alias keeps the property wrapper distinct from newer SDK State macros.
private typealias ViewState<Value> = SwiftUI.State<Value>
private let accent = Color.primary

@main
struct OpenlyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("Openly · 默认打开方式") {
            MainView().environmentObject(model)
                .frame(minWidth: 760, minHeight: 540)
                .tint(accent)
        }
        .defaultSize(width: 920, height: 660)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button("刷新默认应用") { model.refresh() }.keyboardShortcut("r")
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
    @Environment(\.colorScheme) private var scheme
    @ViewState private var showAdd = false
    @ViewState private var showHistory = false
    @ViewState private var newExtension = ""
    @ViewState private var dropTarget = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                header
                searchBar
                HStack {
                    Text("文件类型").frame(maxWidth: .infinity, alignment: .leading)
                    Text("默认应用").frame(width: 238, alignment: .leading)
                }.font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 28).padding(.top, 20).padding(.bottom, 9)
                Divider().padding(.horizontal, 24)
                if model.visible.isEmpty { emptyState } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.visible) { kind in
                                TypeRow(kind: kind)
                                Divider().padding(.leading, 78).padding(.trailing, 24)
                            }
                        }
                    }
                }
                footer
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .overlay {
            if dropTarget {
                RoundedRectangle(cornerRadius: 14).fill(accent.opacity(0.10))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(accent, style: StrokeStyle(lineWidth: 2, dash: [7])))
                    .overlay(Label("松开以识别文件类型", systemImage: "arrow.down.doc").font(.title3.weight(.semibold)).padding(22).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)))
                    .padding(8).allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTarget, perform: receiveDrop)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
        .alert("操作未完成", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("知道了", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .sheet(isPresented: $showHistory) { HistoryView().environmentObject(model) }
        .sheet(isPresented: $showAdd) {
            VStack(alignment: .leading, spacing: 18) {
                Text("添加文件类型").font(.title2.bold())
                Text("输入扩展名，或将文件直接拖入主窗口。系统中尚未注册的类型也可以尝试添加。")
                    .font(.callout).foregroundStyle(.secondary)
                TextField("例如：md、psd、mkv", text: $newExtension).textFieldStyle(.roundedBorder)
                    .onSubmit { addType() }
                HStack {
                    Spacer()
                    Button("取消") { showAdd = false }.keyboardShortcut(.cancelAction)
                    Button("添加") { addType() }.keyboardShortcut(.defaultAction).disabled(newExtension.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(28).frame(width: 380)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("Openly").font(.system(size: 20, weight: .semibold))
            }.padding(.top, 47).padding(.bottom, 30).padding(.leading, 10)
            ForEach(FileGroup.allCases) { group in
                Button {
                    model.group = group
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: group.symbol).frame(width: 18)
                        Text(group.rawValue).lineLimit(1).layoutPriority(1)
                        Spacer(minLength: 0)
                        if group == .all { Text("\(model.kinds.count)").font(.system(size: 10, design: .monospaced)).opacity(0.7).fixedSize() }
                    }.font(.system(size: 12, weight: model.group == group ? .semibold : .regular))
                        .padding(.horizontal, 10).frame(height: 36)
                        .foregroundStyle(model.group == group ? accent : .primary)
                        .background(model.group == group ? accent.opacity(scheme == .dark ? 0.23 : 0.09) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.bottom, 3)
            }
            Spacer()
            Button { showHistory = true } label: {
                Label("最近修改", systemImage: "clock.arrow.circlepath").font(.system(size: 12))
            }.buttonStyle(.plain).padding(.leading, 10).padding(.bottom, 23)
        }.padding(.horizontal, 16).frame(width: 176)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 7) {
                Text(model.group == .all ? "默认打开方式" : model.group.rawValue).font(.system(size: 25, weight: .bold))
            }
            Spacer()
            Button { newExtension = ""; showAdd = true } label: {
                Label("添加类型", systemImage: "plus").font(.system(size: 12, weight: .medium)).padding(.vertical, 3)
            }.controlSize(.large).disabled(model.busy)
        }.padding(.horizontal, 28).padding(.top, 45).padding(.bottom, 24)
    }

    private var searchBar: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索类型、扩展名或应用…", text: $model.query).textFieldStyle(.plain).focused($searchFocused)
                .accessibilityLabel("搜索文件类型")
            if !model.query.isEmpty {
                Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).accessibilityLabel("清除搜索")
            } else { Text("⌘F").font(.system(size: 11)).foregroundStyle(.tertiary) }
        }.font(.system(size: 13)).padding(.horizontal, 12).frame(height: 38)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.07)))
            .padding(.horizontal, 28)
            .background(Button("") { searchFocused = true }.keyboardShortcut("f").hidden())
    }

    private var emptyState: some View {
        VStack(spacing: 13) {
            Image(systemName: "doc.text.magnifyingglass").font(.system(size: 36, weight: .light)).foregroundStyle(.secondary)
            Text("没有找到匹配的类型").font(.headline)
            Text("试试其他关键词，或添加新的扩展名。").font(.callout).foregroundStyle(.secondary)
            Button("清除搜索与筛选") { model.query = ""; model.group = .all }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 7) {
                if model.busy {
                    ProgressView().controlSize(.small)
                    Text("等待系统完成设置…")
                } else {
                    Image(systemName: model.notice == nil ? "arrow.down.doc" : "checkmark.circle.fill").foregroundStyle(accent)
                    Text(model.notice ?? "拖入文件以查找类型").lineLimit(1)
                }
                Spacer(minLength: 4)
                Button { model.refresh(); model.notice = "已刷新默认应用" } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("刷新 ⌘R").disabled(model.busy)
                Text("\(model.visible.count) 项").foregroundStyle(.secondary)
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 24).frame(height: 43)
        }
    }

    private func addType() { showAdd = false; model.addExtension(newExtension) }
    private func receiveDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
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
        HStack(spacing: 12) {
            Image(systemName: kind.group == .all ? "doc" : kind.group.symbol)
                .font(.system(size: 18, weight: .regular)).foregroundStyle(accent)
                .frame(width: 36, height: 38)
            VStack(alignment: .leading, spacing: 4) {
                Text(kind.title).font(.system(size: 12, weight: .medium))
                Text(kind.subtitle).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                Text("应用于此系统类型的所有文件")
                Text(kind.id)
                Divider()
                ForEach(model.apps(for: kind), id: \.path) { app in
                    Button {
                        Task { await model.change(kind, to: app) }
                    } label: {
                        if model.defaults[kind.id]?.standardizedFileURL == app.standardizedFileURL {
                            Label(model.appName(app), systemImage: "checkmark")
                        } else { Text(model.appName(app)) }
                    }
                }
                Divider()
                Button("选择其他应用…") { chooseApp() }
            } label: {
                HStack(spacing: 9) {
                    AppIcon(url: model.defaults[kind.id], size: 24)
                    Text(model.appName(model.defaults[kind.id])).font(.system(size: 12)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.vertical, 3)
            }.menuStyle(.borderlessButton).frame(width: 238).disabled(model.busy)
                .accessibilityLabel("\(kind.title)的默认应用：\(model.appName(model.defaults[kind.id]))")
        }.padding(.horizontal, 28).frame(height: 66)
    }
    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.title = "选择打开\(kind.title)的应用"
        panel.prompt = "设为默认应用"
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            if response == .OK, let url = panel.url { Task { @MainActor in await model.change(kind, to: url) } }
        }
    }
}

struct AppIcon: View {
    let url: URL?
    let size: CGFloat
    var body: some View {
        Group {
            if let url { Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().interpolation(.high) }
            else { Image(systemName: "app.dashed").resizable().scaledToFit().foregroundStyle(.tertiary).padding(3) }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("最近修改").font(.title2.bold())
                    Text("仅记录在 Openly 中完成的修改，保留最近 50 条。").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(24)
            Divider()
            if model.history.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 34)).foregroundStyle(.secondary)
                    Text("还没有修改记录").font(.headline)
                    Text("设置新的默认应用后，可以在这里撤销。").font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.history) { record in
                            HStack(spacing: 12) {
                                AppIcon(url: URL(fileURLWithPath: record.newPath), size: 30)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(record.title).font(.system(size: 12, weight: .semibold))
                                    Text("\(model.appName(record.oldPath.map { URL(fileURLWithPath: $0) })) → \(model.appName(URL(fileURLWithPath: record.newPath)))")
                                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                    Text(record.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10)).foregroundStyle(.tertiary)
                                }
                                Spacer()
                                if record.restoredAt != nil { Text("已撤销").font(.system(size: 11)).foregroundStyle(.secondary) }
                                else if record.oldPath == nil { Text("无原始应用").font(.system(size: 11)).foregroundStyle(.secondary) }
                                else { Button("撤销") { Task { await model.undo(record) } }.disabled(model.busy) }
                            }.padding(.horizontal, 24).padding(.vertical, 16)
                            Divider().padding(.leading, 66)
                        }
                    }
                }
            }
        }.frame(width: 580, height: 440)
            .alert("无法撤销", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("知道了", role: .cancel) { model.error = nil }
            } message: { Text(model.error ?? "") }
    }
}
