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
        for (ext, title, group) in seeds + extra.map({ ($0, $0.uppercased() + " 文件", FileGroup.other) }) {
            guard let type = overrides[ext].flatMap({ UTType($0) }) ?? UTType(filenameExtension: ext) else { continue }
            if let index = result.firstIndex(where: { $0.id == type.identifier }) {
                if !result[index].extensions.contains(ext) { result[index].extensions.append(ext) }
            } else {
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
    @Published var query = ""
    @Published var group = FileGroup.all
    @Published var busy = false
    @Published var notice: String?
    @Published var error: String?
    private let service: AssociationService
    private let preferences: UserDefaults
    private var extra: [String]
    private var typeOverrides: [String: String]

    init(service: AssociationService = SystemAssociations(), preferences: UserDefaults = .standard) {
        self.service = service
        self.preferences = preferences
        self.extra = preferences.stringArray(forKey: "customExtensions") ?? []
        self.typeOverrides = preferences.dictionary(forKey: "typeOverrides") as? [String: String] ?? [:]
        if let data = preferences.data(forKey: "history"), let saved = try? JSONDecoder().decode([ChangeRecord].self, from: data) { history = saved }
        kinds = FileKind.make(extra: extra, overrides: typeOverrides)
        refresh()
    }

    var visible: [FileKind] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return kinds.filter { kind in
            (group == .all || kind.group == group) && (term.isEmpty ||
                [kind.title, kind.subtitle, kind.id, appName(defaults[kind.id])].contains { $0.localizedCaseInsensitiveContains(term) })
        }
    }
    func refresh() {
        defaults = Dictionary(uniqueKeysWithValues: kinds.compactMap { kind in service.current(kind.type).map { (kind.id, $0) } })
    }
    func apps(for kind: FileKind) -> [URL] {
        var seen = Set<String>()
        return ((defaults[kind.id].map { [$0] } ?? []) + service.candidates(kind.type))
            .filter { $0.standardizedFileURL != Bundle.main.bundleURL.standardizedFileURL && seen.insert($0.path).inserted }
    }
    func appName(_ url: URL?) -> String {
        guard let url else { return "尚未设置" }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
    func addExtension(_ input: String) {
        let ext = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !ext.isEmpty, ext.count <= 40, ext.rangeOfCharacter(from: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-+")).inverted) == nil,
              let type = UTType(filenameExtension: ext) else {
            error = "请输入有效扩展名，例如 pdf、md 或 mkv。"; return
        }
        if !extra.contains(ext) { extra.append(ext); preferences.set(extra, forKey: "customExtensions") }
        kinds = FileKind.make(extra: extra, overrides: typeOverrides)
        group = .all
        query = "." + ext
        refresh()
        notice = "已定位 .\(ext) · \(type.localizedDescription ?? type.identifier)"
    }
    func importFile(_ url: URL) {
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
        } catch { self.error = error.localizedDescription }
    }
    func change(_ kind: FileKind, to app: URL) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            try validateApp(app)
            let old = service.current(kind.type)
            guard old?.standardizedFileURL != app.standardizedFileURL else { notice = "已经使用 \(appName(app)) 打开"; return }
            try await service.set(app, for: kind.type)
            // Keep a recovery record even if post-write verification is inconclusive.
            history.insert(ChangeRecord(id: UUID(), typeID: kind.id, title: kind.title, oldPath: old?.path, newPath: app.path, date: Date()), at: 0)
            history = Array(history.prefix(50))
            saveHistory()
            refresh()
            guard defaults[kind.id]?.standardizedFileURL == app.standardizedFileURL else { throw AppFailure.verification }
            notice = "\(kind.subtitle) → \(appName(app))"
        } catch { self.error = error.localizedDescription; refresh() }
    }
    func undo(_ record: ChangeRecord) async {
        guard !busy, record.restoredAt == nil, let oldPath = record.oldPath else { return }
        busy = true
        defer { busy = false }
        do {
            guard let type = UTType(record.typeID) else { throw AppFailure.unavailableType }
            let old = URL(fileURLWithPath: oldPath)
            try validateApp(old)
            guard service.current(type)?.standardizedFileURL == URL(fileURLWithPath: record.newPath).standardizedFileURL else { throw AppFailure.changedElsewhere }
            try await service.set(old, for: type)
            guard service.current(type)?.standardizedFileURL == old.standardizedFileURL else { throw AppFailure.verification }
            if let index = history.firstIndex(where: { $0.id == record.id }) { history[index].restoredAt = Date() }
            saveHistory()
            refresh()
            notice = "已恢复 \(record.title) 的默认应用"
        } catch { self.error = error.localizedDescription; refresh() }
    }
    private func validateApp(_ url: URL) throws {
        guard url.pathExtension == "app", FileManager.default.fileExists(atPath: url.path), Bundle(url: url)?.bundleIdentifier != nil else { throw AppFailure.invalidApp }
    }
    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) { preferences.set(data, forKey: "history") }
    }
}
