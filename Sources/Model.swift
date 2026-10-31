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
    var batchID: UUID? = nil
    var pending: Bool? = nil
    var operationID: UUID { batchID ?? id }
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
    var unprocessed = 0
    var stopped = false
}

struct BatchProgress {
    let completed: Int
    let total: Int
    let currentTitle: String
    let isUndo: Bool
}

struct BatchReport: Identifiable {
    let id: UUID
    let result: BatchResult
    let isUndo: Bool
    let summary: String
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
    case invalidApp, unavailableType, changedElsewhere, verification, noPreviousApp
    var errorDescription: String? {
        switch self {
        case .invalidApp: return "找不到这个应用，请重新选择已安装的 .app。"
        case .unavailableType: return "系统无法识别这个文件类型。"
        case .changedElsewhere: return "此类型的默认应用已经再次改变。请刷新列表后手动选择，避免覆盖后来的设置。"
        case .verification: return "系统尚未返回预期的默认应用。请刷新确认后重试。"
        case .noPreviousApp: return "这项修改原本没有默认应用，无法自动恢复。"
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
    @Published private(set) var progress: BatchProgress?
    @Published private(set) var stopRequested = false
    @Published private(set) var batchReport: BatchReport?
    private let service: AssociationService
    private let preferences: UserDefaults
    private var extra: [String]
    private var typeOverrides: [String: String]
    private let now: () -> Date
    private var lastRefresh: Date?
    private let names = NSCache<NSURL, NSString>()
    private let icons = NSCache<NSURL, NSImage>()
    private var selectionAnchor: String?
    private enum RetryContext {
        case change([FileKind], URL, UUID)
        case undo([UUID])
    }
    private var retryContext: RetryContext?
    var canRetryBatch: Bool { retryContext != nil && !busy }

    init(service: AssociationService = SystemAssociations(), preferences: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.service = service
        self.preferences = preferences
        self.now = now
        names.countLimit = 128
        icons.countLimit = 32
        icons.totalCostLimit = 512 * 1024
        self.extra = preferences.stringArray(forKey: "customExtensions") ?? []
        let storedOverrides = preferences.dictionary(forKey: "typeOverrides") as? [String: String] ?? [:]
        self.typeOverrides = storedOverrides.filter { !Self.isLinkType($0.value) }
        if typeOverrides != storedOverrides { preferences.set(typeOverrides, forKey: "typeOverrides") }
        if let data = preferences.data(forKey: "history"), let saved = try? JSONDecoder().decode([ChangeRecord].self, from: data) {
            history = Self.recentOperations(saved)
        }
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
    private static func validExtension(_ input: String) -> String? {
        let ext = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !ext.isEmpty, ext.count <= 40,
            ext.rangeOfCharacter(from: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-+")).inverted) == nil,
            UTType(filenameExtension: ext) != nil else { return nil }
        return ext
    }
    private static func isLinkType(_ identifier: String) -> Bool {
        identifier == "public.symlink" || identifier == "com.apple.alias-file"
    }
    func addExtension(_ input: String) {
        guard !busy else { return }
        guard let ext = Self.validExtension(input), let type = UTType(filenameExtension: ext) else {
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
            guard url.isFileURL else { throw AppFailure.unavailableType }
            // A link's extension and content type describe the link, not its target.
            let target = url.resolvingSymlinksInPath()
            let values = try target.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .contentTypeKey, .isSymbolicLinkKey, .isAliasFileKey])
            guard values.isRegularFile == true, values.isDirectory != true,
                values.isSymbolicLink != true, values.isAliasFile != true,
                let ext = Self.validExtension(target.pathExtension) else {
                error = "请拖入带有有效扩展名的文件，文件夹、应用和无效链接不适用。"; return
            }
            guard let actualType = values.contentType, !Self.isLinkType(actualType.identifier) else { throw AppFailure.unavailableType }
            // Validate everything before committing either preference.
            if !kinds.contains(where: { $0.extensions.contains(ext) }) { extra.append(ext) }
            typeOverrides[ext] = actualType.identifier
            preferences.set(extra, forKey: "customExtensions")
            preferences.set(typeOverrides, forKey: "typeOverrides")
            kinds = FileKind.make(extra: extra, overrides: typeOverrides)
            clearSelection()
            let validIDs = Set(kinds.map(\.id))
            defaults = defaults.filter { validIDs.contains($0.key) }
            refresh(actualType)
            group = .all
            query = "." + ext
            notice = "已定位 .\(ext) · \(actualType.localizedDescription ?? actualType.identifier)"
        } catch { self.error = error.localizedDescription }
    }
    func requestStop() {
        guard busy, progress != nil else { return }
        stopRequested = true
    }
    func dismissBatchReport() {
        batchReport = nil
        retryContext = nil
    }
    private func beginOperation() {
        busy = true
        error = nil
        notice = nil
        batchReport = nil
        retryContext = nil
        stopRequested = false
    }
    private func finishOperation() {
        progress = nil
        stopRequested = false
        busy = false
    }
    func change(_ kind: FileKind, to app: URL) async {
        guard !busy else { return }
        beginOperation()
        defer { pruneSelection(); finishOperation() }
        do {
            try validateApp(app)
            let changed = try await applyChange(kind, to: app, batchID: nil)
            notice = changed ? "\(kind.subtitle) → \(appName(app))" : "已经使用 \(appName(app)) 打开"
        } catch { self.error = error.localizedDescription; refresh(kind.type) }
    }
    @discardableResult
    func change(_ kinds: [FileKind], to app: URL) async -> BatchResult? {
        guard !busy else { return nil }
        return await changeBatch(kinds, to: app, batchID: UUID())
    }
    private func changeBatch(_ kinds: [FileKind], to app: URL, batchID: UUID) async -> BatchResult? {
        var seen = Set<String>()
        let targets = kinds.filter { seen.insert($0.id).inserted }
        guard !targets.isEmpty else { return nil }
        beginOperation()
        defer { finishOperation() }
        var result = BatchResult()
        var retry: [FileKind] = []
        do { try validateApp(app) }
        catch {
            result.failures = targets.map { BatchFailure(typeID: $0.id, title: $0.title, message: error.localizedDescription) }
            retry = targets
            completeBatch(result, isUndo: false, retry: .change(retry, app, batchID), selected: retry)
            return result
        }
        for (index, kind) in targets.enumerated() {
            if stopRequested || Task.isCancelled {
                result.stopped = true
                result.unprocessed = targets.count - index
                retry.append(contentsOf: targets[index...])
                break
            }
            progress = BatchProgress(completed: index, total: targets.count, currentTitle: kind.title, isUndo: false)
            do {
                if try await applyChange(kind, to: app, batchID: batchID) { result.changed += 1 }
                else { result.unchanged += 1 }
            } catch {
                result.failures.append(BatchFailure(typeID: kind.id, title: kind.title, message: error.localizedDescription))
                retry.append(kind)
                refresh(kind.type)
                if Self.isCancellation(error) { stopRequested = true; result.stopped = true }
            }
            progress = BatchProgress(completed: index + 1, total: targets.count, currentTitle: kind.title, isUndo: false)
        }
        completeBatch(result, isUndo: false, retry: retry.isEmpty ? nil : .change(retry, app, batchID), selected: retry)
        return result
    }
    func retryBatch() async {
        guard !busy, let context = retryContext else { return }
        switch context {
        case let .change(kinds, app, batchID): _ = await changeBatch(kinds, to: app, batchID: batchID)
        case let .undo(ids): await restoreBatch(ids)
        }
    }
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let failure = error as NSError
        return (failure.domain == NSCocoaErrorDomain && failure.code == NSUserCancelledError) ||
            (failure.domain == NSOSStatusErrorDomain && failure.code == -128)
    }
    private func completeBatch(_ result: BatchResult, isUndo: Bool, retry: RetryContext?, selected: [FileKind] = []) {
        var summary = "已\(isUndo ? "恢复" : "更改") \(result.changed) 种类型"
        if result.unchanged > 0 { summary += " · \(result.unchanged) 种无需更改" }
        if !result.failures.isEmpty { summary += " · \(result.failures.count) 种失败" }
        if result.unprocessed > 0 { summary += " · \(result.unprocessed) 种未处理" }
        if result.stopped { summary = "已停止 · " + summary }
        notice = summary
        retryContext = retry
        batchReport = BatchReport(id: UUID(), result: result, isUndo: isUndo, summary: summary)
        // The retry snapshot also retains items hidden by an app-name filter.
        selectedIDs = Set(selected.map(\.id)).intersection(visible.map(\.id))
        selectionAnchor = nil
    }
    private func applyChange(_ kind: FileKind, to app: URL, batchID: UUID?) async throws -> Bool {
        let old = service.current(kind.type)
        if old?.standardizedFileURL == app.standardizedFileURL {
            if defaults[kind.id] != old { defaults[kind.id] = old }
            return false
        }
        let record = ChangeRecord(id: UUID(), typeID: kind.id, title: kind.title,
            oldPath: old?.path, newPath: app.path, date: now(), batchID: batchID, pending: true)
        history.insert(record, at: 0)
        // Save before crossing the asynchronous system boundary. A pending record
        // remains recoverable even if the app exits before the callback arrives.
        saveHistory()
        do { try await service.set(app, for: kind.type) }
        catch {
            if Self.isCancellation(error), progress != nil { stopRequested = true }
            let current = refresh(kind.type)
            if current?.standardizedFileURL == app.standardizedFileURL {
                confirmChange(record.id)
                return true
            }
            if current?.standardizedFileURL == old?.standardizedFileURL {
                history.removeAll { $0.id == record.id }
            }
            history = Self.recentOperations(history)
            saveHistory()
            throw error
        }
        guard refresh(kind.type)?.standardizedFileURL == app.standardizedFileURL else {
            history = Self.recentOperations(history)
            saveHistory()
            throw AppFailure.verification
        }
        confirmChange(record.id)
        return true
    }
    private func confirmChange(_ id: UUID) {
        if let index = history.firstIndex(where: { $0.id == id }) { history[index].pending = false }
        history = Self.recentOperations(history)
        saveHistory()
    }
    func undo(_ record: ChangeRecord) async {
        guard !busy, record.restoredAt == nil, record.oldPath != nil else { return }
        beginOperation()
        defer { pruneSelection(); finishOperation() }
        do {
            _ = try await restore(record)
            notice = "已恢复 \(record.title) 的默认应用"
        } catch {
            self.error = error.localizedDescription
            if let type = UTType(record.typeID) { refresh(type) }
        }
    }
    func undoBatch(_ batchID: UUID) async {
        guard !busy else { return }
        let ids = history.filter { $0.batchID == batchID && $0.restoredAt == nil }.map(\.id)
        await restoreBatch(ids)
    }
    private func restoreBatch(_ ids: [UUID]) async {
        let targets = ids.compactMap { id in history.first { $0.id == id && $0.restoredAt == nil } }
        guard !targets.isEmpty else { return }
        beginOperation()
        defer { pruneSelection(); finishOperation() }
        var result = BatchResult()
        var retry: [UUID] = []
        for (index, record) in targets.enumerated() {
            if stopRequested || Task.isCancelled {
                result.stopped = true
                result.unprocessed = targets.count - index
                retry.append(contentsOf: targets[index...].map(\.id))
                break
            }
            progress = BatchProgress(completed: index, total: targets.count, currentTitle: record.title, isUndo: true)
            do {
                if try await restore(record) { result.changed += 1 }
                else { result.unchanged += 1 }
            } catch {
                result.failures.append(BatchFailure(typeID: record.typeID, title: record.title, message: error.localizedDescription))
                retry.append(record.id)
                if let type = UTType(record.typeID) { refresh(type) }
                if Self.isCancellation(error) { stopRequested = true; result.stopped = true }
            }
            progress = BatchProgress(completed: index + 1, total: targets.count, currentTitle: record.title, isUndo: true)
        }
        completeBatch(result, isUndo: true, retry: retry.isEmpty ? nil : .undo(retry))
    }
    private func restore(_ record: ChangeRecord) async throws -> Bool {
        guard let oldPath = record.oldPath else { throw AppFailure.noPreviousApp }
        guard let type = UTType(record.typeID) else { throw AppFailure.unavailableType }
        let old = URL(fileURLWithPath: oldPath)
        try validateApp(old)
        let current = service.current(type)?.standardizedFileURL
        // An interrupted write or undo can already be back at the original app.
        if record.pending == true && current == old.standardizedFileURL {
            markRestored(record.id)
            refresh(type)
            return false
        }
        guard current == URL(fileURLWithPath: record.newPath).standardizedFileURL else { throw AppFailure.changedElsewhere }
        if let index = history.firstIndex(where: { $0.id == record.id }) { history[index].pending = true }
        saveHistory()
        do { try await service.set(old, for: type) }
        catch {
            if Self.isCancellation(error), progress != nil { stopRequested = true }
            let updated = refresh(type)?.standardizedFileURL
            if updated == old.standardizedFileURL {
                markRestored(record.id)
                return true
            }
            if updated == current, let index = history.firstIndex(where: { $0.id == record.id }) {
                history[index].pending = record.pending
                saveHistory()
            }
            throw error
        }
        guard refresh(type)?.standardizedFileURL == old.standardizedFileURL else { throw AppFailure.verification }
        markRestored(record.id)
        return true
    }
    private func markRestored(_ id: UUID) {
        if let index = history.firstIndex(where: { $0.id == id }) {
            history[index].restoredAt = now()
            history[index].pending = false
        }
        saveHistory()
    }
    private static func recentOperations(_ records: [ChangeRecord]) -> [ChangeRecord] {
        var groups = Set<UUID>()
        return records.filter { record in
            if groups.contains(record.operationID) { return true }
            guard groups.count < 50 else { return false }
            groups.insert(record.operationID)
            return true
        }
    }
    private func validateApp(_ url: URL) throws {
        guard url.pathExtension == "app", FileManager.default.fileExists(atPath: url.path), Bundle(url: url)?.bundleIdentifier != nil else { throw AppFailure.invalidApp }
    }
    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) { preferences.set(data, forKey: "history") }
    }
}
