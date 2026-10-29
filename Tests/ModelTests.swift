import AppKit
import UniformTypeIdentifiers

final class FakeAssociations: AssociationService {
    var values: [String: URL] = [:]
    var shouldFail = false
    func current(_ type: UTType) -> URL? { values[type.identifier] }
    func candidates(_ type: UTType) -> [URL] { [] }
    func set(_ app: URL, for type: UTType) async throws {
        if shouldFail { throw AppFailure.verification }
        values[type.identifier] = app
    }
}

@main
struct ModelTests {
    @MainActor static func main() async throws {
        let suite = "com.openly.tests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let service = FakeAssociations()
        let preview = URL(fileURLWithPath: "/System/Applications/Preview.app")
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        let third = URL(fileURLWithPath: "/System/Applications/Notes.app")
        let model = AppModel(service: service, preferences: preferences)
        let pdf = model.kinds.first { $0.extensions.contains("pdf") }!
        service.values[pdf.id] = preview
        model.refresh()
        assert(model.defaults[pdf.id] == preview)
        assert(Set(model.kinds.map(\.id)).count == model.kinds.count)
        let jpeg = model.kinds.first { $0.extensions.contains("jpg") }!
        assert(jpeg.extensions.contains("jpeg"))
        model.query = ".pdf"
        assert(model.visible.count == 1)
        model.query = "Preview"
        assert(model.visible.contains { $0.id == pdf.id })
        model.query = ""
        model.group = .images
        assert(model.visible.allSatisfy { $0.group == .images })
        model.addExtension(".PSD")
        assert(model.kinds.contains { $0.extensions.contains("psd") })
        model.addExtension("../bad")
        assert(model.error != nil)
        model.error = nil
        await model.change(pdf, to: textEdit)
        assert(model.error == nil && model.history.count == 1)
        assert(model.defaults[pdf.id] == textEdit && !model.busy)
        let reloaded = AppModel(service: service, preferences: preferences)
        assert(reloaded.history.count == 1 && reloaded.kinds.contains { $0.extensions.contains("psd") })
        await model.change(pdf, to: textEdit)
        assert(model.history.count == 1)
        service.values[pdf.id] = third
        await model.undo(model.history[0])
        assert(model.error != nil && service.values[pdf.id] == third)
        model.error = nil
        service.values[pdf.id] = textEdit
        await model.undo(model.history[0])
        assert(model.error == nil && service.values[pdf.id] == preview && model.history[0].restoredAt != nil)
        service.shouldFail = true
        await model.change(pdf, to: textEdit)
        assert(model.error != nil && model.history.count == 1 && !model.busy)
        model.error = nil
        service.shouldFail = false
        await model.change(pdf, to: URL(fileURLWithPath: "/missing.app"))
        assert(model.error != nil && model.history.count == 1)
        model.error = nil
        let sample = FileManager.default.temporaryDirectory.appendingPathComponent("Openly-test-" + UUID().uuidString + ".txt")
        try "test".write(to: sample, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: sample) }
        model.importFile(sample)
        assert(model.error == nil && model.visible.contains { $0.extensions.contains("txt") })
        let afterImport = AppModel(service: service, preferences: preferences)
        assert(afterImport.kinds.contains { $0.extensions.contains("txt") })
        model.importFile(FileManager.default.temporaryDirectory)
        assert(model.error != nil)
        let real = SystemAssociations()
        let actual = real.current(.pdf)
        print("PASS: type grouping, search, filters, custom types, persistence, successful change, no-op, undo, external-change protection, failure paths")
        print("READ-ONLY system check: PDF = \(actual?.lastPathComponent ?? "none"), candidates = \(real.candidates(.pdf).count)")
        print("No system defaults were modified by these tests.")
    }
}
