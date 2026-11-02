import Foundation

/// Keeps launchd in step with the config file and tracks what each service is doing.
/// Services outlive this object: launchd owns them, so quitting the app stops nothing.
@MainActor
public final class ServiceManager {
    public let layout: Layout
    public private(set) var services: [Service] = []
    public private(set) var configError: String?
    public var onChange: () -> Void = {}

    private enum Transition { case starting, stopping }

    private var transitions: [String: Transition] = [:]
    private var launchErrors: [String: String] = [:]
    private var launchedAt: [String: Date] = [:]
    private var jobs: [String: JobStatus] = [:]
    private var configText: String?
    private var refreshing = false
    private var refreshAgain = false
    private var timer: Timer?

    public init(layout: Layout = .standard) {
        self.layout = layout
    }

    public func status(of service: Service) -> ServiceStatus {
        switch transitions[service.slug] {
        case .starting: return .starting
        case .stopping: return .stopping
        case nil: break
        }
        if let message = launchErrors[service.slug] {
            return .failed(message)
        }
        return ServiceStatus(
            job: jobs[layout.label(for: service)],
            restart: service.restart,
            launchedAt: launchedAt[service.slug]
        )
    }

    // MARK: Refreshing

    public func startPolling() {
        createConfigIfNeeded()
        // launchd can't push state changes to us, and the .common run loop mode keeps
        // this ticking while the menu is open.
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Task { await refresh() }
    }

    public func refresh() async {
        guard !refreshing else {
            refreshAgain = true
            return
        }
        refreshing = true
        repeat {
            refreshAgain = false
            await reloadConfigIfChanged()
            if let jobs = await Launchctl.list(prefix: layout.labelPrefix) {
                self.jobs = jobs
            }
        } while refreshAgain
        refreshing = false
        onChange()
    }

    private func createConfigIfNeeded() {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: layout.configFile.path) else { return }
        try? manager.createDirectory(
            at: layout.configFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? ConfigFile.starter.write(to: layout.configFile, atomically: true, encoding: .utf8)
    }

    private func reloadConfigIfChanged() async {
        guard let text = try? String(contentsOf: layout.configFile, encoding: .utf8) else {
            // Keep the last good services: an unreadable file must never look like
            // "everything was removed", which would stop them all.
            configError = "Can't read \(layout.configFile.path)"
            configText = nil
            return
        }
        guard text != configText else { return }
        configText = text
        do {
            services = try ConfigFile.parse(text)
            configError = nil
            await syncAgents()
        } catch {
            configError = String(describing: error)
        }
    }

    /// Makes the agents on disk match the config. launchd keeps using the definition it
    /// loaded, so running services only change on restart. Agents whose service left
    /// the config are stopped and deleted.
    private func syncAgents() async {
        for service in services {
            try? writeAgent(service)
        }

        let wanted = Set(services.map { layout.label(for: $0) })
        var labels = Set(jobs.keys)
        if let loaded = await Launchctl.list(prefix: layout.labelPrefix) {
            labels.formUnion(loaded.keys)
        }
        let folders = [layout.autostartAgents, layout.onDemandAgents]
        for folder in folders {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for file in files where file.hasPrefix(layout.labelPrefix) && file.hasSuffix(".plist") {
                labels.insert(String(file.dropLast(".plist".count)))
            }
        }
        for label in labels.subtracting(wanted) {
            await Launchctl.bootout(label)
            for folder in folders {
                try? FileManager.default.removeItem(at: folder.appending(path: label + ".plist"))
            }
            jobs[label] = nil
        }
    }

    private func writeAgent(_ service: Service) throws {
        let manager = FileManager.default
        let url = layout.agentURL(for: service)
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try layout.agentData(for: service)
        // Rewriting an unchanged agent would re-trigger the system's login item notice.
        if (try? Data(contentsOf: url)) != data {
            try data.write(to: url, options: .atomic)
        }
        try? manager.removeItem(at: layout.staleAgentURL(for: service))
    }

    // MARK: Actions

    /// Starts the service from its current config, replacing any running instance.
    public func start(_ service: Service) async {
        let slug = service.slug
        guard transitions[slug] == nil else { return }
        transitions[slug] = .starting
        launchErrors[slug] = nil
        onChange()

        do {
            try prepare(service)
            let label = layout.label(for: service)
            await Launchctl.bootout(label)
            await Launchctl.enable(label)
            launchErrors[slug] = await Launchctl.bootstrap(layout.agentURL(for: service))
        } catch {
            launchErrors[slug] = String(describing: error)
        }

        launchedAt[slug] = Date()
        transitions[slug] = nil
        await refresh()
    }

    private func prepare(_ service: Service) throws {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        let directory = layout.workingDirectory(for: service)
        guard manager.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ConfigError("Directory not found: \(directory)")
        }
        try manager.createDirectory(
            at: layout.logURL(for: service).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeAgent(service)
    }

    /// launchd only leaves a job alone once it's unloaded. Killing it would count as a
    /// failure and `KeepAlive` would bring it straight back.
    public func stop(_ service: Service) async {
        let slug = service.slug
        guard transitions[slug] == nil else { return }
        transitions[slug] = .stopping
        launchErrors[slug] = nil
        onChange()

        await Launchctl.bootout(layout.label(for: service))

        transitions[slug] = nil
        await refresh()
    }

    /// Writes `service` to the config, renaming the section `original` if given.
    /// `values` holds new secret values by keychain item, stored before the config
    /// is touched so it never points at an item that failed to save.
    public func save(
        _ service: Service,
        replacing original: Service? = nil,
        storing values: [String: String] = [:]
    ) async throws {
        var file = try currentFile()
        try file.save(service, replacing: original?.name)
        _ = try ConfigFile.parse(file.text)
        for (item, value) in values where service.secrets.values.contains(item) {
            try await Keychain.store(value, item: item, security: layout.security)
        }
        try write(file)
        await refresh()
    }

    /// Removes the service from the config; the sync stops it and deletes its agent.
    /// Secrets this app stored for it go too, unless another service uses them. Items
    /// the user made are left alone, and so is everything when a section is hand-deleted.
    public func remove(_ service: Service) async throws {
        var file = try currentFile()
        file.remove(service.name)
        try write(file)

        let otherServices = services.filter { $0.slug != service.slug }
        let elsewhere = Set(otherServices.flatMap { $0.secrets.values })
        for item in Set(service.secrets.values).subtracting(elsewhere)
        where item.hasPrefix(Keychain.itemPrefix) {
            await Keychain.delete(item: item, security: layout.security)
        }
        await refresh()
    }

    private func currentFile() throws -> ConfigFile {
        ConfigFile(text: try String(contentsOf: layout.configFile, encoding: .utf8))
    }

    private func write(_ file: ConfigFile) throws {
        // The config may be a symlink into someone's dotfiles.
        let target = layout.configFile.resolvingSymlinksInPath()
        try file.text.write(to: target, atomically: true, encoding: .utf8)
    }
}
