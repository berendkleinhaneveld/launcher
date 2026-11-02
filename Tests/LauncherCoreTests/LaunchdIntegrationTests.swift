import Foundation
import Testing

@testable import LauncherCore

/// Runs real jobs through launchd, in a throwaway folder and label namespace.
@MainActor
@Suite(.serialized) final class LaunchdIntegrationTests {
    let root: URL
    let layout: Layout
    let manager: ServiceManager

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "launcher-tests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        layout = Layout(
            configFile: root.appending(path: "config/services.conf"),
            autostartAgents: root.appending(path: "autostart"),
            onDemandAgents: root.appending(path: "on-demand"),
            logs: root.appending(path: "logs"),
            labelPrefix: "local.launcher-test.\(UInt32.random(in: 0...UInt32.max)).",
            shell: "/bin/zsh"
        )
        manager = ServiceManager(layout: layout)
        try FileManager.default.createDirectory(
            at: layout.configFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ConfigFile.starter.write(to: layout.configFile, atomically: true, encoding: .utf8)
    }

    /// Synchronous, because a task started here could outlive the test process and
    /// leave real jobs behind in launchd.
    deinit {
        for name in ["probe", "renamed"] {
            let bootout = Process()
            bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            bootout.arguments = ["bootout", "gui/\(getuid())/\(layout.labelPrefix)\(name)"]
            bootout.standardError = FileHandle.nullDevice
            try? bootout.run()
            bootout.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: root)
    }

    private func service(_ command: String, name: String = "probe", restart: Service.Restart = .no) async throws -> Service {
        let service = Service(name: name, command: command, restart: restart)
        try await manager.save(service)
        return service
    }

    private func wait(
        _ service: Service,
        timeout: TimeInterval = 8,
        until condition: (ServiceStatus) -> Bool
    ) async throws -> ServiceStatus {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            await manager.refresh()
            let status = manager.status(of: service)
            if condition(status) { return status }
            try await Task.sleep(for: .milliseconds(100))
        }
        let status = manager.status(of: service)
        Issue.record("timed out in state \(status)")
        return status
    }

    @Test func startsRunsAndStops() async throws {
        let service = try await service("echo hello; while true; do sleep 1; done")
        #expect(manager.status(of: service) == .stopped)

        await manager.start(service)
        #expect(manager.status(of: service) == .starting)
        _ = try await wait(service) { $0.isRunning }

        let log = try String(contentsOf: layout.logURL(for: service), encoding: .utf8)
        #expect(log == "hello\n")

        let before = Date()
        await manager.stop(service)
        #expect(Date().timeIntervalSince(before) < 2, "compound commands must stop on SIGTERM")
        #expect(manager.status(of: service) == .stopped)
    }

    /// Restarting replaces the running instance, however long it takes to shut down.
    @Test func restartWaitsForASlowExit() async throws {
        let service = try await service("trap 'sleep 2; exit 0' TERM; while true; do sleep 0.1; done")
        await manager.start(service)
        _ = try await wait(service) { $0.isRunning }

        await manager.start(service)
        _ = try await wait(service) { $0.isRunning }
    }

    @Test func failureIsReportedAndStopClearsIt() async throws {
        let service = try await service("exit 3")
        await manager.start(service)
        let status = try await wait(service) { $0.isFailed }
        #expect(status == .failed("Exited with code 3"))

        await manager.stop(service)
        #expect(manager.status(of: service) == .stopped)
    }

    @Test func unknownCommandSaysSo() async throws {
        let service = try await service("definitely-not-a-command")
        await manager.start(service)
        let status = try await wait(service) { $0.isFailed }
        #expect(status == .failed("Command not found (exit 127)"))
    }

    @Test func cleanExitFinishes() async throws {
        let service = try await service("true")
        await manager.start(service)
        _ = try await wait(service) { $0 == .finished }
    }

    @Test func onFailureIsRestartedByLaunchd() async throws {
        let marker = root.appending(path: "marker").path
        let service = try await service(
            "if [ -e \(marker) ]; then while true; do sleep 1; done; else touch \(marker); exit 9; fi",
            restart: .onFailure
        )
        await manager.start(service)
        _ = try await wait(service, timeout: 20) { $0.isRunning }
    }

    @Test func missingDirectoryFailsBeforeLaunchd() async throws {
        var service = Service(name: "probe", command: "true", directory: "/no/such/place")
        try await manager.save(service)
        await manager.start(service)
        #expect(manager.status(of: service) == .failed("Directory not found: /no/such/place"))
        service.directory = "/"
        try await manager.save(service, replacing: Service(name: "probe", command: "true", directory: "/no/such/place"))
        await manager.start(service)
        _ = try await wait(service) { $0 == .finished }
    }

    @Test func removingStopsAndDeletesTheAgent() async throws {
        let service = try await service("while true; do sleep 1; done")
        await manager.start(service)
        _ = try await wait(service) { $0.isRunning }
        let agent = layout.agentURL(for: service)
        #expect(FileManager.default.fileExists(atPath: agent.path))

        try await manager.remove(service)

        #expect(manager.services.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: agent.path))
        #expect(await Launchctl.list(prefix: layout.labelPrefix) == [:])
    }

    @Test func renamingARunningServiceStopsTheOldJob() async throws {
        let old = try await service("while true; do sleep 1; done")
        await manager.start(old)
        _ = try await wait(old) { $0.isRunning }

        var new = old
        new.name = "renamed"
        try await manager.save(new, replacing: old)
        await manager.start(new)
        _ = try await wait(new) { $0.isRunning }

        let loaded = await Launchctl.list(prefix: layout.labelPrefix)
        #expect(loaded.map { Array($0.keys) } == [layout.label(for: new)])
    }

    /// A stand-in for `security`: prints the value of the item named by `-s`, or exits
    /// like the real tool does for an unknown item. Tests leave the keychain untouched.
    private func secretsLayout() throws -> (layout: Layout, manager: ServiceManager) {
        let tool = root.appending(path: "fake security")
        try """
            #!/bin/sh
            [ "$3" = "it's mine" ] || { echo "item not found" >&2; exit 44; }
            echo 'hunter2 with spaces'

            """.write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        var layout = layout
        layout.security = tool.path
        return (layout, ServiceManager(layout: layout))
    }

    @Test func secretsReachTheCommandButNotTheDisk() async throws {
        let (layout, manager) = try secretsLayout()
        let service = Service(name: "probe", command: "echo \"[$TOKEN]\"", secrets: ["TOKEN": "it's mine"])
        try await manager.save(service)
        await manager.start(service)
        try await Task.sleep(for: .seconds(1))

        let log = try String(contentsOf: layout.logURL(for: service), encoding: .utf8)
        #expect(log == "[hunter2 with spaces]\n")

        let agent = try String(contentsOf: layout.agentURL(for: service), encoding: .utf8)
        #expect(!agent.contains("hunter2"))
        #expect(!(try String(contentsOf: layout.configFile, encoding: .utf8)).contains("hunter2"))
    }

    @Test func aMissingSecretStopsTheServiceFromRunning() async throws {
        let (layout, manager) = try secretsLayout()
        let service = Service(name: "probe", command: "echo ran", secrets: ["TOKEN": "no such item"])
        try await manager.save(service)
        await manager.start(service)
        try await Task.sleep(for: .seconds(1))
        await manager.refresh()

        #expect(manager.status(of: service) == .failed("Exited with code 44"))
        let log = try String(contentsOf: layout.logURL(for: service), encoding: .utf8)
        #expect(log == "item not found\nLauncher: can't read TOKEN from keychain item no such item\n")
    }

    @Test func hasBrokenConfigKeepsServicesRunning() async throws {
        let service = try await service("while true; do sleep 1; done")
        await manager.start(service)
        _ = try await wait(service) { $0.isRunning }

        try "[broken\n".write(to: layout.configFile, atomically: true, encoding: .utf8)
        await manager.refresh()

        #expect(manager.configError == "Line 1: expected [name] or key = value")
        #expect(manager.services == [service])
        #expect(manager.status(of: service).isRunning)
    }

    @Test func autostartMovesTheAgentToTheLoginFolder() async throws {
        var service = try await service("true")
        #expect(layout.agentURL(for: service).path.contains("/on-demand/"))

        let original = service
        service.autostart = true
        try await manager.save(service, replacing: original)

        let manager = FileManager.default
        #expect(manager.fileExists(atPath: layout.autostartAgents.appending(path: layout.label(for: service) + ".plist").path))
        #expect(!manager.fileExists(atPath: layout.onDemandAgents.appending(path: layout.label(for: service) + ".plist").path))
    }

    @Test func handEditsArePickedUp() async throws {
        await manager.refresh()
        #expect(manager.services.isEmpty)
        try "[manual]\ncommand = true\n".write(to: layout.configFile, atomically: true, encoding: .utf8)
        await manager.refresh()
        #expect(manager.services.map(\.name) == ["manual"])
    }
}
