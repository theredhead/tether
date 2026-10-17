import Foundation

struct SourceHost: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = "New host"
    var address = ""
    var user = ""
    var port = 22
    var identityFile = ""
    var endpoint: String { user.isEmpty ? address : "\(user)@\(address)" }
    var validation: String? {
        if address.isEmpty || address.hasPrefix("-") || address.contains(where: { $0.isWhitespace || ":/@".contains($0) }) { return "Enter a hostname or SSH config alias (without user or path)." }
        if !user.isEmpty && (user.hasPrefix("-") || user.contains(where: { $0.isWhitespace || ":/@".contains($0) })) { return "Enter a valid SSH username." }
        if !(1...65535).contains(port) { return "Port must be between 1 and 65535." }
        return nil
    }
}

struct SyncJob: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = "New sync"
    var hostID: UUID?
    var remotePath = ""
    var destinationPath = ""
    var isFolder = false
    var enabled = true
    var validation: String? {
        if !remotePath.hasPrefix("/") || remotePath.contains(where: { $0.isNewline || $0 == "\0" }) { return "Use an absolute remote path." }
        if !destinationPath.hasPrefix("/") || destinationPath == "/" { return "Choose an absolute local target path." }
        return nil
    }
}

struct Configuration: Codable {
    var hosts: [SourceHost] = []
    var jobs: [SyncJob] = []
    var automatic = false
    var intervalMinutes = 15
    var notificationsEnabled = false
}

extension Configuration {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        hosts = try values.decodeIfPresent([SourceHost].self, forKey: .hosts) ?? []
        jobs = try values.decodeIfPresent([SyncJob].self, forKey: .jobs) ?? []
        automatic = try values.decodeIfPresent(Bool.self, forKey: .automatic) ?? false
        intervalMinutes = try values.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? 15
        notificationsEnabled = try values.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? false
    }
}

struct JobResult {
    var date: Date
    var message: String
    var failed: Bool
}

struct SyncFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

actor SyncEngine {
    private func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        // A temporary file avoids pipe backpressure and unbounded stderr buffering.
        let log = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: log.path, contents: nil) else { throw SyncFailure(message: "Could not create process log.") }
        defer { try? FileManager.default.removeItem(at: log) }
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        process.standardError = handle
        process.standardOutput = handle
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let data = try Data(contentsOf: log)
        let output = String(decoding: data.prefix(16_384), as: UTF8.self)
        guard process.terminationStatus == 0 else { throw SyncFailure(message: "\(URL(fileURLWithPath: executable).lastPathComponent) exited \(process.terminationStatus): \(output)") }
        return output
    }

    private func options(_ host: SourceHost) -> [String] {
        var args = ["-o", "UseKeychain=yes", "-o", "AddKeysToAgent=yes", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=15", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3"]
        if !host.identityFile.isEmpty { args += ["-o", "IdentitiesOnly=yes", "-i", (host.identityFile as NSString).expandingTildeInPath] }
        return args
    }

    func test(_ host: SourceHost) throws {
        if let error = host.validation { throw SyncFailure(message: error) }
        _ = try run("/usr/bin/ssh", options(host) + ["-p", String(host.port), host.endpoint, "true"])
    }

    func addKey(_ path: String) throws {
        guard path.hasPrefix("/") else { throw SyncFailure(message: "Choose a private key file first.") }
        _ = try run("/usr/bin/ssh-add", ["--apple-use-keychain", path])
    }

    func synchronize(_ job: SyncJob, host: SourceHost) throws -> Bool {
        if let error = host.validation ?? job.validation { throw SyncFailure(message: error) }
        let fm = FileManager.default
        let destination = URL(fileURLWithPath: job.destinationPath)
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".tether-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        let download = staging.appendingPathComponent("payload")
        var args = options(host) + ["-P", String(host.port)]
        if job.isFolder { args.append("-r") }
        args += ["--", "\(host.endpoint):\(job.remotePath)", download.path]
        _ = try run("/usr/bin/scp", args)
        let values = try download.resourceValues(forKeys: [.isDirectoryKey])
        guard (values.isDirectory == true) == job.isFolder else { throw SyncFailure(message: "Remote item does not match the selected file/folder type.") }
        if fm.fileExists(atPath: destination.path) {
            if try destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw SyncFailure(message: "Target must not be a symbolic link.")
            }
            if job.isFolder {
                // Merge downloaded contents. Preserve local-only files and compare before copying.
                return try merge(download, into: destination)
            }
            if fm.contentsEqual(atPath: download.path, andPath: destination.path) { return false }
        }
        if Darwin.rename(download.path, destination.path) != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return true
    }

    func merge(_ source: URL, into target: URL) throws -> Bool {
        let fm = FileManager.default
        let values = try target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true && values.isSymbolicLink != true else { throw SyncFailure(message: "Folder target must be a directory, not a symbolic link or file.") }
        var changed = false
        for child in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            let output = target.appendingPathComponent(child.lastPathComponent)
            let info = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard info.isSymbolicLink != true else { throw SyncFailure(message: "Symbolic links in folder transfers are unsupported.") }
            if fm.fileExists(atPath: output.path) {
                let old = try output.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard old.isSymbolicLink != true && old.isDirectory == info.isDirectory else { throw SyncFailure(message: "Conflicting target type: \(output.path)") }
                if info.isDirectory == true { changed = try merge(child, into: output) || changed }
                else if !fm.contentsEqual(atPath: child.path, andPath: output.path) {
                    if Darwin.rename(child.path, output.path) != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                    changed = true
                }
            } else { try fm.moveItem(at: child, to: output); changed = true }
        }
        return changed
    }
}
