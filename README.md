# tooling

Setup scripts for machines I run. Self-contained, no dependencies beyond the
platform's own tools, safe to re-run.

| Script | Platform | What it does |
| --- | --- | --- |
| [`macos_update_lock.sh`](#macos_update_locksh) | macOS | Disable software updates, reversibly |
| [`debian_setup.sh`](#debian_setupsh) | Debian / Ubuntu | APT mirror, SSH client, packages, shell |
| [`proxy_setup.sh`](#proxy_setupsh) | Debian / Ubuntu | Point common tools at an HTTP proxy |
| [`ssh_setup.sh`](#ssh_setupsh) | Debian / Ubuntu | Install and configure the SSH server |

They share one interface:

```
<script> apply   [step ...]    apply, safe to re-run
<script> restore [step ...]    back to how it was before the first apply
<script> status                what is currently applied
<script> help
```

`apply` snapshots what it is about to touch on its first run, and later runs
never overwrite that snapshot — so `restore` returns the machine to how it was
before the **first** apply, not before the most recent one.

Run the Debian ones as your normal user, not under `sudo`: user-level steps
write to `$HOME`, and privileged work goes through sudo individually.

---

## macos_update_lock.sh

```
sudo bash macos_update_lock.sh apply     # alias: off
sudo bash macos_update_lock.sh restore   # alias: on
bash macos_update_lock.sh status
```

Three layers, not equally durable (measured on 15.7.5):

| Layer | Survives reboot? |
| --- | --- |
| `/etc/hosts` block on 8 Apple update hostnames | **Yes** — this is the layer that holds |
| `com.apple.SoftwareUpdate` / `com.apple.commerce` preferences | Yes |
| `launchctl disable` of `softwareupdated` / `suhelperd` | **No** — macOS re-enables them at boot |

Not blocked: `mesu.apple.com` (breaks updating a connected iPhone from Finder)
and `ocsp.apple.com` (breaks TLS certificate validation). `gdmf.apple.com`
**is** blocked, which also stops `trustd` certificate trust supplements and
Siri asset downloads — Apple multiplexes the OS update manifest and every other
asset manifest over that one Pallas endpoint, so it cannot be scoped to updates
by hostname. Edit `BLOCK_HOSTS` if you would rather have the assets.

`AutomaticCheckEnabled` is a managed key on macOS 15 — `defaults write` reports
success but `cfprefsd` drops it, so only an MDM profile can pin it. Harmless
with the other layers in place.

---

## debian_setup.sh

```
bash debian_setup.sh apply [apt ssh packages shell]
```

| Step | Apply | Restore |
| --- | --- | --- |
| `apt` | Rewrites the mirror host in your sources; adds retry/timeout tuning | Source files back, tuning file removed |
| `ssh` | `ServerAliveInterval` keepalive in `~/.ssh/config` | File back |
| `packages` | Installs `$PACKAGES` | **No uninstall** — reports what it added. `PURGE_PACKAGES=1` to remove |
| `shell` | History settings and prompt in `~/.bashrc` | File back |

The mirror is probed first and skipped if unreachable, since a bad one breaks
apt. Only the host is rewritten, so suites and components are untouched.
Overrides: `APT_MIRROR`, `PACKAGES`, `SHELL_PROMPT=0`.

---

## proxy_setup.sh

```
bash proxy_setup.sh apply [wget curl git apt maven node wsl docker docker-build alias]
```

| Variable | Default | |
| --- | --- | --- |
| `PROXY_HOST` / `PROXY_PORT` | `127.0.0.1` / `7890` | |
| `GIT_USER_NAME` / `GIT_USER_EMAIL` | unset | Sets the git identity; an existing one is left alone |
| `ALLOW_INSECURE_SSL=1` | off | Also disables npm/yarn `strict-ssl` — MITM proxies only |
| `SKIP_PROXY_CHECK=1` | off | Write the apt proxy even if it does not work |

The apt proxy is probed with a real request before being written — a wrong apt
proxy breaks apt entirely, including the apt you would use to repair the
machine. Files the script did not write (an existing `settings.xml`,
`aliases.sh` without our marker, an existing git identity) are left alone.

---

## ssh_setup.sh

```
sudo bash ssh_setup.sh apply [--root-login|--no-root-login] [--password-login|--no-password-login]
sudo bash ssh_setup.sh restore
```

Root login is off by default (`prohibit-password`); `--root-login` enables it
and exposes root to password brute force. Password auth stays on unless you
pass `--no-password-login`. With neither root flag the script asks, defaulting
to off when stdin is not a terminal.

`sshd_config` is snapshotted and validated with `sshd -t` before sshd is
restarted; if validation fails the snapshot is put back, since a broken config
locks you out on restart. `restore` reverts the config only — it does not
uninstall `openssh-server` or touch firewall rules.

---

## Markers

The marker strings these scripts leave behind (`# macos-update-lock BEGIN` in
`/etc/hosts`, `# BEGIN proxy_setup.sh` in `~/.bashrc`, …) are **frozen
identifiers and do not track the filenames** — they are how a later run
recognises what it wrote. Renaming them orphans existing state.

## License

MIT — see [LICENSE](LICENSE).
