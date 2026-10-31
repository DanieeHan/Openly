import AppKit
import Foundation
import UniformTypeIdentifiers

private final class MemoryPreferences: UserDefaults {
    // Override every preference access used by AppModel; never touch the user's defaults.
    private var values: [String: Any] = [:]
    private(set) var saves = 0
    init(memoryOnly: Void) { super.init(suiteName: nil)! }
    override func object(forKey key: String) -> Any? { values[key] }
    override func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    override func dictionary(forKey key: String) -> [String: Any]? { values[key] as? [String: Any] }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func set(_ value: Any?, forKey key: String) { values[key] = value; saves += 1 }
}

private final class PausedAssociations: AssociationService {
    let original: URL
    var values: [String: URL] = [:]
    var writes: [String] = []
    var pending: (String, URL, CheckedContinuation<Void, Error>)?
    init(original: URL) { self.original = original }
    func current(_ type: UTType) -> URL? { values[type.identifier] ?? original }
    func candidates(_ type: UTType) -> [URL] { [original] }
    func set(_ app: URL, for type: UTType) async throws {
        writes.append(type.identifier)
        try await withCheckedThrowingContinuation { continuation in
            precondition(pending == nil)
            pending = (type.identifier, app, continuation)
        }
    }
    func finish(error: Error? = nil) {
        let operation = pending!
        pending = nil
        if let error { operation.2.resume(throwing: error) }
        else { values[operation.0] = operation.1; operation.2.resume() }
    }
}

private final class RecordingApplication: NSApplication {
    // Capture the actual NSApp reply without ending the test process.
    var replies: [Bool] = []
    var inspectBeforeReply: (() -> Void)?
    override func reply(toApplicationShouldTerminate shouldTerminate: Bool) {
        inspectBeforeReply?()
        replies.append(shouldTerminate)
    }
}

@main
struct LifecycleTests {
    @MainActor private static func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        fatalError("Timed out waiting for test condition")
    }

    private static func records(_ preferences: MemoryPreferences) -> [ChangeRecord] {
        guard let data = preferences.data(forKey: "history") else { return [] }
        return try! JSONDecoder().decode([ChangeRecord].self, from: data)
    }

    @MainActor static func main() async throws {
        let app = RecordingApplication.shared as! RecordingApplication
        let delegate = AppDelegate()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("OpenlyLifecycleTests-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("Original.app")
        let target = folder.appendingPathComponent("Target.app")
        for (url, id) in [(original, "test.original"), (target, "test.target")] {
            let contents = url.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id, "CFBundlePackageType": "APPL"], format: .xml, options: 0)
            try plist.write(to: contents.appendingPathComponent("Info.plist"))
        }
        precondition(NSApp === app, "The real AppDelegate must reply to the recording application")
        precondition(delegate.applicationShouldTerminate(app) == .terminateNow)
        precondition(delegate.applicationShouldTerminateAfterLastWindowClosed(app))
        print("PASS idle terminateNow; last-window closure requests termination")

        // Batch: suspend the first system callback, request exit twice, then complete it.
        let preferences = MemoryPreferences(memoryOnly: ())
        let service = PausedAssociations(original: original)
        let model = AppModel(service: service, preferences: preferences)
        delegate.attach(model)
        let targets = Array(model.kinds.prefix(2))
        precondition(targets.count == 2)
        let batch = Task { await model.change(targets, to: target) }
        await waitUntil { service.pending != nil }
        precondition(model.busy && model.progress?.total == 2)
        precondition(records(preferences).first?.pending == true)
        app.inspectBeforeReply = {
            precondition(!model.busy)
            let saved = records(preferences)
            precondition(saved.count == 1 && saved[0].pending == false)
            precondition(saved[0].oldPath == original.path && saved[0].newPath == target.path)
            precondition(preferences.saves >= 2)
        }
        precondition(delegate.applicationShouldTerminate(app) == .terminateLater)
        precondition(delegate.applicationShouldTerminate(app) == .terminateLater)
        precondition(model.stopRequested)
        try? await Task.sleep(nanoseconds: 20_000_000)
        precondition(app.replies.isEmpty && model.busy, "Exit must wait for the pending system callback")
        print("PASS busy batch terminateLater; stop requested; no reply before callback")
        service.finish()
        let result = await batch.value
        await waitUntil { app.replies.count == 1 }
        precondition(app.replies == [true])
        precondition(service.writes.count == 1, "An exit request must stop the remaining batch items")
        precondition(result?.changed == 1 && result?.unprocessed == 1 && result?.stopped == true)
        try? await Task.sleep(nanoseconds: 20_000_000)
        precondition(app.replies.count == 1)
        precondition(delegate.applicationShouldTerminate(app) == .terminateNow)
        print("PASS batch replies exactly once after confirmed history save; second type not written")

        // Single mutation: no batch stop flag, but the same termination delay protects its save.
        let singlePreferences = MemoryPreferences(memoryOnly: ())
        let singleService = PausedAssociations(original: original)
        let singleModel = AppModel(service: singleService, preferences: singlePreferences)
        delegate.attach(singleModel)
        let single = Task { await singleModel.change(singleModel.kinds[0], to: target) }
        await waitUntil { singleService.pending != nil }
        app.inspectBeforeReply = {
            precondition(!singleModel.busy)
            precondition(records(singlePreferences).count == 1)
            precondition(records(singlePreferences)[0].pending == false)
        }
        precondition(delegate.applicationShouldTerminate(app) == .terminateLater)
        precondition(app.replies.count == 1)
        singleService.finish()
        await single.value
        await waitUntil { app.replies.count == 2 }
        print("PASS single change also waits until confirmed history is saved")

        // Failed/cancelled callback: clear the uncommitted recovery record before exit.
        let failedPreferences = MemoryPreferences(memoryOnly: ())
        let failedService = PausedAssociations(original: original)
        let failedModel = AppModel(service: failedService, preferences: failedPreferences)
        delegate.attach(failedModel)
        let failed = Task { await failedModel.change(Array(failedModel.kinds.prefix(2)), to: target) }
        await waitUntil { failedService.pending != nil }
        app.inspectBeforeReply = {
            precondition(!failedModel.busy)
            precondition(records(failedPreferences).isEmpty)
            precondition(failedPreferences.saves >= 2)
        }
        precondition(delegate.applicationShouldTerminate(app) == .terminateLater)
        failedService.finish(error: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        _ = await failed.value
        await waitUntil { app.replies.count == 3 }
        precondition(failedService.writes.count == 1)
        precondition(app.replies.allSatisfy { $0 })
        print("PASS cancelled callback saves cleanup before reply and stops remaining writes")
        print("Lifecycle tests passed — real AppDelegate and AppModel, simulated association service, in-memory preferences")
    }
}
