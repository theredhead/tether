import SwiftUI
import AppKit
import ServiceManagement

@MainActor
final class SyncController: ObservableObject {
    @Published var configuration = Configuration()
    @Published var results: [UUID: JobResult] = [:]
    @Published var status = "Add a host and sync in Settings"
    @Published var isSyncing = false
    @Published var setupStatus = ""
    @Published var setupBusy = false
    @Published var persistenceError: String?
    @Published var notificationStatus = ""
    @Published var requestingNotifications = false
    private let notifications = UpdateNotifications()
    private let engine = SyncEngine()
    private var timer: Timer?
    private let configURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Tether/configuration.json")

    init() {
        if FileManager.default.fileExists(atPath: configURL.path) {
            do { configuration = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: configURL)) }
            catch { persistenceError = "Could not load settings: \(error.localizedDescription). Existing settings will not be overwritten until you save." }
        }
        schedule()
        if configuration.automatic { syncNow() }
    }
    func save() {
        do {
            configuration.intervalMinutes = min(1440, max(1, configuration.intervalMinutes))
            try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(configuration).write(to: configURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
            persistenceError = nil
            schedule()
        } catch { persistenceError = "Could not save settings: \(error.localizedDescription)" }
    }
    private func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Double(max(1, configuration.intervalMinutes)) * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in if let self, self.configuration.automatic { self.syncNow() } }
        }
    }
    func syncNow() {
        guard !isSyncing else { return }
        let config = configuration
        let jobs = config.jobs.filter(\.enabled)
        guard !jobs.isEmpty else { status = "No enabled syncs"; return }
        isSyncing = true; status = "Synchronizing…"
        Task {
            var failures = 0; var updates = 0
            for job in jobs {
                do {
                    guard let host = config.hosts.first(where: { $0.id == job.hostID }) else { throw SyncFailure(message: "Choose a source host in Settings.") }
                    let changed = try await engine.synchronize(job, host: host)
                    if changed {
                        updates += 1
                        if config.notificationsEnabled {
                            do { try await notifications.notifyUpdated(job) }
                            catch { notificationStatus = "Could not deliver update notification: \(error.localizedDescription)" }
                        }
                    }
                    results[job.id] = JobResult(date: Date(), message: changed ? "Updated" : "No changes", failed: false)
                } catch {
                    failures += 1
                    results[job.id] = JobResult(date: Date(), message: error.localizedDescription, failed: true)
                }
            }
            status = failures > 0 ? "\(failures) sync(s) failed — see Settings" : "Checked \(jobs.count) sync(s), updated \(updates)"
            isSyncing = false
        }
    }
    func setUpdateNotifications(_ enabled: Bool) {
        guard !requestingNotifications else { return }
        if !enabled {
            configuration.notificationsEnabled = false
            notificationStatus = ""
            save()
            return
        }
        requestingNotifications = true
        Task {
            do {
                let granted = try await notifications.requestPermission()
                configuration.notificationsEnabled = granted
                notificationStatus = granted ? "" : "Allow Tether in System Settings → Notifications, then enable this setting again."
                save()
            } catch {
                notificationStatus = error.localizedDescription
            }
            requestingNotifications = false
        }
    }

    func test(_ host: SourceHost) {
        guard !setupBusy else { return }; setupBusy = true; setupStatus = "Testing unattended SSH…"
        Task {
            do { try await engine.test(host); setupStatus = "Connected successfully without a password prompt." }
            catch { setupStatus = error.localizedDescription }
            setupBusy = false
        }
    }
    func addKey(_ host: SourceHost) {
        guard !setupBusy else { return }; setupBusy = true; setupStatus = "Adding key…"
        Task {
            do { try await engine.addKey(host.identityFile); setupStatus = "Key added to the SSH agent with macOS Keychain support." }
            catch { setupStatus = "\(error.localizedDescription)\nIf your key needs a passphrase, use the Terminal command below so you can enter it securely." }
            setupBusy = false
        }
    }

}

