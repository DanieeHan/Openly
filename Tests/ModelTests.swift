import AppKit
import UniformTypeIdentifiers
import Combine

final class FakeAssociations: AssociationService {
    var values: [String: URL] = [:]
    var shouldFail = false
    var reads = 0
    var candidateReads = 0
    var available: [URL] = []
    var availableByType: [String: [URL]] = [:]
    var failedTypes: Set<String> = []
    var noEffectTypes: Set<String> = []
    var writes: [String] = []
    var beforeSet: (@MainActor () async -> Void)?
    func current(_ type: UTType) -> URL? { reads += 1; return values[type.identifier] }
    func candidates(_ type: UTType) -> [URL] { candidateReads += 1; return availableByType[type.identifier] ?? available }
    func set(_ app: URL, for type: UTType) async throws {
        writes.append(type.identifier)
        if let beforeSet { await beforeSet() }
        if shouldFail || failedTypes.contains(type.identifier) { throw AppFailure.verification }
        if !noEffectTypes.contains(type.identifier) { values[type.identifier] = app }
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
        var clock = Date()
        let model = AppModel(service: service, preferences: preferences, now: { clock })
        let initialReads = service.reads
        model.refreshIfNeeded()
        assert(service.reads == initialReads, "Startup activation must not query all types twice")
        clock.addTimeInterval(6)
        model.refreshIfNeeded()
        assert(service.reads == initialReads * 2)
        let pdf = model.kinds.first { $0.extensions.contains("pdf") }!
        service.values[pdf.id] = preview
        model.refresh()
        assert(model.defaults[pdf.id] == preview)
        var publications = 0
        let observer = model.$defaults.dropFirst().sink { _ in publications += 1 }
        model.refresh()
        assert(publications == 0, "Unchanged defaults must not redraw all rows")
        assert(Set(model.kinds.map(\.id)).count == model.kinds.count)
        let jpeg = model.kinds.first { $0.extensions.contains("jpg") }!
        assert(jpeg.extensions.contains("jpeg"))
        model.query = ".pdf"
        assert(model.visible.count == 1)
        model.query = "Preview"
        assert(model.visible.contains { $0.id == pdf.id })
        assert(service.candidateReads == 0, "Search must never enumerate application candidates")
        service.available = [preview, preview, textEdit]
        assert(model.apps(for: pdf).count == 2 && service.candidateReads == 1)
        let image = model.icon(for: preview)!
        assert(image === model.icon(for: preview), "Reuse one thumbnail for repeated apps")
        assert(image.representations.count == 1)
        assert(image.representations[0].pixelsWide == 64 && image.representations[0].pixelsHigh == 64)
        model.query = ""
        model.group = .images
        assert(model.visible.allSatisfy { $0.group == .images })
        model.addExtension(".PSD")
        assert(model.kinds.contains { $0.extensions.contains("psd") })
        model.addExtension("../bad")
        assert(model.error != nil)
        model.error = nil
        let readsBeforeChange = service.reads
        await model.change(pdf, to: textEdit)
        assert(service.reads == readsBeforeChange + 2, "A change only needs the old default and one verification")
        assert(model.error == nil && model.history.count == 1)
        assert(model.defaults[pdf.id] == textEdit && !model.busy)
        let reloaded = AppModel(service: service, preferences: preferences)
        assert(reloaded.history.count == 1 && reloaded.kinds.contains { $0.extensions.contains("psd") })
        await model.change(pdf, to: textEdit)
        assert(model.history.count == 1)
        service.values[pdf.id] = preview
        await model.change(pdf, to: preview)
        assert(model.defaults[pdf.id] == preview && model.history.count == 1, "A no-op must still correct stale display state")
        service.values[pdf.id] = textEdit
        model.refresh()
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
        observer.cancel()
        try await batchTests()
        print("PASS: grouping, search, filters, persistence, change/undo, external-change protection, failure paths, file import")
        print("PASS: refresh coalescing, unchanged-publication suppression, lazy candidates, bounded-size thumbnail reuse, targeted verification")
        print("READ-ONLY system check: PDF = \(actual?.lastPathComponent ?? "none"), candidates = \(real.candidates(.pdf).count)")
        print("No system defaults were modified by these tests.")
    }

