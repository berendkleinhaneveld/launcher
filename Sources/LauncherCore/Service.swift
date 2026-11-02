import Foundation

/// One `[section]` of the config file.
public struct Service: Equatable, Sendable {
    public enum Restart: String, CaseIterable, Sendable {
        case no
        case onFailure = "on-failure"
        case always
    }

    public var name: String
    public var command: String
    /// Empty means the home directory.
    public var directory: String
    /// Empty means `~/Library/Logs/Launcher/<slug>.log`.
    public var log: String
    public var autostart: Bool
    public var restart: Restart
    public var env: [String: String]
    /// Environment variable name to keychain item name. Only the item's name is ever
    /// stored; the value is read from the keychain each time the service launches.
    public var secrets: [String: String]

    public init(
        name: String,
        command: String,
        directory: String = "",
        log: String = "",
        autostart: Bool = false,
        restart: Restart = .no,
        env: [String: String] = [:],
        secrets: [String: String] = [:]
    ) {
        self.name = name
        self.command = command
        self.directory = directory
        self.log = log
        self.autostart = autostart
        self.restart = restart
        self.env = env
        self.secrets = secrets
    }

    /// Secret names end up in a shell script, so they have to be real variable names.
    public static func isVariableName(_ name: String) -> Bool {
        name.wholeMatch(of: /[A-Za-z_][A-Za-z0-9_]*/) != nil
    }

    /// Names are free-form; launchd labels and file names use this instead.
    public var slug: String { Service.slug(for: name) }

    public static func slug(for name: String) -> String {
        let mapped = name.lowercased().unicodeScalars.map { scalar -> Character in
            scalar.isASCII && CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        }
        return String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
    }
}