func choosePath(directory: Bool, save: Bool = false) -> String? {
    if save {
        let panel = NSSavePanel(); panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
    let panel = NSOpenPanel(); panel.canChooseDirectories = directory; panel.canChooseFiles = !directory
    panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
    return panel.runModal() == .OK ? panel.url?.path : nil
}

struct SettingsView: View {
    @ObservedObject var controller: SyncController
    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gear") }
            hosts.tabItem { Label("SSH Hosts", systemImage: "server.rack") }
            jobs.tabItem { Label("Syncs", systemImage: "arrow.triangle.2.circlepath") }
            SSHGuide().tabItem { Label("SSH Setup", systemImage: "key") }
        }.padding().frame(width: 760, height: 580)
    }
    private var general: some View {
        Form {
            Text("Tether").font(.largeTitle)
            Text("Download remote files and folders automatically over SSH.").foregroundStyle(.secondary)
            Toggle("Automatic sync while Tether is running", isOn: $controller.configuration.automatic)
            Toggle("Notify when files or folders are updated", isOn: Binding(
                get: { controller.configuration.notificationsEnabled },
                set: { controller.setUpdateNotifications($0) }
            )).disabled(controller.requestingNotifications)
            if !controller.notificationStatus.isEmpty {
                Text(controller.notificationStatus).font(.caption).textSelection(.enabled)
            }
            Stepper("Check every \(controller.configuration.intervalMinutes) minutes", value: $controller.configuration.intervalMinutes, in: 1...1440)
            HStack {
                Button("Save Settings") { controller.save() }
                Button("Sync Now") { controller.syncNow() }.disabled(controller.isSyncing)
            }
            Button("Enable Launch at Login") {
                do { try SMAppService.mainApp.register(); controller.setupStatus = "Login startup enabled. Check System Settings → General → Login Items if approval is needed." }
                catch { controller.setupStatus = error.localizedDescription }
            }
            Button("Disable Launch at Login") {
                do { try SMAppService.mainApp.unregister(); controller.setupStatus = "Login startup disabled." }
                catch { controller.setupStatus = error.localizedDescription }
            }
            Text("Launch at login requires the packaged app in Applications. Sync pauses when your Mac sleeps and stops when you quit.").font(.caption)
            Text(controller.status)
            Text(controller.setupStatus).textSelection(.enabled)
            if let error = controller.persistenceError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Text("Changes take effect on the next sync. Save Settings to keep them after quitting.").font(.caption)
        }.padding()
    }
    private var hosts: some View {
        VStack(alignment: .leading) {
            HStack { Text("Source hosts").font(.title2); Spacer(); Button("Add Host") { controller.configuration.hosts.append(SourceHost()) } }
            ScrollView {
                ForEach($controller.configuration.hosts) { $host in
                    GroupBox {
                        VStack(alignment: .leading) {
                            HStack { TextField("Display name", text: $host.name); Button("Remove") { controller.configuration.hosts.removeAll { $0.id == host.id } } }
                            HStack { TextField("Hostname or SSH alias", text: $host.address); TextField("Username (optional)", text: $host.user); TextField("Port", value: $host.port, format: .number).frame(width: 80) }
                            HStack { TextField("Private key path (optional; uses SSH config by default)", text: $host.identityFile); Button("Choose Key…") { if let path = choosePath(directory: false) { host.identityFile = path } } }
                            HStack {
                                Button("Add Key to Agent / Keychain") { controller.addKey(host) }.disabled(host.identityFile.isEmpty || controller.setupBusy)
                                Button("Test Connection") { controller.test(host) }.disabled(host.validation != nil || controller.setupBusy)
                            }
                            if let error = host.validation { Text(error).font(.caption).foregroundStyle(.red) }
                        }.padding(4)
                    }
                }
            }
            Text(controller.setupStatus).font(.caption).textSelection(.enabled)
            Button("Save Settings") { controller.save() }
        }.padding()
    }
    private var jobs: some View {
        VStack(alignment: .leading) {
            HStack { Text("Sync entries").font(.title2); Spacer(); Button("Add Sync") { var job = SyncJob(); job.hostID = controller.configuration.hosts.first?.id; controller.configuration.jobs.append(job) } }
            ScrollView {
                ForEach($controller.configuration.jobs) { $job in
                    GroupBox {
                        VStack(alignment: .leading) {
                            HStack { Toggle("", isOn: $job.enabled).labelsHidden(); TextField("Name", text: $job.name); Button("Remove") { controller.configuration.jobs.removeAll { $0.id == job.id } } }
                            Picker("Source host", selection: $job.hostID) {
                                Text("Choose host").tag(Optional<UUID>.none)
                                ForEach(controller.configuration.hosts) { host in Text(host.name).tag(Optional(host.id)) }
                            }
                            TextField("Absolute remote path, e.g. /srv/exports/report.json", text: $job.remotePath)
                            Toggle("Download a folder recursively", isOn: $job.isFolder)
                            HStack { TextField("Local target path", text: $job.destinationPath); Button("Choose Target…") { if let path = choosePath(directory: job.isFolder, save: !job.isFolder) { job.destinationPath = path } } }
                            if let error = job.validation { Text(error).font(.caption).foregroundStyle(.red) }
                            if let result = controller.results[job.id] { Text("\(result.date.formatted()): \(result.message)").font(.caption).foregroundStyle(result.failed ? .red : .secondary).textSelection(.enabled) }
                        }.padding(4)
                    }
                }
            }
            Text("Files replace the chosen target only when changed. Folders merge their contents into the target; local-only files remain. Folder updates are atomic per file, not for the entire folder.").font(.caption)
            HStack { Button("Save Settings") { controller.save() }; Button("Sync Now") { controller.syncNow() }.disabled(controller.isSyncing) }
        }.padding()
    }
}

