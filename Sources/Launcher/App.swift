import AppKit
import LauncherCore

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let manager = ServiceManager()
    private var menu: MenuController?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeMainMenu()
        menu = MenuController(manager: manager)
        manager.startPolling()
    }

    /// Never shown, since this is a menu bar app, but without it the windows don't
    /// get standard shortcuts like paste and close.
    private static func makeMainMenu() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let find = edit.addItem(
            withTitle: "Find",
            action: #selector(NSTextView.performTextFinderAction(_:)),
            keyEquivalent: "f"
        )
        find.tag = NSTextFinder.Action.showFindInterface.rawValue

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let main = NSMenu()
        for submenu in [edit, window] {
            main.addItem(withTitle: submenu.title, action: nil, keyEquivalent: "").submenu = submenu
        }
        return main
    }
}
