import XCTest
@testable import Tether

final class TetherTests: XCTestCase {
    func testConfigurationRoundTripKeepsHostAssociation() throws {
        let host = SourceHost(name: "Exports", address: "sync-server", user: "reader", port: 2222)
        let job = SyncJob(name: "Reports", hostID: host.id, remotePath: "/exports/a b", destinationPath: "/tmp/reports", isFolder: true)
        let config = Configuration(hosts: [host], jobs: [job], automatic: true, intervalMinutes: 30)
        let restored = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(restored.hosts, config.hosts)
        XCTAssertEqual(restored.jobs, config.jobs)
        XCTAssertEqual(restored.jobs[0].hostID, restored.hosts[0].id)
    }

    func testOlderConfigurationLoadsWithoutNotificationPreference() throws {
        let data = Data(#"{"hosts":[],"jobs":[],"automatic":true,"intervalMinutes":30}"#.utf8)
        let config = try JSONDecoder().decode(Configuration.self, from: data)
        XCTAssertTrue(config.automatic)
        XCTAssertEqual(config.intervalMinutes, 30)
        XCTAssertFalse(config.notificationsEnabled)
        var enabled = config
        enabled.notificationsEnabled = true
        let restored = try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(enabled))
        XCTAssertTrue(restored.notificationsEnabled)
    }

    func testInvalidSSHAndPaths() {
        XCTAssertNotNil(SourceHost(address: "-oProxyCommand=bad").validation)
        XCTAssertNotNil(SourceHost(address: "user@host").validation)
        XCTAssertNotNil(SourceHost(address: "host", port: 0).validation)
        XCTAssertNil(SourceHost(address: "my-ssh-alias").validation)
        XCTAssertNotNil(SyncJob(remotePath: "relative", destinationPath: "/tmp/a").validation)
        XCTAssertNotNil(SyncJob(remotePath: "/exports", destinationPath: "/").validation)
    }

    func testFolderMergePreservesLocalFilesAndDetectsChanges() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let target = root.appendingPathComponent("target")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: source.appendingPathComponent("report"))
        try Data("old".utf8).write(to: target.appendingPathComponent("report"))
        try Data("keep".utf8).write(to: target.appendingPathComponent("local"))
        let engine = SyncEngine()
        let changed = try await engine.merge(source, into: target)
        XCTAssertTrue(changed)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("report")), Data("new".utf8))
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("local")), Data("keep".utf8))
        try Data("new".utf8).write(to: source.appendingPathComponent("report"))
        let unchanged = try await engine.merge(source, into: target)
        XCTAssertFalse(unchanged)
    }

    func testFolderMergeRejectsTargetSymlink() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let target = root.appendingPathComponent("target")
        let outside = root.appendingPathComponent("outside")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: source.appendingPathComponent("report"))
        try Data("untouched".utf8).write(to: outside)
        try fm.createSymbolicLink(at: target.appendingPathComponent("report"), withDestinationURL: outside)
        do { _ = try await SyncEngine().merge(source, into: target); XCTFail("Expected rejection") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Conflicting target type")) }
        XCTAssertEqual(try Data(contentsOf: outside), Data("untouched".utf8))
    }
}