    @MainActor static func batchTests() async throws {
        let suite = "com.openly.batch-tests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let service = FakeAssociations()
        let model = AppModel(service: service, preferences: preferences)
        let preview = URL(fileURLWithPath: "/System/Applications/Preview.app")
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        let notes = URL(fileURLWithPath: "/System/Applications/Notes.app")
        let pdf = model.kinds.first { $0.extensions.contains("pdf") }!
        let txt = model.kinds.first { $0.extensions.contains("txt") }!
        let jpeg = model.kinds.first { $0.extensions.contains("jpg") }!
        let rows = model.visible
        model.select(rows[0])
        model.select(rows[2], extending: true)
        assert(model.selectedIDs == Set(rows[0...2].map(\.id)))
        model.select(rows[1], extending: true)
        assert(model.selectedIDs == Set(rows[0...1].map(\.id)), "Repeated Shift-click keeps the original anchor")
        model.select(rows[3])
        model.select(rows[1], extending: true)
        assert(model.selectedIDs == Set(rows[1...3].map(\.id)))
        model.select(rows[0], toggling: true)
        assert(model.selectedIDs.count == 4)
        model.select(rows[0], toggling: true)
        assert(model.selectedIDs.count == 3)
        model.query = "pdf"
        assert(model.selectedIDs.isEmpty)
        model.selectAllVisible()
        assert(model.selectedIDs == [pdf.id])
        model.group = .documents
        assert(model.selectedIDs.isEmpty)
        model.query = ""
        model.select(rows[1], extending: true)
        assert(model.selectedIDs == [txt.id], "Missing anchor falls back to one visible row")
        model.group = .all
        service.values = [pdf.id: preview, txt.id: notes]
        service.availableByType = [pdf.id: [preview, textEdit], txt.id: [textEdit, notes], jpeg.id: []]
        model.refresh()
        assert(model.commonApps(for: [pdf, txt]) == [textEdit])
        assert(model.commonApps(for: [pdf, jpeg]).isEmpty)
        assert(model.commonApps(for: []).isEmpty)
        service.values = [pdf.id: preview, txt.id: preview, jpeg.id: preview]
        service.failedTypes = [txt.id]
        model.refresh()
        model.selectAllVisible()
        let partial = await model.change([pdf, txt, jpeg, pdf], to: textEdit)!
        assert(partial.changed == 2 && partial.unchanged == 0 && partial.failures.map(\.typeID) == [txt.id])
        assert(service.writes == [pdf.id, txt.id, jpeg.id], "Duplicate system types must only be written once")
        assert(model.history.count == 2 && model.selectedIDs.isEmpty && !model.busy)
        assert(service.values[txt.id] == preview && model.error?.contains(txt.title) == true)
        let reloaded = AppModel(service: service, preferences: preferences)
        assert(reloaded.history.count == 2, "Successful writes survive partial failure")
        let skipped = await model.change([pdf, jpeg], to: textEdit)!
        assert(skipped.unchanged == 2 && skipped.changed == 0 && model.history.count == 2 && model.error == nil)
        assert(service.writes.count == 3)
        service.failedTypes.removeAll()
        service.noEffectTypes = [txt.id]
        let unverified = await model.change([txt], to: textEdit)!
        assert(unverified.failures.count == 1 && model.history.count == 3, "Accepted but unverified writes retain recovery records")
        assert(AppModel(service: service, preferences: preferences).history.count == 3)
        service.noEffectTypes.removeAll()
        let writesBeforeInvalid = service.writes.count
        let invalid = await model.change([pdf, txt], to: URL(fileURLWithPath: "/missing.app"))!
        assert(invalid.failures.count == 2 && service.writes.count == writesBeforeInvalid && !model.busy)
        let empty = await model.change([], to: textEdit)
        assert(empty == nil)

        // App-name search can hide a row as soon as its default app changes.
        model.query = "Preview"
        model.selectAllVisible()
        let filtered = await model.change(model.selectedKinds, to: textEdit)!
        assert(filtered.changed == 1 && model.visible.isEmpty && model.selectedIDs.isEmpty)

        // Hold one system call open to prove reentry and target mutation are blocked.
        model.query = ""
        service.values = [pdf.id: preview, txt.id: preview]
        model.refresh()
        model.select(pdf)
        var resume: CheckedContinuation<Void, Never>?
        service.beforeSet = { await withCheckedContinuation { resume = $0 } }
        let task = Task { await model.change([pdf, txt], to: notes) }
        while resume == nil { await Task.yield() }
        assert(model.busy)
        let reads = service.reads
        model.refreshIfNeeded()
        assert(service.reads == reads, "Consent prompt activation must not trigger full refresh")
        model.select(jpeg)
        assert(model.selectedIDs == [pdf.id])
        let kindsBefore = model.kinds.count
        model.addExtension("busy-test")
        assert(model.kinds.count == kindsBefore)
        let overlapping = await model.change([jpeg], to: textEdit)
        assert(overlapping == nil)
        model.query = "png"
        service.beforeSet = nil
        resume?.resume()
        let completed = await task.value!
        assert(completed.changed == 2 && service.values[pdf.id] == notes && service.values[txt.id] == notes)
        assert(!model.busy && model.selectedIDs.isEmpty)

        let oversized = (0..<70).map { _ in ChangeRecord(id: UUID(), typeID: pdf.id, title: pdf.title,
            oldPath: preview.path, newPath: textEdit.path, date: Date()) }
        preferences.set(try JSONEncoder().encode(oversized), forKey: "history")
        assert(AppModel(service: service, preferences: preferences).history.count == 50)
        print("PASS: Shift ranges, reverse/anchor selection, Cmd toggle, filter clearing, common-app intersection, batch dedup/skip")
        print("PASS: partial failure, recovery history, invalid target, busy protection, target snapshots, hidden-selection clearing, history bound")
    }
}
