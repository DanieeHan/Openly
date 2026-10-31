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
    var cancelledTypes: Set<String> = []
    var errorAfterSetTypes: Set<String> = []
    var noEffectTypes: Set<String> = []
    var writes: [String] = []
    var beforeSet: (@MainActor () async -> Void)?
    var afterSet: (@MainActor () async -> Void)?
    func current(_ type: UTType) -> URL? { reads += 1; return values[type.identifier] }
    func candidates(_ type: UTType) -> [URL] { candidateReads += 1; return availableByType[type.identifier] ?? available }
    func set(_ app: URL, for type: UTType) async throws {
        writes.append(type.identifier)
        if let beforeSet { await beforeSet() }
        if cancelledTypes.contains(type.identifier) { throw CocoaError(.userCancelled) }
        if shouldFail || failedTypes.contains(type.identifier) { throw AppFailure.verification }
        if !noEffectTypes.contains(type.identifier) { values[type.identifier] = app }
        if let afterSet { await afterSet() }
        if errorAfterSetTypes.contains(type.identifier) { throw AppFailure.verification }
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
        try importSafetyTests()
        try await journalAndStopTests()
        try await batchRecoveryTests()
        try await historyCompatibilityTests()
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
        assert(model.history.count == 2 && model.selectedIDs == [txt.id] && !model.busy)
        assert(service.values[txt.id] == preview && model.error == nil)
        assert(model.batchReport?.result.failures.map(\.typeID) == [txt.id], "Batch failures stay in the report, without a duplicate error alert")
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
        let unverifiedRecord = model.history.first!
        let writesBeforeRecovery = service.writes.count
        assert(unverifiedRecord.pending == true)
        await model.undo(unverifiedRecord)
        assert(model.error == nil && model.history.first?.restoredAt != nil)
        assert(service.writes.count == writesBeforeRecovery, "Recover an unapplied pending write without rewriting the original default")
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

    @MainActor static func importSafetyTests() throws {
        let suite = "com.openly.import-tests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("Openly-import-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: fixture)
        }
        preferences.set(["pdf": "public.symlink", "txt": "com.apple.alias-file", "png": UTType.png.identifier], forKey: "typeOverrides")
        let model = AppModel(service: FakeAssociations(), preferences: preferences)
        assert(model.kinds.first { $0.extensions.contains("pdf") }?.id == UTType.pdf.identifier)
        assert(model.kinds.first { $0.extensions.contains("txt") }?.id == UTType.plainText.identifier)
        let migrated = preferences.dictionary(forKey: "typeOverrides") as? [String: String]
        assert(migrated == ["png": UTType.png.identifier], "Remove old link overrides without discarding unrelated mappings")

        let document = fixture.appendingPathComponent("document.pdf")
        try "%PDF-1.4\n%%EOF".write(to: document, atomically: true, encoding: .utf8)
        let disguised = fixture.appendingPathComponent("linked.txt")
        try FileManager.default.createSymbolicLink(at: disguised, withDestinationURL: document)
        model.importFile(disguised)
        assert(model.error == nil && model.query == ".pdf", "Use the resolved target's extension, not the link's misleading name")
        assert(model.kinds.first { $0.extensions.contains("pdf") }?.id == UTType.pdf.identifier)
        assert(model.kinds.first { $0.extensions.contains("txt") }?.id == UTType.plainText.identifier)
        let reloaded = AppModel(service: FakeAssociations(), preferences: preferences)
        assert(reloaded.kinds.first { $0.extensions.contains("pdf") }?.id == UTType.pdf.identifier)

        let broken = fixture.appendingPathComponent("broken.pdf")
        try FileManager.default.createSymbolicLink(at: broken, withDestinationURL: fixture.appendingPathComponent("missing.pdf"))
        let directoryLink = fixture.appendingPathComponent("directory.pdf")
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: fixture)
        let invalidExtension = fixture.appendingPathComponent("document.invalid extension")
        try "sample".write(to: invalidExtension, atomically: true, encoding: .utf8)
        let savedOverrides = preferences.dictionary(forKey: "typeOverrides") as? [String: String]
        let savedExtensions = preferences.stringArray(forKey: "customExtensions")
        let savedKinds = model.kinds.map(\.id)
        for invalid in [broken, directoryLink, invalidExtension, fixture, URL(string: "https://example.invalid/file.pdf")!] {
            model.error = nil
            model.importFile(invalid)
            assert(model.error != nil, "Reject invalid imports")
            assert(preferences.dictionary(forKey: "typeOverrides") as? [String: String] == savedOverrides)
            assert(preferences.stringArray(forKey: "customExtensions") == savedExtensions)
            assert(model.kinds.map(\.id) == savedKinds, "Rejected files must not alter type mappings")
        }
        print("PASS: symbolic-link target resolution, old mapping migration, rejected imports leave preferences unchanged")
    }

    @MainActor static func journalAndStopTests() async throws {
        let suite = "com.openly.journal-tests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let service = FakeAssociations()
        let model = AppModel(service: service, preferences: preferences)
        let preview = URL(fileURLWithPath: "/System/Applications/Preview.app")
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        let targets = Array(model.kinds.prefix(3))
        for kind in targets { service.values[kind.id] = preview }
        model.refresh()
        var resume: CheckedContinuation<Void, Never>?
        service.beforeSet = {
            if service.writes.count == 2 {
                await withCheckedContinuation { resume = $0 }
            }
        }
        let task = Task { await model.change(targets, to: textEdit) }
        while resume == nil { await Task.yield() }
        assert(model.progress?.completed == 1 && model.progress?.total == 3)
        assert(model.progress?.currentTitle == targets[1].title && model.progress?.isUndo == false)
        let persisted = try JSONDecoder().decode([ChangeRecord].self, from: preferences.data(forKey: "history")!)
        assert(persisted.count == 2, "Both the completed item and in-flight journal must already be saved")
        assert(persisted.first { $0.typeID == targets[0].id }?.pending == false)
        assert(persisted.first { $0.typeID == targets[1].id }?.pending == true)
        assert(Set(persisted.compactMap(\.batchID)).count == 1)
        let reopened = AppModel(service: service, preferences: preferences)
        assert(reopened.history.count == 2 && reopened.history.contains { $0.typeID == targets[0].id && $0.pending == false })
        model.requestStop()
        assert(model.busy && model.stopRequested && service.writes.count == 2, "Stopping waits for the active system request")
        service.beforeSet = nil
        resume?.resume()
        let stopped = await task.value!
        assert(stopped.changed == 2 && stopped.stopped && stopped.unprocessed == 1 && stopped.failures.isEmpty)
        assert(service.writes == targets.prefix(2).map(\.id), "Never start the next write after a stop request")
        assert(model.selectedIDs == [targets[2].id] && model.canRetryBatch)
        assert(!model.busy && model.progress == nil && !model.stopRequested)
        let batchID = model.history.first!.batchID!
        model.query = "no-matching-type"
        await model.retryBatch()
        assert(service.writes == targets.map(\.id), "Retry uses the stopped batch snapshot even after filtering")
        assert(model.batchReport?.result.changed == 1 && !model.canRetryBatch)
        assert(model.history.count == 3 && model.history.allSatisfy { $0.batchID == batchID && $0.pending == false })

        // A write can already be effective while the system callback is still pending.
        model.query = ""
        service.writes.removeAll()
        resume = nil
        service.afterSet = { await withCheckedContinuation { resume = $0 } }
        let inFlight = Task { await model.change(targets[0], to: preview) }
        while resume == nil { await Task.yield() }
        let recovered = AppModel(service: service, preferences: preferences)
        let pending = recovered.history.first!
        assert(pending.pending == true && pending.typeID == targets[0].id && service.values[targets[0].id] == preview)
        service.afterSet = nil
        resume?.resume()
        await inFlight.value
        // The record loaded during the interrupted callback is sufficient to restore safely.
        await recovered.undo(pending)
        assert(recovered.error == nil && service.values[targets[0].id] == textEdit)
        assert(recovered.history.first?.restoredAt != nil)
        print("PASS: write-ahead recovery journal, per-item persistence, stop waits for current write, stopped-batch retry")
    }

    @MainActor static func batchRecoveryTests() async throws {
        let suite = "com.openly.recovery-tests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let service = FakeAssociations()
        let model = AppModel(service: service, preferences: preferences)
        let preview = URL(fileURLWithPath: "/System/Applications/Preview.app")
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        let notes = URL(fileURLWithPath: "/System/Applications/Notes.app")
        let targets = Array(model.kinds.prefix(12))
        for kind in targets { service.values[kind.id] = preview }
        service.failedTypes = Set(targets.dropFirst().map(\.id))
        let partial = await model.change(targets, to: textEdit)!
        assert(partial.changed == 1 && partial.failures.count == 11)
        assert(model.batchReport?.result.failures.count == 11, "Keep every failure, including those beyond the old eight-item limit")
        assert(model.selectedIDs == service.failedTypes && model.canRetryBatch && model.error == nil)
        let batchID = model.history.first!.batchID!
        model.query = "no-matching-type"
        service.failedTypes.removeAll()
        let writesBeforeRetry = service.writes.count
        await model.retryBatch()
        assert(Array(service.writes.dropFirst(writesBeforeRetry)) == targets.dropFirst().map(\.id), "Retry only incomplete items")
        assert(model.history.count == 12 && model.history.allSatisfy { $0.batchID == batchID })

        // A later change made elsewhere must survive a whole-batch undo.
        service.values[targets[0].id] = notes
        let writesBeforeUndo = service.writes.count
        await model.undoBatch(batchID)
        assert(model.batchReport?.isUndo == true && model.batchReport?.result.changed == 11)
        assert(model.batchReport?.result.failures.map(\.typeID) == [targets[0].id])
        assert(service.values[targets[0].id] == notes && service.writes.count == writesBeforeUndo + 11)
        assert(model.history.filter { $0.restoredAt != nil }.count == 11 && model.canRetryBatch)
        service.values[targets[0].id] = textEdit
        await model.retryBatch()
        assert(model.batchReport?.isUndo == true && model.batchReport?.result.changed == 1)
        assert(model.history.allSatisfy { $0.restoredAt != nil } && !model.canRetryBatch)
        assert(AppModel(service: service, preferences: preferences).history.allSatisfy { $0.restoredAt != nil })

        model.query = ""
        service.writes.removeAll()
        service.cancelledTypes = [targets[0].id]
        let cancelled = await model.change(Array(targets.prefix(3)), to: textEdit)!
        assert(cancelled.stopped && cancelled.changed == 0 && cancelled.unprocessed == 2 && cancelled.failures.count == 1)
        assert(service.writes == [targets[0].id], "A system cancellation stops subsequent writes")
        assert(model.selectedIDs == Set(targets.prefix(3).map(\.id)) && model.canRetryBatch)
        service.cancelledTypes.removeAll()
        await model.retryBatch()
        assert(model.batchReport?.result.changed == 3 && !model.canRetryBatch)
        let cancelBatchID = model.history.first!.batchID!
        assert(model.history.filter { $0.batchID == cancelBatchID }.count == 3)

        // Stopping undo must also retain the untouched remainder for retry.
        var resume: CheckedContinuation<Void, Never>?
        service.beforeSet = { await withCheckedContinuation { resume = $0 } }
        let undo = Task { await model.undoBatch(cancelBatchID) }
        while resume == nil { await Task.yield() }
        assert(model.progress?.isUndo == true && model.progress?.total == 3)
        model.requestStop()
        service.beforeSet = nil
        resume?.resume()
        await undo.value
        assert(model.batchReport?.result.changed == 1 && model.batchReport?.result.unprocessed == 2 && model.canRetryBatch)
        await model.retryBatch()
        assert(model.batchReport?.result.changed == 2 && !model.canRetryBatch)
        assert(model.history.filter { $0.batchID == cancelBatchID }.allSatisfy { $0.restoredAt != nil })

        // A callback error after the intended state was applied must retain recovery.
        service.errorAfterSetTypes = [targets[0].id]
        await model.change(targets[0], to: textEdit)
        assert(model.error == nil && model.history.first?.pending == false && model.history.first?.oldPath == preview.path)
        service.errorAfterSetTypes.removeAll()
        service.failedTypes = [targets[0].id]
        _ = await model.change([targets[0]], to: preview)
        assert(model.canRetryBatch)
        // A new operation invalidates old retry intent even when it is a no-op.
        await model.change(targets[0], to: textEdit)
        let writesAfterNewOperation = service.writes.count
        await model.retryBatch()
        assert(!model.canRetryBatch && model.batchReport == nil && service.writes.count == writesAfterNewOperation)
        model.dismissBatchReport()
        assert(model.batchReport == nil && !model.canRetryBatch)
        print("PASS: complete failure details, failed-only retry, whole-batch undo, external-change protection, cancellation and undo stop/retry")
    }

    @MainActor static func historyCompatibilityTests() async throws {
        let suite = "com.openly.history-tests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let service = FakeAssociations()
        let preview = URL(fileURLWithPath: "/System/Applications/Preview.app")
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        let oldRecord = ChangeRecord(id: UUID(), typeID: UTType.pdf.identifier, title: "PDF 文档", oldPath: preview.path, newPath: textEdit.path, date: Date())
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode([oldRecord])) as! [[String: Any]]
        legacy[0].removeValue(forKey: "batchID")
        legacy[0].removeValue(forKey: "pending")
        preferences.set(try JSONSerialization.data(withJSONObject: legacy), forKey: "history")
        let model = AppModel(service: service, preferences: preferences)
        assert(model.history.count == 1 && model.history.first?.id == oldRecord.id)
        assert(model.history.first?.batchID == nil && model.history.first?.pending == nil, "Existing history decodes without new fields")
        var targets: [FileKind] = []
        for number in 0..<60 {
            let ext = "openly-regression-\(number)"
            model.addExtension(ext)
            targets.append(model.kinds.first { $0.extensions.contains(ext) }!)
        }
        model.query = ""
        for kind in targets { service.values[kind.id] = preview }
        let result = await model.change(targets, to: textEdit)!
        assert(result.changed == 60 && result.failures.isEmpty)
        let batchID = model.history.first!.batchID!
        assert(model.history.filter { $0.batchID == batchID }.count == 60, "A batch larger than 50 types retains all recovery records")
        let older = (0..<70).map { _ in ChangeRecord(id: UUID(), typeID: UTType.pdf.identifier, title: "PDF 文档", oldPath: preview.path, newPath: textEdit.path, date: Date()) }
        preferences.set(try JSONEncoder().encode(model.history.filter { $0.batchID == batchID } + older), forKey: "history")
        let reloaded = AppModel(service: service, preferences: preferences)
        assert(reloaded.history.count == 109 && Set(reloaded.history.map(\.operationID)).count == 50)
        assert(reloaded.history.filter { $0.batchID == batchID }.count == 60)
        await reloaded.undoBatch(batchID)
        assert(reloaded.batchReport?.result.changed == 60 && reloaded.batchReport?.result.failures.isEmpty == true)
        assert(targets.allSatisfy { service.values[$0.id] == preview })
        print("PASS: legacy history decoding, 50-operation retention, more than 50 types retain complete batch recovery")
    }
}
