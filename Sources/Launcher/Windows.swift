import AppKit
import LauncherCore
import SwiftUI

/// Opens the log and editor windows, keeping at most one of each per service.
@MainActor
final class Windows {
    private let manager: ServiceManager
    private var open: [String: NSWindowController] = [:]

    init(manager: ServiceManager) {
        self.manager = manager
    }

    func showLogs(for service: Service) {
        let url = manager.layout.logURL(for: service)
        show(key: "log:" + service.slug) {
            LogWindowController(name: service.name, url: url)
        }
    }

    /// `nil` adds a new service.
    func showEditor(for service: Service?) {
        show(key: "editor:" + (service?.slug ?? "")) { [unowned self] in
            self.makeEditor(for: service)
        }
    }

    private func show(key: String, make: () -> NSWindowController) {
        let controller = open[key] ?? make()
        open[key] = controller
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: controller.window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.open[key] = nil }
        }
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private func makeEditor(for service: Service?) -> NSWindowController {
        let manager = self.manager
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.title = service?.name ?? "Add Service"

        let form = ServiceForm(
            original: service,
            isRunning: service.map { manager.status(of: $0).isRunning } ?? false,
            taken: Set(manager.services.map(\.slug)).subtracting([service?.slug].compactMap { $0 }),
            defaultLog: { manager.layout.defaultLogURL(forName: $0).path },
            onSave: { [weak window] edited, values, startNew in
                do {
                    // Asked before saving, because saving a rename stops the old job.
                    let wasRunning = service.map { manager.status(of: $0).isRunning } ?? false
                    try await manager.save(edited, replacing: service, storing: values)
                    // A running service needs a restart to pick up the changes.
                    if startNew || wasRunning {
                        await manager.start(edited)
                    }
                    window?.close()
                    return nil
                } catch {
                    return String(describing: error)
                }
            },
            onRemove: { [weak window] in
                guard let window, let service else { return }
                Self.confirmRemoval(of: service, in: window) {
                    Task {
                        try? await manager.remove(service)
                        window.close()
                    }
                }
            },
            onCancel: { [weak window] in window?.close() }
        )
        let content = NSHostingController(rootView: form)
        window.contentViewController = content
        window.setContentSize(content.view.fittingSize)
        window.center()
        return NSWindowController(window: window)
    }

    private static func confirmRemoval(of service: Service, in window: NSWindow, then remove: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "Remove \(service.name)?"
        alert.informativeText = "This stops it, deletes its launchd agent and removes it from the config file. Its log file is kept."
        if service.secrets.values.contains(where: { $0.hasPrefix(Keychain.itemPrefix) }) {
            alert.informativeText += " Secrets Launcher stored for it are deleted from the keychain."
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { remove() }
        }
    }
}

/// Takes a pasted secret. The value is masked and only reaches the keychain when the
/// form behind this sheet is saved.
private struct SecretSheet: View {
    let onSet: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var value = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set Secret").font(.headline)
            Form {
                TextField("Variable", text: $name, prompt: Text("API_KEY"))
                SecureField("Value", text: $value, prompt: Text("Paste it here"))
            }
            if let error {
                Text(error).foregroundStyle(.red).font(.callout)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Set", action: set)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func set() {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Pasted keys often come with a stray newline.
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Service.isVariableName(name) else {
            error = "The variable needs a name like API_KEY."
            return
        }
        if let problem = Keychain.problem(with: value) {
            error = problem
            return
        }
        onSet(name, value)
        dismiss()
    }
}

/// The form behind both Add Service and Configure.
private struct ServiceForm: View {
    let original: Service?
    let isRunning: Bool
    let taken: Set<String>
    let defaultLog: (String) -> String
    /// Gets the edited service, new secret values, and whether to start a new service.
    let onSave: (Service, [String: String], Bool) async -> String?
    let onRemove: () -> Void
    let onCancel: () -> Void

    @State private var name: String
    @State private var command: String
    @State private var directory: String
    @State private var restart: Service.Restart
    @State private var autostart: Bool
    @State private var log: String
    @State private var env: String
    @State private var secrets: String
    /// New values by keychain item, kept here until Save so Cancel stores nothing.
    @State private var newSecretValues: [String: String] = [:]
    @State private var isSettingSecret = false
    @State private var error: String?
    @State private var saving = false

    init(
        original: Service?,
        isRunning: Bool,
        taken: Set<String>,
        defaultLog: @escaping (String) -> String,
        onSave: @escaping (Service, [String: String], Bool) async -> String?,
        onRemove: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.original = original
        self.isRunning = isRunning
        self.taken = taken
        self.defaultLog = defaultLog
        self.onSave = onSave
        self.onRemove = onRemove
        self.onCancel = onCancel
        _name = State(initialValue: original?.name ?? "")
        _command = State(initialValue: original?.command ?? "")
        _directory = State(initialValue: original?.directory ?? "")
        _restart = State(initialValue: original?.restart ?? .no)
        _autostart = State(initialValue: original?.autostart ?? false)
        _log = State(initialValue: original?.log ?? "")
        _env = State(initialValue: Self.lines(for: original?.env ?? [:]))
        _secrets = State(initialValue: Self.lines(for: original?.secrets ?? [:]))
    }

