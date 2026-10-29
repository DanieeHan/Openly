import AppKit
import UniformTypeIdentifiers

enum FileGroup: String, CaseIterable, Identifiable {
    case all = "全部类型", documents = "文档", images = "图片", media = "影音", code = "代码与数据", other = "其他"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .documents: return "doc.text"
        case .images: return "photo"
        case .media: return "play.rectangle"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .other: return "square.stack.3d.up"
        }
    }
}

struct FileKind: Identifiable {
    let type: UTType
    var extensions: [String]
    let title: String
    let group: FileGroup
    var id: String { type.identifier }
    var subtitle: String { extensions.map { "." + $0 }.joined(separator: "  ") }

    static let seeds: [(String, String, FileGroup)] = [
        ("pdf", "PDF 文档", .documents), ("txt", "纯文本", .documents),
        ("md", "Markdown", .code), ("rtf", "富文本", .documents),
        ("docx", "Word 文档", .documents), ("xlsx", "Excel 表格", .documents),
        ("pptx", "PowerPoint 演示", .documents), ("epub", "电子书", .documents),
        ("pages", "Pages 文稿", .documents), ("csv", "CSV 表格", .code),
        ("jpg", "JPEG 图像", .images), ("jpeg", "JPEG 图像", .images),
        ("png", "PNG 图像", .images), ("gif", "GIF 图像", .images),
        ("heic", "HEIC 图像", .images), ("webp", "WebP 图像", .images),
        ("svg", "SVG 矢量图", .images), ("tiff", "TIFF 图像", .images),
        ("mp4", "MPEG-4 视频", .media), ("mov", "QuickTime 视频", .media),
        ("mkv", "Matroska 视频", .media), ("mp3", "MP3 音频", .media),
        ("m4a", "MPEG-4 音频", .media), ("wav", "WAV 音频", .media),
        ("flac", "FLAC 音频", .media), ("html", "HTML 网页文件", .code),
        ("htm", "HTML 网页文件", .code), ("json", "JSON 数据", .code),
        ("xml", "XML 文档", .code), ("yaml", "YAML 配置", .code),
        ("swift", "Swift 源代码", .code), ("py", "Python 脚本", .code),
        ("js", "JavaScript", .code), ("css", "CSS 样式", .code),
        ("zip", "ZIP 归档", .other), ("7z", "7-Zip 归档", .other)
    ]

    static func make(extra: [String] = [], overrides: [String: String] = [:]) -> [FileKind] {
        var result: [FileKind] = []
        var indices: [String: Int] = [:]
        for (ext, title, group) in seeds + extra.map({ ($0, $0.uppercased() + " 文件", FileGroup.other) }) {
            guard let type = overrides[ext].flatMap({ UTType($0) }) ?? UTType(filenameExtension: ext) else { continue }
            if let index = indices[type.identifier] {
                if !result[index].extensions.contains(ext) { result[index].extensions.append(ext) }
            } else {
                indices[type.identifier] = result.count
                result.append(FileKind(type: type, extensions: [ext], title: title, group: group))
            }
        }
        return result
    }
}

struct ChangeRecord: Codable, Identifiable {
    let id: UUID
    let typeID: String
    let title: String
    let oldPath: String?
    let newPath: String
    let date: Date
    var restoredAt: Date?
}

struct BatchFailure {
    let typeID: String
    let title: String
    let message: String
}

struct BatchResult {
    var changed = 0
    var unchanged = 0
    var failures: [BatchFailure] = []
}

protocol AssociationService {
    func current(_ type: UTType) -> URL?
    func candidates(_ type: UTType) -> [URL]
    func set(_ app: URL, for type: UTType) async throws
}

struct SystemAssociations: AssociationService {
    func current(_ type: UTType) -> URL? { NSWorkspace.shared.urlForApplication(toOpen: type) }
    func candidates(_ type: UTType) -> [URL] { NSWorkspace.shared.urlsForApplications(toOpen: type) }
    func set(_ app: URL, for type: UTType) async throws {
        try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type)
    }
}

