import AppKit
import SwiftUI
import XCTest
import InspectorCore
@testable import InspectorApp

final class WorkspaceTests: XCTestCase {
    @MainActor private func workspace(_ old: [String: Any] = [:]) -> (Workspace, UserDefaults) {
        let suite = "io.github.yogivirabhadra.omlx-inspector.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.setPersistentDomain(old, forName: suite)
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return (Workspace(defaults: defaults), defaults)
    }
    private func line(_ body: String, logger: String = "omlx.server", level: String = "TRACE") -> String {
        "2026-11-27 10:00:00,000 - \(logger) - \(level) - [-] - \(body)\n"
    }
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-\(UUID()).log")
        let text =
            line(
                #"Incoming POST /v1/chat/completions — body: {"model":"fixture","messages":[{"role":"user","content":"Synthetic smoke question"}]}"#
            )
            + line("fixture warning", logger: "custom.logger", level: "WARNING")
        try text.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("old"))
        }
        return url
    }
    @MainActor private func waitFor(_ description: String, _ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out: \(description)")
    }
    @MainActor func testLegacyPlistPreferencesAndInvalidFallbacks() async throws {
        let old: [String: Any] = [
            "browsingMode": "Log Records", "recordMode": "Source", "mode": "Structured", "appearance": "Dark",
            "showContext": true, "filter": "Tools & results", "monitoring": false
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: old, format: .xml, options: 0)
        let restored = try XCTUnwrap(PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any])
        let (model, defaults) = workspace(restored)
        defer { model.stop() }
        XCTAssertEqual(model.browsingMode, .logRecords)
        XCTAssertEqual(model.recordMode, .source)
        XCTAssertEqual(model.mode, .structured)
        XCTAssertEqual(model.appearance, .dark)
        XCTAssertTrue(model.showContext)
        XCTAssertFalse(model.monitoring)
        XCTAssertEqual(model.filter, .tools)
        model.savePreferences()
        model.browsingMode = .logRecords
        model.recordMode = .source
        for (key, value) in old { XCTAssertEqual(defaults.object(forKey: key) as? NSObject, value as? NSObject, key) }
        let (invalid, _) = workspace([
            "browsingMode": "future", "recordMode": "Readable", "mode": "future", "appearance": "future"
        ])
        defer { invalid.stop() }
        XCTAssertEqual(invalid.browsingMode, .executions)
        XCTAssertEqual(invalid.recordMode, .structured)
        XCTAssertEqual(invalid.mode, .readable)
        XCTAssertEqual(invalid.appearance, .system)
        XCTAssertTrue(LoggerFilter.named("custom.logger").includes("custom.logger"))
        XCTAssertFalse(LoggerFilter.named("custom.logger").includes("other"))
        XCTAssertTrue(RecordLevel.all.includes("future-level"))
    }
    @MainActor func testClearHistorySearchCancellationAndRecordFiltering() async throws {
        let (model, _) = workspace()
        defer { model.stop() }
        model.load(try fixture())
        try await waitFor("load") { model.snapshot != nil && !model.loading }
        let canonicalCount = model.snapshot!.records.count
        model.browsingMode = .logRecords
        model.query = "Synthetic"
        model.searchPresented = true
        model.runSearch()
        model.clearDisplay()
        XCTAssertTrue(model.following)
        XCTAssertNotNil(model.displayBoundary)
        XCTAssertTrue(model.filteredRecords.isEmpty)
        XCTAssertNil(model.recordID)
        XCTAssertFalse(model.searchPresented)
        XCTAssertNil(model.searchGeneration)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(model.recordSearchResults)
        XCTAssertNil(model.searchResults)
        XCTAssertNil(model.detail)
        XCTAssertEqual(model.snapshot?.records.count, canonicalCount)
        model.showHistory()
        XCTAssertNil(model.displayBoundary)
        XCTAssertFalse(model.following)
        XCTAssertEqual(model.filteredRecords.count, canonicalCount)
        XCTAssertNotNil(model.recordID)
        try await waitFor("record detail") { model.detail != nil }
        model.runSearch()
        try await waitFor("record search") { model.recordSearchResults != nil }
        model.recordLogger = .named("custom.logger")
        XCTAssertNil(model.recordSearchResults)
        XCTAssertNil(model.searchGeneration)
        XCTAssertEqual(model.filteredRecords.count, 1)
        model.recordLevel = .info
        XCTAssertTrue(model.filteredRecords.isEmpty)
        XCTAssertNil(model.recordID)
        model.followLatest()
        XCTAssertEqual(model.recordLogger, .all)
        XCTAssertEqual(model.recordLevel, .all)
        XCTAssertTrue(model.following)
        XCTAssertEqual(model.recordID, model.filteredRecords.last?.id)
        model.query = "fixture"
        model.runSearch()
        model.browsingMode = .executions
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(model.recordSearchResults)
        XCTAssertNil(model.searchResults)
        XCTAssertFalse(model.following)
    }
    @MainActor func testLiveAppendAndRotationWhileFollowingAndBrowsing() async throws {
        let (model, _) = workspace()
        defer { model.stop() }
        let url = try fixture()
        model.load(url)
        try await waitFor("load") { model.snapshot != nil && !model.loading }
        model.browsingMode = .logRecords
        model.clearDisplay()
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line("live append", logger: "custom.logger", level: "INFO").utf8))
        try handle.close()
        try await waitFor("append") { model.filteredRecords.contains { $0.summary == "live append" } }
        XCTAssertTrue(model.following)
        let generation = model.snapshot!.generation
        model.showHistory()
        model.query = "fixture"
        model.runSearch()
        try await waitFor("search") { model.recordSearchResults != nil }
        try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("old"))
        try line("new generation", logger: "custom.logger", level: "INFO").write(
            to: url, atomically: true, encoding: .utf8)
        try await waitFor("deferred rotation") { model.pendingReplacement != nil }
        XCTAssertEqual(model.snapshot?.generation, generation)
        model.followLatest()
        XCTAssertNil(model.pendingReplacement)
        XCTAssertNil(model.recordSearchResults)
        XCTAssertNotEqual(model.snapshot?.generation, generation)
        XCTAssertTrue(model.filteredRecords.contains { $0.summary == "new generation" })
        model.clearDisplay()
        try line("following replacement", logger: "custom.logger", level: "INFO").write(
            to: url, atomically: true, encoding: .utf8)
        try await waitFor("live replacement") {
            model.filteredRecords.contains { $0.summary == "following replacement" }
        }
        XCTAssertNil(model.pendingReplacement)
        XCTAssertNil(model.displayBoundary)
    }
    @MainActor func testMonitoringResumesAfterFailedOrCancelledReload() async throws {
        let (model, _) = workspace()
        defer { model.stop() }
        let url = try fixture()
        model.load(url)
        try await waitFor("load") { model.snapshot != nil && !model.loading }
        let append = { (body: String) in
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(self.line(body, logger: "custom.logger", level: "INFO").utf8))
            try handle.close()
        }
        // A load that fails (a directory is not a log) must not leave the open log unmonitored.
        model.load(FileManager.default.temporaryDirectory)
        try await waitFor("failed load") { model.error != nil && !model.loading }
        try append("after failed load")
        try await waitFor("monitoring after failure") {
            model.snapshot?.records.contains { $0.summary == "after failed load" } == true
        }
        // Neither may a load the user cancels.
        model.load(url)
        model.cancel()
        XCTAssertFalse(model.loading)
        try append("after cancelled load")
        try await waitFor("monitoring after cancel") {
            model.snapshot?.records.contains { $0.summary == "after cancelled load" } == true
        }
    }
    @MainActor func testNativePanesRenderWithFixture() async throws {
        _ = NSApplication.shared
        let (model, _) = workspace()
        defer { model.stop() }
        // Mark launch restoration complete before explicitly loading the fixture;
        // mounting InspectorWindow runs restore() just as a real window does.
        model.restore()
        model.load(try fixture())
        try await waitFor("load") { model.snapshot != nil && !model.loading }
        for mode in BrowsingMode.allCases {
            model.browsingMode = mode
            try await waitFor("detail") { model.detail != nil }
            let host = NSHostingView(rootView: InspectorWindow(workspace: model))
            host.frame = NSRect(x: 0, y: 0, width: 1360, height: 850)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            try await waitFor("mounted inspector detail") { model.detail != nil && !model.detailLoading }
            host.layoutSubtreeIfNeeded()
            XCTAssertFalse(model.text.isEmpty)
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            XCTAssertGreaterThan(bitmap.pixelsHigh, 0)
            if let directory = ProcessInfo.processInfo.environment["INSPECTOR_SMOKE_OUTPUT"] {
                let url = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
                    to: url.appendingPathComponent("\(mode.rawValue).png"))
            }
        }
    }
}
