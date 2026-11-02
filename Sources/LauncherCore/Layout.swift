import Foundation

/// Where everything lives, and how a `Service` becomes a launchd job.
public struct Layout: Sendable {
    public var configFile: URL
    /// launchd loads this folder at login, so only autostart services go here.
    public var autostartAgents: URL
    /// Agents that only run on request. `KeepAlive` implies `RunAtLoad`, so these
    /// would start at login too if they lived in `~/Library/LaunchAgents`.
    public var onDemandAgents: URL
    public var logs: URL
    public var labelPrefix: String
    public var shell: String
    /// The `security` tool that reads the keychain.
    public var security: String

    public init(
        configFile: URL,
        autostartAgents: URL,
        onDemandAgents: URL,
        logs: URL,
        labelPrefix: String,
        shell: String,
        security: String = "/usr/bin/security"
    ) {
        self.configFile = configFile
        self.autostartAgents = autostartAgents
        self.onDemandAgents = onDemandAgents
        self.logs = logs
        self.labelPrefix = labelPrefix
        self.shell = shell
        self.security = security
    }

    public static var standard: Layout {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let library = home.appending(path: "Library")
        return Layout(
            configFile: home.appending(path: ".config/launcher/services.conf"),
            autostartAgents: library.appending(path: "LaunchAgents"),
            onDemandAgents: library.appending(path: "Application Support/Launcher/agents"),
            logs: library.appending(path: "Logs/Launcher"),
            labelPrefix: "local.launcher.",
            shell: loginShell()
        )
    }

    private static func loginShell() -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            return String(cString: shell)
        }
        return "/bin/zsh"
    }

    public func label(for service: Service) -> String {
        labelPrefix + service.slug
    }

    public func agentURL(for service: Service) -> URL {
        (service.autostart ? autostartAgents : onDemandAgents)
            .appending(path: label(for: service) + ".plist")
    }

    /// Where the agent must not be, for when `autostart` has been flipped.
    func staleAgentURL(for service: Service) -> URL {
        (service.autostart ? onDemandAgents : autostartAgents)
            .appending(path: label(for: service) + ".plist")
    }

    public func logURL(for service: Service) -> URL {
        service.log.isEmpty
            ? defaultLogURL(forName: service.name)
            : URL(fileURLWithPath: expand(service.log))
    }

    public func defaultLogURL(forName name: String) -> URL {
        logs.appending(path: Service.slug(for: name) + ".log")
    }

    public func workingDirectory(for service: Service) -> String {
        expand(service.directory.isEmpty ? "~" : service.directory)
    }

    public func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    public func agent(for service: Service) -> [String: Any] {
        var environment = service.env
        environment["LAUNCHER_COMMAND"] = service.command
        environment["SHELL"] = shell
        // Python block-buffers stdout when it's a file, which makes logs lag.
        environment["PYTHONUNBUFFERED"] = environment["PYTHONUNBUFFERED"] ?? "1"

        var launch = Self.runCommand
        if !service.secrets.isEmpty {
            environment["LAUNCHER_SECRETS"] = secretsScript(for: service)
            launch = #"exec /bin/sh -c "$LAUNCHER_SECRETS""#
        }

        let log = logURL(for: service).path
        var agent: [String: Any] = [
            "Label": label(for: service),
            // launchd's own PATH is minimal, so the interactive login shell supplies
            // the user's. The command itself can't run in that shell, though: interactive
            // shells ignore SIGTERM, so a compound command would only die on launchd's
            // SIGKILL 20 seconds after Stop.
            "ProgramArguments": [shell, "-ilc", launch],
            "EnvironmentVariables": environment,
            "WorkingDirectory": workingDirectory(for: service),
            "StandardOutPath": log,
            "StandardErrorPath": log,
            // Autostart is decided by which folder the agent is in, so loading always runs it.
            "RunAtLoad": true,
        ]
        switch service.restart {
        case .no: break
        case .onFailure: agent["KeepAlive"] = ["SuccessfulExit": false]
        case .always: agent["KeepAlive"] = true
        }
        return agent
    }

    private static let runCommand = #"exec "$SHELL" -c "$LAUNCHER_COMMAND""#

    /// Reads the secrets when the service launches, so the agent on disk only holds
    /// the names of keychain items. It's POSIX sh whatever the user's shell is, and a
    /// failed lookup ends it, so a service never runs with a secret missing.
    func secretsScript(for service: Service) -> String {
        let lookups = service.secrets.keys.sorted().map { name in
            let item = "'" + service.secrets[name]!.replacing("'", with: #"'\''"#) + "'"
            return """
                \(name)=$('\(security)' find-generic-password -s \(item) -w) || {
                    status=$?
                    echo "Launcher: can't read \(name) from keychain item "\(item) >&2
                    exit $status
                }
                export \(name)
                """
        }
        return (lookups + [Self.runCommand]).joined(separator: "\n")
    }

    public func agentData(for service: Service) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: agent(for: service),
            format: .xml,
            options: 0
        )
    }
}