struct SSHGuide: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Set up passwordless sync").font(.title2)
                Text("Run these steps in Terminal, replacing the example host and username. Keep a passphrase on your private key; macOS Keychain can remember it.")
                Text("1. Create a dedicated key (choose a new filename; do not overwrite an existing key).")
                command("ssh-keygen -t ed25519 -f ~/.ssh/tether")
                Text("2. Install the public key on the remote account. This step asks for your remote password. Only share the .pub file; never copy your private key to the server.")
                command("cat ~/.ssh/tether.pub | ssh user@example.com 'umask 077; mkdir -p ~/.ssh; cat >> ~/.ssh/authorized_keys'")
                Text("3. Store the key passphrase in Keychain and load the key into the SSH agent. Enter the passphrase in Terminal when asked. The button in SSH Hosts also tries this command, but Terminal is needed for an interactive passphrase prompt.")
                command("ssh-add --apple-use-keychain ~/.ssh/tether")
                Text("4. Add this block to ~/.ssh/config (use your actual hostname, username and key path).")
                command("Host my-sync-server\n    HostName example.com\n    User user\n    IdentityFile ~/.ssh/tether\n    AddKeysToAgent yes\n    UseKeychain yes")
                Text("5. Establish host trust interactively. Verify the fingerprint with the server administrator before accepting it. Tether never accepts an unknown or changed host key automatically.")
                command("ssh my-sync-server true")
                Text("6. Confirm it works without prompts, then add my-sync-server as the host address in Settings and click Test Connection.")
                command("ssh -o BatchMode=yes -o StrictHostKeyChecking=yes my-sync-server true")
                Text("For a custom port use ssh -p PORT during setup and set the same port in SSH Hosts. Leave the private key field empty to use ~/.ssh/config. Keychain stores the key’s passphrase; the private key remains on disk. The remote account needs read permission for every source. If authentication fails after a restart, repeat ssh-add and check your SSH config. Hardware keys or server policies requiring interactive verification cannot run unattended.").font(.caption)
            }.padding()
        }
    }
    private func command(_ value: String) -> some View { Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Color.secondary.opacity(0.1)).cornerRadius(6) }
}

@MainActor
private func tetherIcon() -> NSImage? {
    guard let url = Bundle.main.url(forResource: "Tether", withExtension: "icns") else { return nil }
    return NSImage(contentsOf: url)
}

@MainActor
final class TetherAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let icon = tetherIcon() { NSApp.applicationIconImage = icon }
    }
}

@MainActor
private func showAboutTether() {
    var options: [NSApplication.AboutPanelOptionKey: Any] = [.applicationName: "Tether"]
    if let icon = tetherIcon() { options[.applicationIcon] = icon }
    NSApp.orderFrontStandardAboutPanel(options: options)
    NSApp.activate(ignoringOtherApps: true)
}

struct MenuContent: View {
    @ObservedObject var controller: SyncController
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(controller.status)
        Button("Sync Now") { controller.syncNow() }.disabled(controller.isSyncing)
        Toggle("Automatic Sync", isOn: $controller.configuration.automatic).onChange(of: controller.configuration.automatic) { _ in controller.save() }
        Divider()
        Button("Settings…") {
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        }.keyboardShortcut(",")
        Button("About Tether") { showAboutTether() }
        Divider()
        Button("Quit Tether") { NSApplication.shared.terminate(nil) }
    }
}

@main
struct TetherApp: App {
    @NSApplicationDelegateAdaptor(TetherAppDelegate.self) private var appDelegate
    @StateObject private var controller = SyncController()
    var body: some Scene {
        MenuBarExtra("Tether", systemImage: controller.isSyncing ? "arrow.triangle.2.circlepath" : "arrow.down.doc") {
            MenuContent(controller: controller)
        }
        Window("Tether Settings", id: "settings") {
            SettingsView(controller: controller)
        }.windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Tether") { showAboutTether() }
            }
        }
    }
}
