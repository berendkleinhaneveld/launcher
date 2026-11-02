import Foundation
import Testing

@testable import LauncherCore

/// These use a stand-in for `security`, so running them leaves the keychain alone.
@MainActor
@Suite final class KeychainTests {
    let root: URL
    let tool: URL
    let manager: ServiceManager

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "launcher-keychain-tests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // Records every call, and "stores" whatever is in stdin's -w argument.
        tool = root.appending(path: "security")
        try """
            #!/bin/sh
            echo "$*" >> '\(root.path)/calls'
            case "$1" in
                -i) cat >> '\(root.path)/stdin'; sed -E 's/.* -w "(.*)"$/\\1/' '\(root.path)/stdin' > '\(root.path)/value' ;;
                find-generic-password) cat '\(root.path)/value' ;;
            esac

            """.write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        let config = root.appending(path: "services.conf")
        try "".write(to: config, atomically: true, encoding: .utf8)
        manager = ServiceManager(
            layout: Layout(
                configFile: config,
                autostartAgents: root.appending(path: "autostart"),
                onDemandAgents: root.appending(path: "on-demand"),
                logs: root.appending(path: "logs"),
                labelPrefix: "local.launcher-keychain-test.",
                shell: "/bin/zsh",
                security: tool.path
            ))
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private func read(_ name: String) -> String {
        (try? String(contentsOf: root.appending(path: name), encoding: .utf8)) ?? ""
    }

    @Test func theValueGoesThroughStdinNeverArguments() async throws {
        try await Keychain.store("s3cret", item: "launcher.a.KEY", security: tool.path)
        #expect(read("stdin").contains(#"-w "s3cret""#))
        #expect(!read("calls").contains("s3cret"))
    }

    @Test func aValueThatDoesNotReadBackIsAnError() async throws {
        let broken = root.appending(path: "broken")
        try "#!/bin/sh\necho wrong\n".write(to: broken, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: broken.path)

        await #expect(throws: KeychainError(description: "Couldn't store item in the keychain.")) {
            try await Keychain.store("s3cret", item: "item", security: broken.path)
        }
    }

    @Test func aFailedStoreLeavesTheConfigAlone() async throws {
        let broken = root.appending(path: "broken")
        try "#!/bin/sh\nexit 1\n".write(to: broken, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: broken.path)
        var layout = manager.layout
        layout.security = broken.path
        let manager = ServiceManager(layout: layout)

        let service = Service(name: "a", command: "x", secrets: ["KEY": "launcher.a.KEY"])
        await #expect(throws: KeychainError.self) {
            try await manager.save(service, storing: ["launcher.a.KEY": "s3cret"])
        }
        #expect(read("services.conf").isEmpty)
    }

    @Test func savingStoresOnlyItemsTheServiceStillUses() async throws {
        let service = Service(name: "a", command: "x", secrets: ["KEY": "launcher.a.KEY"])
        try await manager.save(
            service,
            storing: ["launcher.a.KEY": "kept", "launcher.a.GONE": "dropped"]
        )
        #expect(read("stdin").contains("kept"))
        #expect(!read("stdin").contains("dropped"))
        #expect(read("services.conf").contains("secret.KEY = launcher.a.KEY"))
        #expect(!read("services.conf").contains("kept"))
    }

    @Test func removingDeletesOwnItemsOnly() async throws {
        let service = Service(
            name: "a",
            command: "x",
            secrets: ["OWN": "launcher.a.OWN", "SHARED": "launcher.shared", "MINE": "my-own-item"]
        )
        try await manager.save(service)
        try await manager.save(Service(name: "b", command: "x", secrets: ["S": "launcher.shared"]))

        try await manager.remove(service)

        #expect(read("calls").contains("delete-generic-password -a launcher -s launcher.a.OWN"))
        #expect(!read("calls").contains("launcher.shared"))
        #expect(!read("calls").contains("my-own-item"))
    }

    @Test(arguments: [
        ("", "The value is empty."),
        ("café", "Secrets can only contain plain ASCII characters."),
        ("two\nlines", "Secrets can only contain plain ASCII characters."),
        (String(repeating: "x", count: 3500), "That value is too long for the keychain tool."),
        (String(repeating: "\\", count: 1800), "That value is too long for the keychain tool."),
    ])
    func refusesValuesThatWouldNotSurvive(value: String, message: String) {
        #expect(Keychain.problem(with: value) == message)
    }

    @Test func acceptsAwkwardButValidValues() {
        #expect(Keychain.problem(with: #"a'b"c\d $HOME `id` #x"#) == nil)
        #expect(Keychain.problem(with: String(repeating: "x", count: 3000)) == nil)
    }

    @Test func escapesQuotesAndBackslashes() {
        let command = Keychain.storeCommand(value: #"a"b\c"#, item: "i", security: "/s")
        #expect(command == #"add-generic-password -U -a launcher -s "i" -l "i" -T "/s" -w "a\"b\\c""# + "\n")
    }

    @Test func itemNamesIncludeTheService() {
        #expect(Keychain.item(service: "Web server", secret: "API_KEY") == "launcher.web-server.API_KEY")
    }
}
