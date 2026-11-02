import Foundation

public struct ConfigError: Error, Equatable, CustomStringConvertible {
    public let line: Int?
    public let message: String

    public init(line: Int? = nil, _ message: String) {
        self.line = line
        self.message = message
    }

    public var description: String {
        line.map { "Line \($0): \(message)" } ?? message
    }
}

/// The plain-text config, kept as lines so that saving from the UI only touches
/// the keys that changed and leaves comments, order and formatting alone.
public struct ConfigFile {
    public static let starter = """
        # Launcher services. Each [section] is one service, and its name is what the
        # menu shows. Everything after the "=" is taken literally. Only `command` is
        # required. Edits are picked up automatically; a running service needs a
        # restart to use them.
        #
        # [Web server]
        # command = npm run dev
        # directory = ~/Developer/site
        # restart = on-failure
        # autostart = yes
        # log = ~/Library/Logs/web.log
        # env.PORT = 3000
        # secret.API_KEY = my-keychain-item
        #
        # restart:   no (default), on-failure or always
        # autostart: yes starts it at login, no (default) only when you ask
        # log:       defaults to ~/Library/Logs/Launcher/<name>.log
        # secret:    sets a variable from a keychain item, read at each launch

        """

    private var lines: [String]

    public init(text: String) {
        lines = text.components(separatedBy: "\n")
    }

    public var text: String { lines.joined(separator: "\n") }

    // MARK: Reading

    public static func parse(_ text: String) throws -> [Service] {
        var services: [Service] = []
        var current: Service?
        var currentLine = 0

        func finishSection() throws {
            guard let service = current else { return }
            guard !service.command.isEmpty else {
                throw ConfigError(line: currentLine, "[\(service.name)] has no command")
            }
            if let other = services.first(where: { $0.slug == service.slug }) {
                throw ConfigError(line: currentLine, "[\(service.name)] clashes with [\(other.name)]")
            }
            if let name = service.env.keys.sorted().first(where: { service.secrets[$0] != nil }) {
                throw ConfigError(line: currentLine, "[\(service.name)] sets \(name) as both env and secret")
            }
            services.append(service)
        }

        for (index, raw) in text.components(separatedBy: "\n").enumerated() {
            let number = index + 1
            switch Line(raw) {
            case .blank, .comment:
                continue
            case .header(let name):
                try finishSection()
                guard !Service.slug(for: name).isEmpty else {
                    throw ConfigError(line: number, "a service name needs a letter or digit")
                }
                current = Service(name: name, command: "")
                currentLine = number
            case .entry(let key, let value):
                guard var service = current else {
                    throw ConfigError(line: number, "\"\(key)\" is outside any [section]")
                }
                try apply(key, value, to: &service, line: number)
                current = service
            case .invalid:
                throw ConfigError(line: number, "expected [name] or key = value")
            }
        }
        try finishSection()
        return services
    }

    private static func apply(_ key: String, _ value: String, to service: inout Service, line: Int) throws {
        switch key {
        case "command":
            service.command = value
        case "directory":
            service.directory = value
        case "log":
            service.log = value
        case "autostart":
            switch value.lowercased() {
            case "yes", "true": service.autostart = true
            case "no", "false": service.autostart = false
            default: throw ConfigError(line: line, "autostart must be yes or no")
            }
        case "restart":
            guard let restart = Service.Restart(rawValue: value.lowercased()) else {
                throw ConfigError(line: line, "restart must be no, on-failure or always")
            }
            service.restart = restart
        case _ where key.hasPrefix("secret."):
            let name = String(key.dropFirst("secret.".count))
            guard Service.isVariableName(name) else {
                throw ConfigError(line: line, "\"\(name)\" isn't a valid variable name")
            }
            guard !value.isEmpty else {
                throw ConfigError(line: line, "\(key) needs a keychain item name")
            }
            service.secrets[name] = value
        default:
            guard key.hasPrefix("env."), key.count > 4 else {
                throw ConfigError(line: line, "unknown key \"\(key)\"")
            }
            service.env[String(key.dropFirst(4))] = value
        }
    }

