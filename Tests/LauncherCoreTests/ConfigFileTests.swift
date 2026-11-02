import Foundation
import Testing

@testable import LauncherCore

@Suite struct ParsingTests {
    @Test func readsEveryKey() throws {
        let services = try ConfigFile.parse(
            """
            # comment
            [Web server]
            command = npm run dev -- --port=3000
            directory = ~/site
            log = ~/web.log
            restart = on-failure
            autostart = yes
            env.PORT = 3000
            env.URL = http://x/?a=b#c

            ; another comment
            [db]
            command = postgres
            """)

        #expect(services.count == 2)
        #expect(
            services[0]
                == Service(
                    name: "Web server",
                    command: "npm run dev -- --port=3000",
                    directory: "~/site",
                    log: "~/web.log",
                    autostart: true,
                    restart: .onFailure,
                    env: ["PORT": "3000", "URL": "http://x/?a=b#c"]
                ))
        #expect(services[1] == Service(name: "db", command: "postgres"))
    }

    @Test func readsSecrets() throws {
        let services = try ConfigFile.parse("[a]\ncommand = x\nsecret.API_KEY = my item\n")
        #expect(services[0].secrets == ["API_KEY": "my item"])
        #expect(services[0].env.isEmpty)
    }

    @Test func starterHasNoServices() throws {
        #expect(try ConfigFile.parse(ConfigFile.starter).isEmpty)
    }

    @Test(arguments: [
        ("[a]\n", "Line 1: [a] has no command"),
        ("command = x", "Line 1: \"command\" is outside any [section]"),
        ("[a]\ncommand = x\nnonsense", "Line 3: expected [name] or key = value"),
        ("[a]\ncommand = x\nfoo = 1", "Line 3: unknown key \"foo\""),
        ("[a]\ncommand = x\nrestart = maybe", "Line 3: restart must be no, on-failure or always"),
        ("[a]\ncommand = x\nautostart = 1", "Line 3: autostart must be yes or no"),
        ("[!!]\ncommand = x", "Line 1: a service name needs a letter or digit"),
        ("[a]\ncommand = x\nsecret.A-B = i", "Line 3: \"A-B\" isn't a valid variable name"),
        ("[a]\ncommand = x\nsecret.A;rm = i", "Line 3: \"A;rm\" isn't a valid variable name"),
        ("[a]\ncommand = x\nsecret.A =", "Line 3: secret.A needs a keychain item name"),
        ("[a]\ncommand = x\nenv.A = 1\nsecret.A = i", "Line 1: [a] sets A as both env and secret"),
        ("[Web]\ncommand = x\n[web]\ncommand = y", "Line 3: [web] clashes with [Web]"),
    ])
    func reportsErrorsWithLineNumbers(text: String, message: String) {
        #expect(throws: ConfigError.self) { try ConfigFile.parse(text) }
        do {
            _ = try ConfigFile.parse(text)
        } catch {
            #expect(String(describing: error) == message)
        }
    }

    @Test func slugs() {
        #expect(Service.slug(for: "Web  server (v2)") == "web-server-v2")
        #expect(Service.slug(for: "Café") == "caf")
        #expect(Service.slug(for: "—") == "")
    }
}

@Suite struct EditingTests {
    let text = """
        # My services

        # the site
        [web]
        command = npm start  # not a comment, part of the command
        # keep this note
        env.B = 2
        env.A = 1

        # the database
        [db]
        command = postgres

        """

    @Test func changingOneKeyTouchesOnlyThatLine() throws {
        var file = ConfigFile(text: text)
        var web = try ConfigFile.parse(text)[0]
        web.command = "npm run dev"
        try file.save(web, replacing: "web")

        #expect(file.text == text.replacingOccurrences(
            of: "command = npm start  # not a comment, part of the command",
            with: "command = npm run dev"
        ))
    }

    @Test func savingUnchangedServiceChangesNothing() throws {
        var file = ConfigFile(text: text)
        try file.save(try ConfigFile.parse(text)[0], replacing: "web")
        #expect(file.text == text)
    }

    @Test func addedKeysGoAfterTheLastKeyAndRemovedKeysDisappear() throws {
        var file = ConfigFile(text: text)
        var web = try ConfigFile.parse(text)[0]
        web.restart = .always
        web.env["B"] = nil
        try file.save(web, replacing: "web")

        #expect(file.text.contains("# keep this note\nenv.A = 1\nrestart = always\n\n# the database"))
        #expect(try ConfigFile.parse(file.text)[0] == web)
    }

    @Test func renamingKeepsThePlaceInTheFile() throws {
        var file = ConfigFile(text: text)
        var web = try ConfigFile.parse(text)[0]
        web.name = "site"
        try file.save(web, replacing: "web")

        #expect(try ConfigFile.parse(file.text).map(\.name) == ["site", "db"])
    }

    @Test func addingAppendsANewSection() throws {
        var file = ConfigFile(text: text)
        let new = Service(
            name: "cache", command: "redis-server", autostart: true, restart: .onFailure, env: ["X": "1"])
        try file.save(new)

        #expect(file.text.hasSuffix(
            "command = postgres\n\n[cache]\ncommand = redis-server\nrestart = on-failure\nautostart = yes\nenv.X = 1\n"
        ))
        #expect(try ConfigFile.parse(file.text).last == new)
    }

    @Test func secretsAreSavedAlongsideEnvironment() throws {
        var file = ConfigFile(text: text)
        var web = try ConfigFile.parse(text)[0]
        web.secrets = ["TOKEN": "web-token"]
        try file.save(web, replacing: "web")

        #expect(file.text.contains("env.A = 1\nsecret.TOKEN = web-token\n"))
        #expect(try ConfigFile.parse(file.text)[0] == web)

        web.secrets = [:]
        try file.save(web, replacing: "web")
        #expect(file.text == text)
    }

    @Test func addingToAnEmptyFileHasNoLeadingBlankLine() throws {
        var file = ConfigFile(text: "")
        try file.save(Service(name: "a", command: "x"))
        #expect(file.text == "[a]\ncommand = x\n")
    }

    @Test func removingTakesItsOwnCommentsButNotTheNextSections() {
        var file = ConfigFile(text: text)
        file.remove("web")
        #expect(file.text == "# My services\n\n# the database\n[db]\ncommand = postgres\n")
    }

    @Test func removingTheLastSection() throws {
        var file = ConfigFile(text: text)
        file.remove("db")
        #expect(try ConfigFile.parse(file.text).map(\.name) == ["web"])
        #expect(file.text.contains("# the database") == false)
    }
}