enum AppFailure: LocalizedError {
    case invalidApp, unavailableType, changedElsewhere, verification
    var errorDescription: String? {
        switch self {
        case .invalidApp: return "找不到这个应用，请重新选择已安装的 .app。"
        case .unavailableType: return "系统无法识别这个文件类型。"
        case .changedElsewhere: return "此类型的默认应用已经再次改变。请刷新列表后手动选择，避免覆盖后来的设置。"
        case .verification: return "系统尚未返回预期的默认应用。请刷新确认后重试。"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var kinds: [FileKind] = []
    @Published var defaults: [String: URL] = [:]
    @Published var history: [ChangeRecord] = []
    @Published var query = "" { didSet { if query != oldValue { clearSelection() } } }
    @Published var group = FileGroup.all { didSet { if group != oldValue { clearSelection() } } }
    @Published private(set) var selectedIDs: Set<String> = []
    @Published var busy = false
    @Published var notice: String?
    @Published var error: String?
    private let service: AssociationService
    private let preferences: UserDefaults
    private var extra: [String]
    private var typeOverrides: [String: String]
    private let now: () -> Date
    private var lastRefresh: Date?
    private let names = NSCache<NSURL, NSString>()
    private let icons = NSCache<NSURL, NSImage>()
    private var selectionAnchor: String?

    init(service: AssociationService = SystemAssociations(), preferences: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.service = service
        self.preferences = preferences
        self.now = now
        names.countLimit = 128
        icons.countLimit = 32
        icons.totalCostLimit = 512 * 1024
        self.extra = preferences.stringArray(forKey: "customExtensions") ?? []
        self.typeOverrides = preferences.dictionary(forKey: "typeOverrides") as? [String: String] ?? [:]
        if let data = preferences.data(forKey: "history"), let saved = try? JSONDecoder().decode([ChangeRecord].self, from: data) { history = Array(saved.prefix(50)) }
        kinds = FileKind.make(extra: extra, overrides: typeOverrides)
        refresh()
    }

    var visible: [FileKind] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if term.isEmpty && group == .all { return kinds }
        return kinds.filter { kind in
            (group == .all || kind.group == group) && (term.isEmpty ||
                kind.title.localizedCaseInsensitiveContains(term) ||
                kind.subtitle.localizedCaseInsensitiveContains(term) ||
                kind.id.localizedCaseInsensitiveContains(term) ||
                appName(defaults[kind.id]).localizedCaseInsensitiveContains(term))
        }
    }
    var selectedKinds: [FileKind] { kinds.filter { selectedIDs.contains($0.id) } }

    func select(_ kind: FileKind, extending: Bool = false, toggling: Bool = false) {
        guard !busy else { return }
        let rows = visible
        guard let index = rows.firstIndex(where: { $0.id == kind.id }) else { return }
        if extending, let anchor = selectionAnchor, let start = rows.firstIndex(where: { $0.id == anchor }) {
            let range = Set(rows[min(start, index)...max(start, index)].map(\.id))
            selectedIDs = toggling ? selectedIDs.union(range) : range
        } else {
            if toggling {
                if selectedIDs.contains(kind.id) { selectedIDs.remove(kind.id) }
                else { selectedIDs.insert(kind.id) }
            } else { selectedIDs = [kind.id] }
            selectionAnchor = kind.id
        }
    }
    func selectAllVisible() {
        guard !busy else { return }
        let rows = visible
        selectedIDs = Set(rows.map(\.id))
        selectionAnchor = rows.first?.id
    }
    func clearSelection() {
        // Query/category changes may also clear selection during a pending write;
        // the write itself always holds an immutable snapshot of its target kinds.
        if !selectedIDs.isEmpty { selectedIDs.removeAll() }
        selectionAnchor = nil
    }
    func refresh() {
        names.removeAllObjects()
        let updated = Dictionary(uniqueKeysWithValues: kinds.compactMap { kind in service.current(kind.type).map { (kind.id, $0) } })
        // Do not invalidate every visible row when nothing changed.
        if updated != defaults { defaults = updated }
        pruneSelection()
        lastRefresh = now()
    }
    func refreshIfNeeded() {
        guard !busy else { return }
        guard lastRefresh.map({ now().timeIntervalSince($0) >= 1 }) ?? true else { return }
        refresh()
    }
    @discardableResult
    private func refresh(_ type: UTType) -> URL? {
        let updated = service.current(type)
        if defaults[type.identifier] != updated { defaults[type.identifier] = updated }
        return updated
    }
    private func pruneSelection() {
        guard !selectedIDs.isEmpty else { return }
        let remaining = selectedIDs.intersection(visible.map(\.id))
        if remaining != selectedIDs { selectedIDs = remaining }
        if let anchor = selectionAnchor, !remaining.contains(anchor) { selectionAnchor = nil }
    }
    func apps(for kind: FileKind) -> [URL] {
        var seen = Set<String>()
        return ((defaults[kind.id].map { [$0] } ?? []) + service.candidates(kind.type))
            .filter { $0.standardizedFileURL != Bundle.main.bundleURL.standardizedFileURL && seen.insert($0.path).inserted }
    }
    func commonApps(for kinds: [FileKind]) -> [URL] {
        guard let first = kinds.first else { return [] }
        let ordered = apps(for: first)
        var common = Set(ordered.map { $0.standardizedFileURL })
        var seen: Set<String> = [first.id]
        for kind in kinds.dropFirst() where seen.insert(kind.id).inserted {
            common.formIntersection(apps(for: kind).map { $0.standardizedFileURL })
            if common.isEmpty { break }
        }
        return ordered.filter { common.contains($0.standardizedFileURL) }
    }
    func appName(_ url: URL?) -> String {
        guard let url else { return "尚未设置" }
        if let name = names.object(forKey: url as NSURL) { return name as String }
        let displayed = FileManager.default.displayName(atPath: url.path)
        let name = displayed.hasSuffix(".app") ? String(displayed.dropLast(4)) : displayed
        names.setObject(name as NSString, forKey: url as NSURL)
        return name
    }
    func icon(for url: URL?) -> NSImage? {
        guard let url else { return nil }
        if let image = icons.object(forKey: url as NSURL) { return image }
        // Rasterize a small representation, rather than retaining full app artwork per row.
        return autoreleasepool {
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 256, bitsPerPixel: 32),
                let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSWorkspace.shared.icon(forFile: url.path).draw(in: NSRect(x: 0, y: 0, width: 64, height: 64),
                from: .zero, operation: .copy, fraction: 1, respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            NSGraphicsContext.restoreGraphicsState()
            bitmap.size = NSSize(width: 32, height: 32)
            let image = NSImage(size: bitmap.size)
            image.addRepresentation(bitmap)
            icons.setObject(image, forKey: url as NSURL, cost: bitmap.bytesPerRow * bitmap.pixelsHigh)
            return image
        }
    }
    func addExtension(_ input: String) {
        guard !busy else { return }
        let ext = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !ext.isEmpty, ext.count <= 40, ext.rangeOfCharacter(from: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-+")).inverted) == nil,
              let type = UTType(filenameExtension: ext) else {
            error = "请输入有效扩展名，例如 pdf、md 或 mkv。"; return
        }
        if !kinds.contains(where: { $0.extensions.contains(ext) }) {
            let existingIDs = Set(kinds.map(\.id))
            extra.append(ext)
            preferences.set(extra, forKey: "customExtensions")
            kinds = FileKind.make(extra: extra, overrides: typeOverrides)
            for kind in kinds where !existingIDs.contains(kind.id) { refresh(kind.type) }
        }
        group = .all
        query = "." + ext
        notice = "已定位 .\(ext) · \(type.localizedDescription ?? type.identifier)"
    }
    func importFile(_ url: URL) {
        guard !busy else { return }
        do {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey])
            guard values.isDirectory != true, !url.pathExtension.isEmpty else {
                error = "请拖入带有扩展名的文件，文件夹和应用不适用。"; return
            }
            // Ask the file itself: its actual type can differ from a simple extension lookup.
            guard let actualType = values.contentType else { throw AppFailure.unavailableType }
            typeOverrides[url.pathExtension.lowercased()] = actualType.identifier
            preferences.set(typeOverrides, forKey: "typeOverrides")
            addExtension(url.pathExtension)
            kinds = FileKind.make(extra: extra, overrides: typeOverrides)
            clearSelection()
            let validIDs = Set(kinds.map(\.id))
            defaults = defaults.filter { validIDs.contains($0.key) }
            refresh(actualType)
        } catch { self.error = error.localizedDescription }
    }
    func change(_ kind: FileKind, to app: URL) async {
        guard !busy else { return }
        busy = true
        error = nil
        notice = nil
        let historyHead = history.first?.id
        defer {
            if history.first?.id != historyHead { saveHistory() }
            pruneSelection()
            busy = false
        }
        do {
            try validateApp(app)
            let changed = try await applyChange(kind, to: app)
            notice = changed ? "\(kind.subtitle) → \(appName(app))" : "已经使用 \(appName(app)) 打开"
        } catch { self.error = error.localizedDescription; refresh(kind.type) }
    }
    @discardableResult
    func change(_ kinds: [FileKind], to app: URL) async -> BatchResult? {
        guard !busy else { return nil }
        var seen = Set<String>()
        let targets = kinds.filter { seen.insert($0.id).inserted }
        guard !targets.isEmpty else { return nil }
        busy = true
        error = nil
        notice = nil
        let historyHead = history.first?.id
        defer {
            if history.first?.id != historyHead { saveHistory() }
            clearSelection()
            busy = false
        }
        var result = BatchResult()
        do { try validateApp(app) }
        catch {
            self.error = error.localizedDescription
            result.failures = targets.map { BatchFailure(typeID: $0.id, title: $0.title, message: error.localizedDescription) }
            return result
        }
        // macOS sets defaults per UTType, so a batch can partially fail or ask
        // for consent more than once. Never pretend that this is an atomic write.
        for kind in targets {
            do {
                if try await applyChange(kind, to: app) { result.changed += 1 }
                else { result.unchanged += 1 }
            } catch {
                result.failures.append(BatchFailure(typeID: kind.id, title: kind.title, message: error.localizedDescription))
                refresh(kind.type)
            }
        }
        var summary = "已更改 \(result.changed) 种类型"
        if result.unchanged > 0 { summary += " · \(result.unchanged) 种无需更改" }
        if !result.failures.isEmpty {
            summary += " · \(result.failures.count) 种失败"
            let details = result.failures.prefix(8).map { "\($0.title)：\($0.message)" }.joined(separator: "\n")
            self.error = "\(summary)\n\n\(details)" + (result.failures.count > 8 ? "\n另有 \(result.failures.count - 8) 种类型未完成。" : "")
        }
        notice = summary
        return result
    }
    private func applyChange(_ kind: FileKind, to app: URL) async throws -> Bool {
        let old = service.current(kind.type)
        if old?.standardizedFileURL == app.standardizedFileURL {
            if defaults[kind.id] != old { defaults[kind.id] = old }
            return false
        }
        try await service.set(app, for: kind.type)
        // Accepted writes retain a recovery record even if verification fails.
        history.insert(ChangeRecord(id: UUID(), typeID: kind.id, title: kind.title,
            oldPath: old?.path, newPath: app.path, date: Date()), at: 0)
        if history.count > 50 { history.removeLast(history.count - 50) }
        guard refresh(kind.type)?.standardizedFileURL == app.standardizedFileURL else { throw AppFailure.verification }
        return true
    }
    func undo(_ record: ChangeRecord) async {
        guard !busy, record.restoredAt == nil, let oldPath = record.oldPath else { return }
        busy = true
        error = nil
        notice = nil
        defer { pruneSelection(); busy = false }
        do {
            guard let type = UTType(record.typeID) else { throw AppFailure.unavailableType }
            let old = URL(fileURLWithPath: oldPath)
            try validateApp(old)
            guard service.current(type)?.standardizedFileURL == URL(fileURLWithPath: record.newPath).standardizedFileURL else { throw AppFailure.changedElsewhere }
            try await service.set(old, for: type)
            guard refresh(type)?.standardizedFileURL == old.standardizedFileURL else { throw AppFailure.verification }
            if let index = history.firstIndex(where: { $0.id == record.id }) { history[index].restoredAt = Date() }
            saveHistory()
            notice = "已恢复 \(record.title) 的默认应用"
        } catch {
            self.error = error.localizedDescription
            if let type = UTType(record.typeID) { refresh(type) }
        }
    }
    private func validateApp(_ url: URL) throws {
        guard url.pathExtension == "app", FileManager.default.fileExists(atPath: url.path), Bundle(url: url)?.bundleIdentifier != nil else { throw AppFailure.invalidApp }
    }
    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) { preferences.set(data, forKey: "history") }
    }
}