    /// The keys a service writes out; defaults are left unsaid.
    private static func fields(of service: Service) -> [(key: String, value: String)] {
        var fields = [(key: "command", value: service.command)]
        if !service.directory.isEmpty { fields.append(("directory", service.directory)) }
        if service.restart != .no { fields.append(("restart", service.restart.rawValue)) }
        if service.autostart { fields.append(("autostart", "yes")) }
        if !service.log.isEmpty { fields.append(("log", service.log)) }
        for key in service.env.keys.sorted() {
            fields.append(("env.\(key)", service.env[key]!))
        }
        for key in service.secrets.keys.sorted() {
            fields.append(("secret.\(key)", service.secrets[key]!))
        }
        return fields
    }

    // MARK: Editing

    /// Adds `service`, or updates the section called `oldName` in place.
    public mutating func save(_ service: Service, replacing oldName: String? = nil) throws {
        let services = try Self.parse(text)
        guard let oldName,
            let old = services.first(where: { $0.name == oldName }),
            let header = headerIndex(of: oldName)
        else {
            append(service)
            return
        }

        let before = Dictionary(uniqueKeysWithValues: Self.fields(of: old).map { ($0.key, $0.value) })
        let after = Self.fields(of: service)
        for key in before.keys where !after.contains(where: { $0.key == key }) {
            removeEntries(key, under: header)
        }
        for (key, value) in after where before[key] != value {
            setEntry(key, value, under: header)
        }
        lines[header] = "[\(service.name)]"
    }

    public mutating func remove(_ name: String) {
        guard let header = headerIndex(of: name) else { return }

        var start = header
        while start > 0, case .comment = Line(lines[start - 1]) { start -= 1 }

        // Comments directly above the next section belong to that section.
        var end = sectionEnd(after: header)
        if end < lines.count {
            while end > header + 1, Line(lines[end - 1]).isTrivia { end -= 1 }
        }

        lines.removeSubrange(start..<end)

        // Don't leave two blank lines where the section was.
        if start > 0, start < lines.count, Line(lines[start - 1]).isBlank, Line(lines[start]).isBlank {
            lines.remove(at: start)
        }
    }

    private mutating func append(_ service: Service) {
        while let last = lines.last, Line(last).isBlank { lines.removeLast() }
        if !lines.isEmpty { lines.append("") }
        lines.append("[\(service.name)]")
        lines += Self.fields(of: service).map { "\($0.key) = \($0.value)" }
        lines.append("")
    }

    private mutating func setEntry(_ key: String, _ value: String, under header: Int) {
        let body = (header + 1)..<sectionEnd(after: header)
        let entry = "\(key) = \(value)"
        if let index = body.first(where: { Line(lines[$0]).key == key }) {
            lines[index] = entry
        } else {
            let last = body.last(where: { Line(lines[$0]).key != nil }) ?? header
            lines.insert(entry, at: last + 1)
        }
    }

    private mutating func removeEntries(_ key: String, under header: Int) {
        let body = (header + 1)..<sectionEnd(after: header)
        for index in body.reversed() where Line(lines[index]).key == key {
            lines.remove(at: index)
        }
    }

    private func headerIndex(of name: String) -> Int? {
        lines.firstIndex { line in
            if case .header(name) = Line(line) { return true }
            return false
        }
    }

    private func sectionEnd(after header: Int) -> Int {
        lines[(header + 1)...].firstIndex { line in
            if case .header = Line(line) { return true }
            return false
        } ?? lines.count
    }
}

private enum Line {
    case blank
    case comment
    case header(String)
    case entry(key: String, value: String)
    case invalid

    init(_ raw: String) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty {
            self = .blank
        } else if line.hasPrefix("#") || line.hasPrefix(";") {
            self = .comment
        } else if line.hasPrefix("["), line.hasSuffix("]") {
            self = .header(line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces))
        } else if let equals = line.firstIndex(of: "=") {
            self = .entry(
                key: line[..<equals].trimmingCharacters(in: .whitespaces),
                value: line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            )
        } else {
            self = .invalid
        }
    }

    var key: String? {
        if case .entry(let key, _) = self { return key }
        return nil
    }

    var isBlank: Bool {
        if case .blank = self { return true }
        return false
    }

    var isTrivia: Bool {
        switch self {
        case .blank, .comment: return true
        default: return false
        }
    }
}
