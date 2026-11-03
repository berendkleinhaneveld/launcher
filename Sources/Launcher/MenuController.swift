import AppKit
import LauncherCore
import ServiceManagement

/// The menu bar item and its menu. The menu stays open while statuses change, so rows
/// are updated in place and the menu is only rebuilt when the list of services changes.
@MainActor
final class MenuController: NSObject, NSMenuDelegate {
    private let manager: ServiceManager
    private let windows: Windows
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let icon: StatusIcon
    private let menu = NSMenu()
    private var rows: [ServiceRow] = []
    private var shownError: String?

    private lazy var loginItem = ActionItem("Launch at Login") { [weak self] in
        self?.toggleLaunchAtLogin()
    }

    init(manager: ServiceManager) {
        self.manager = manager
        windows = Windows(manager: manager)
        icon = StatusIcon(button: statusItem.button!)
        super.init()

        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        manager.onChange = { [weak self] in self?.update() }
        rebuild()
        update()
    }

    func menuWillOpen(_ menu: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        Task { await manager.refresh() }
    }

    private func update() {
        if rows.map(\.service) != manager.services || shownError != manager.configError {
            rebuild()
        }
        for row in rows {
            row.update(status: manager.status(of: row.service))
        }
        updateIcon()
    }

    private func updateIcon() {
        let statuses = manager.services.map { manager.status(of: $0) }
        let failed = statuses.filter(\.isFailed).count
        let starting = statuses.filter { $0 == .starting }.count
        let running = statuses.filter(\.isRunning).count

        var parts = ["\(running) running"]
        if starting > 0 { parts.append("\(starting) starting") }
        if failed > 0 { parts.append("\(failed) failed") }

        let attention = failed > 0 || manager.configError != nil
        icon.update(
            badge: attention ? .failed : starting > 0 ? .starting : .none,
            idle: running + starting + failed == 0 && manager.configError == nil,
            description: "Launcher: " + parts.joined(separator: ", ")
        )
    }

    private func rebuild() {
        menu.removeAllItems()

        shownError = manager.configError
        if let error = manager.configError {
            let item = NSMenuItem(title: error, action: nil, keyEquivalent: "")
            item.image = ServiceRow.image(for: .failed(""))
            item.isEnabled = false
            menu.addItem(item)
            menu.addItem(.separator())
        }

        rows = manager.services.map { ServiceRow(service: $0, manager: manager, windows: windows) }
        rows.forEach { menu.addItem($0.item) }
        if rows.isEmpty {
            let empty = NSMenuItem(title: "No services yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }

        menu.addItem(.separator())
        menu.addItem(ActionItem("Add Service…") { [weak self] in
            self?.windows.showEditor(for: nil)
        })
        menu.addItem(ActionItem("Open Config File") { [weak self] in
            self?.openConfigFile()
        })
        menu.addItem(.separator())
        menu.addItem(loginItem)
        menu.addItem(ActionItem("Quit Launcher") {
            NSApp.terminate(nil)
        })
    }

    private func openConfigFile() {
        // The app chosen for `.conf` files, else the default text editor, because
        // out of the box `.conf` may have no app at all.
        let workspace = NSWorkspace.shared
        let file = manager.layout.configFile
        guard let app = workspace.urlForApplication(toOpen: file)
            ?? workspace.urlForApplication(toOpen: .plainText) else { return }
        workspace.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    private func toggleLaunchAtLogin() {
        let app = SMAppService.mainApp
        do {
            if app.status == .enabled {
                try app.unregister()
            } else {
                try app.register()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

/// One service in the menu, with its hover submenu.
@MainActor
private final class ServiceRow {
    let service: Service
    let item: NSMenuItem

    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let start: ActionItem
    private let stop: ActionItem
    private let restart: ActionItem

    init(service: Service, manager: ServiceManager, windows: Windows) {
        self.service = service
        item = NSMenuItem(title: service.name, action: nil, keyEquivalent: "")

        start = ActionItem("Start") { Task { await manager.start(service) } }
        stop = ActionItem("Stop") { Task { await manager.stop(service) } }
        restart = ActionItem("Restart") { Task { await manager.start(service) } }

        let submenu = NSMenu()
        submenu.autoenablesItems = false
        statusLine.isEnabled = false
        submenu.addItem(statusLine)
        submenu.addItem(.separator())
        submenu.addItem(start)
        submenu.addItem(restart)
        submenu.addItem(stop)
        submenu.addItem(.separator())
        submenu.addItem(ActionItem("Show Logs") { windows.showLogs(for: service) })
        submenu.addItem(ActionItem("Configure…") { windows.showEditor(for: service) })
        item.submenu = submenu
    }

    func update(status: ServiceStatus) {
        item.image = Self.image(for: status)
        statusLine.title = status.summary()

        let isBusy = status == .starting || status == .stopping
        start.isHidden = status.isRunning || isBusy
        restart.isHidden = !status.isRunning
        // A failed service can still be loaded and retrying, so it can be stopped as well.
        stop.isHidden = !(status.isRunning || status.isFailed || status == .starting)
        stop.isEnabled = status != .stopping
    }

    /// Shape as well as color, so status doesn't rely on telling colors apart.
    static func image(for status: ServiceStatus) -> NSImage? {
        let symbol: String
        let color: NSColor
        switch status {
        case .running:
            (symbol, color) = ("circle.fill", .systemGreen)
        case .starting, .stopping:
            (symbol, color) = ("circle.dotted", .systemOrange)
        case .failed:
            (symbol, color) = ("exclamationmark.triangle.fill", .systemRed)
        case .stopped, .finished:
            (symbol, color) = ("circle", .tertiaryLabelColor)
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        return NSImage(systemSymbolName: symbol, accessibilityDescription: status.summary())?
            .withSymbolConfiguration(configuration)
    }
}

/// A menu item that runs a closure.
@MainActor
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("not used")
    }

    @objc private func fire() {
        handler()
    }
}
