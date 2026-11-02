import Foundation

public struct KeychainError: Error, Equatable, CustomStringConvertible {
    public let description: String
}

/// Stores secrets pasted into the app. Services read them back with `security`, so
/// `security` has to create the items as well: macOS ties an item to its creator, and an
/// item made by this app would make `security` prompt, which a background service can't
/// answer. The value goes through stdin, because arguments are visible in `ps`.
public enum Keychain {
    /// Marks items this app created, and may therefore change or delete.
    public static let itemPrefix = "launcher."

    private static let account = "launcher"
    /// `security -i` silently splits lines at about 4 KB, which would store a cut-off value.
    private static let maximumLength = 3500

    public static func item(service: String, secret: String) -> String {
        "\(itemPrefix)\(Service.slug(for: service)).\(secret)"
    }

    /// Why a value can't be stored, if it can't.
    public static func problem(with value: String) -> String? {
        if value.isEmpty {
            return "The value is empty."
        }
        // `security -w` prints anything else as hex, so a service would get garbage.
        if !value.utf8.allSatisfy({ (0x20...0x7E).contains($0) }) {
            return "Secrets can only contain plain ASCII characters."
        }
        if quoted(value).utf8.count > maximumLength {
            return "That value is too long for the keychain tool."
        }
        return nil
    }

    /// Adds the item, or updates it if it exists, and reads it back to prove it worked.
    public static func store(_ value: String, item: String, security: String) async throws {
        if let problem = problem(with: value) {
            throw KeychainError(description: problem)
        }
        let command = storeCommand(value: value, item: item, security: security)
        _ = await runProcess(security, ["-i"], input: Data(command.utf8))

        let stored = await runProcess(security, ["find-generic-password", "-s", item, "-w"])
        guard stored.status == 0, stored.output == value + "\n" else {
            throw KeychainError(description: "Couldn't store \(item) in the keychain.")
        }
    }

    public static func delete(item: String, security: String) async {
        _ = await runProcess(security, ["delete-generic-password", "-a", account, "-s", item])
    }

    static func storeCommand(value: String, item: String, security: String) -> String {
        let arguments = [
            "add-generic-password", "-U",
            "-a", account,
            "-s", quoted(item),
            "-l", quoted(item),
            "-T", quoted(security),
            "-w", quoted(value),
        ]
        return arguments.joined(separator: " ") + "\n"
    }

    private static func quoted(_ text: String) -> String {
        let escaped = text.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