    private static func lines(for pairs: [String: String]) -> String {
        pairs.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
    }

    private var saveTitle: String {
        if original == nil { return "Add" }
        return isRunning ? "Save & Restart" : "Save"
    }

    private var logPrompt: String {
        (defaultLog(name.isEmpty ? "name" : name) as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("Web server"))
                    TextField(text: $command, prompt: Text("npm run dev")) {
                        Text("Command").font(.body)
                    }
                    .font(.system(.body, design: .monospaced))
                    HStack {
                        TextField("Directory", text: $directory, prompt: Text("~"))
                        Button("Choose…", action: chooseDirectory)
                    }
                }
                Section {
                    Picker("Restart", selection: $restart) {
                        Text("Never").tag(Service.Restart.no)
                        Text("On failure").tag(Service.Restart.onFailure)
                        Text("Always").tag(Service.Restart.always)
                    }
                    Toggle("Start at login", isOn: $autostart)
                    TextField("Log file", text: $log, prompt: Text(logPrompt))
                }
                Section("Environment, one NAME=value per line") {
                    TextEditor(text: $env)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 44)
                        .scrollContentBackground(.hidden)
                }
                Section {
                    TextEditor(text: $secrets)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 44)
                        .scrollContentBackground(.hidden)
                } header: {
                    HStack {
                        Text("Keychain secrets, one NAME=item per line")
                        Spacer()
                        Button("Set Secret…") { isSettingSecret = true }
                            .disabled(Service.slug(for: name).isEmpty)
                            .help("Paste a value to store in the keychain")
                    }
                } footer: {
                    if !newSecretValues.isEmpty {
                        Text("New values are stored in the keychain when you save.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }

            HStack {
                if original != nil {
                    Button("Remove…", role: .destructive, action: onRemove)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                if original == nil {
                    Button("Add & Start") { save(startNew: true) }
                        .disabled(saving)
                }
                Button(saveTitle) { save(startNew: false) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(width: 500, height: error == nil ? 552 : 577)
        .sheet(isPresented: $isSettingSecret) {
            SecretSheet(onSet: setSecret)
        }
    }

    /// Adds or updates the line for `name`. A secret stored by this app keeps its item,
    /// which replaces the value. Items the user made are never overwritten: the
    /// variable moves to a new item instead.
    private func setSecret(name secretName: String, value: String) {
        var lines = secrets.split(whereSeparator: \.isNewline).map(String.init)
        let prefix = secretName + "="
        let existing = lines.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        let item = existing.flatMap { $0.hasPrefix(Keychain.itemPrefix) ? $0 : nil }
            ?? Keychain.item(service: name, secret: secretName)

        lines.removeAll { $0.hasPrefix(prefix) }
        lines.append(prefix + item)
        secrets = lines.joined(separator: "\n")
        newSecretValues[item] = value
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            directory = url.path.hasPrefix(home + "/")
                ? "~" + url.path.dropFirst(home.count)
                : url.path
        }
    }

    private func save(startNew: Bool) {
        do {
            let service = try makeService()
            saving = true
            Task {
                error = await onSave(service, newSecretValues, startNew)
                saving = false
            }
        } catch {
            self.error = error.message
        }
    }

    private struct Invalid: Error {
        let message: String
    }

    private func makeService() throws(Invalid) -> Service {
        // The config is line based, so nothing here may span lines.
        func field(_ text: String) -> String {
            text.split(whereSeparator: \.isNewline).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
        }

        let name = field(self.name).replacing("]", with: "")
        guard !Service.slug(for: name).isEmpty else {
            throw Invalid(message: "The name needs a letter or digit.")
        }
        guard !taken.contains(Service.slug(for: name)) else {
            throw Invalid(message: "There is already a service called \(name).")
        }
        let command = field(self.command)
        guard !command.isEmpty else {
            throw Invalid(message: "The command is empty.")
        }

        let secrets = try pairs(in: self.secrets, format: "NAME=item")
        for (key, item) in secrets where !Service.isVariableName(key) || item.isEmpty {
            throw Invalid(message: "Secret lines look like NAME=item: \(key)=\(item)")
        }

        return Service(
            name: name,
            command: command,
            directory: field(directory),
            log: field(log),
            autostart: autostart,
            restart: restart,
            env: try pairs(in: env, format: "NAME=value"),
            secrets: secrets
        )
    }

    private func pairs(in text: String, format: String) throws(Invalid) -> [String: String] {
        var pairs: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            guard parts.count == 2, !key.isEmpty, !key.contains(" ") else {
                throw Invalid(message: "Lines look like \(format): \(line)")
            }
            pairs[key] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        return pairs
    }
}
