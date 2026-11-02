# Launcher

A small macOS menu bar app for starting, stopping and watching command-line
services. launchd does the actual work, so services keep running when the app
isn't, and everything is driven by one plain text file.

Requires macOS 14 or later. Building needs Xcode or the Swift toolchain.

```bash
make install
```

```bash
open ~/Applications/Launcher.app
```

`make app` builds `build/Launcher.app` without installing it, and `make test`
runs the tests, which start real jobs in launchd under a throwaway label but
leave the keychain alone.

## Using it

The menu lists your services, each with a status icon. Hover one to start, stop
or restart it, follow its logs, or configure it. Removing a service is in its
Configure window. **Add Service…** is in the main menu.

The menu bar icon stays out of the way unless something needs attention:

| Icon | Meaning |
| --- | --- |
| Dimmed | Nothing is running |
| Normal | Services are running |
| Pulsing orange dot | A service is starting |
| Red dot | A service failed, or the config file has an error |

Stopping a failed service clears its red dot.

## Config

`~/.config/launcher/services.conf`. Each `[section]` is a service, and its name
is what the menu shows. Everything after the `=` is taken literally, so `#` and
quotes inside a value need no escaping. Comments must be on their own line.

```ini
[Web server]
command = npm run dev
directory = ~/Developer/site
restart = on-failure
autostart = yes
log = ~/Library/Logs/web.log
env.PORT = 3000
secret.API_KEY = launcher.web-server.API_KEY
```

| Key | Default | |
| --- | --- | --- |
| `command` | required | Run by your login shell, so your `PATH` applies |
| `directory` | `~` | Working directory |
| `restart` | `no` | `no`, `on-failure` or `always` |
| `autostart` | `no` | `yes` starts it at login |
| `log` | `~/Library/Logs/Launcher/<name>.log` | stdout and stderr, together |
| `env.NAME` | | Any number of environment variables |
| `secret.NAME` | | Sets a variable from a keychain item (see below) |

Hand edits are picked up within a couple of seconds, and saving from the app
keeps your comments and only touches the lines that changed. A running service
keeps its old settings until it's restarted.

**The file is the source of truth.** Taking a section out of it, or renaming
one, stops that service and deletes its launchd agent. If the file has an error
the menu shows the line, and nothing changes until it's fixed.

## Secrets

Use `secret.NAME` rather than `env.NAME` for API keys and the like. `env` values
are stored as plain text in the config and the launchd agent. A secret is only
referred to by the name of its keychain item, and its value is read each time
the service launches.

The easy way is **Set Secret…** in a service's window: give it a variable name,
paste the value, and it's stored in the keychain when you save, as
`launcher.<service>.<NAME>`. Setting the same variable again replaces the value,
and a running service picks that up from the restart.

You can also point at an item you made yourself:

```bash
security add-generic-password -a "$USER" -s my-api-key -w
```

```ini
secret.API_KEY = my-api-key
```

If a lookup fails, the service doesn't start: it shows as failed and its log says
which secret couldn't be read.

Removing a service in the app also deletes the secrets Launcher stored for it,
unless another service uses them. Items you made yourself are never changed or
deleted, and neither is anything when you delete a section from the file by hand.

Limits worth knowing:

- Values must be plain ASCII and under about 3.5 KB, on one line. Set Secret
  refuses anything else, because `security`, the tool that reads and writes the
  keychain, can't carry it intact. For an item you made yourself nothing checks
  this, and `security` hands a non-ASCII value to the service as hex.
- A running service has the value in its environment, where other processes
  running as you can read it.
- Items made by other apps may trigger a macOS access prompt, which a background
  service can't answer. Items made by Set Secret or the `security` command above
  don't.

## How it maps to launchd

Each service is a generated user agent labelled `local.launcher.<name>`. Don't
edit these by hand, as the app rewrites them.

- **Start** writes the agent and runs `launchctl bootstrap`. **Stop** runs
  `launchctl bootout`, because killing a `KeepAlive` job only restarts it.
- Agents with `autostart = yes` live in `~/Library/LaunchAgents`, where launchd
  finds them at login. The rest live in
  `~/Library/Application Support/Launcher/agents`, because `KeepAlive` implies
  `RunAtLoad` and they would otherwise start at login too.
- Commands go through `$SHELL -ilc`, to pick up the `PATH` from your shell
  startup files, which then hands over to a non-interactive shell. Interactive
  shells ignore `SIGTERM`, so without that step stopping a compound command would
  take until launchd's SIGKILL 20 seconds later.

## Good to know

- launchd has no idea when a service is ready, so "starting" just means the
  first 3 seconds after launch.
- macOS shows a "background item added" notice the first time an autostart agent
  is written. If you switch it off in System Settings › General › Login Items,
  launchd refuses to load that service.
- Logs are never rotated. They grow until you press Clear in the log window.
- Status is polled every 2 seconds, as launchd can't push changes.
