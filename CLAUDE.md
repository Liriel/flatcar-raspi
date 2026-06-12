# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A packaging/provisioning repo (no application source) that bundles the upstream
[traceway-otel-agent](https://github.com/tracewayapp/traceway-otel-agent) binary into a
[systemd-sysext](https://www.flatcar.org/docs/latest/provisioning/sysext/) image and deploys it
onto a **Raspberry Pi 4** running [Flatcar Container Linux](https://www.flatcar.org/) (arm64) via
Ignition. The agent ships host metrics (CPU/mem/disk/fs/network) to Traceway over OTLP/HTTP. This
repo targets the Pi only — there is no cloud/amd64 deployment path.

## Commands

```bash
make fetch-installer          # download the flatcar-install script into flatcar-install/ (gitignored, re-run on fresh clone)
make transpile                # cfg/butane.yaml → cfg/ignition.json (requires butane on PATH)
make provision DEVICE=/dev/sdb  # write Flatcar + Ignition + RPi4 UEFI firmware to an SD card (run as root, DESTRUCTIVE)
```

There are no tests or linters. Releases are cut by pushing a git tag:

```bash
git tag v0.5.1 && git push origin v0.5.1   # triggers .github/workflows/build.yml
```

## The single config: `cfg/butane.yaml`

The committed file is `cfg/butane.example.yaml` (a template with placeholders). Users copy it to
`cfg/butane.yaml` (gitignored) and fill in their secrets — never edit the example in place for a
real deployment, and never commit `cfg/butane.yaml`.

All node configuration lives in one Butane file, `cfg/butane.yaml`, consumed by
`make transpile` → `cfg/ignition.json` → `provision.sh`. It carries the SSH key, the
Pi-specific `kernel_arguments` (serial console + `flatcar.autologin`), the Traceway token and
agent config, the hostname + mDNS config, the `xterm-kitty` terminfo, and two boot-time sysext
download scripts (`install-traceway-sysext.sh` for this repo's agent image and
`install-docker-compose-sysext.sh` for the flatcar/sysext-bakery docker-compose image).
`INSTALL.md` is the full walkthrough; `README.md` the overview.

mDNS / `hostname.local`: done natively via systemd-resolved, **not** avahi (avahi would need its
own sysext; resolved already ships in Flatcar). Three pieces: `/etc/hostname` sets the name,
`/etc/systemd/resolved.conf.d/10-mdns.conf` (`[Resolve] MulticastDNS=yes`) turns on the responder
globally, and per-link `MulticastDNS=yes` enables it on each interface — wired via a
`/etc/systemd/network/zz-default.network.d/10-mdns.conf` drop-in (zz-default.network is Flatcar's
built-in catch-all DHCP unit; the drop-in adds mDNS without touching DHCP), Wi-Fi via the line in
`25-wlan0.network`. `systemd-resolved.service` is declared `enabled: true` for good measure.

kitty terminfo: Flatcar ships no `xterm-kitty` entry, so SSHing from kitty (which sets
`TERM=xterm-kitty`) breaks curses apps. The compiled entry is embedded as a base64 `data:` URL at
`/etc/terminfo/x/xterm-kitty` (`/usr` is read-only; `/etc/terminfo` is an ncurses search path).
Regenerate with `base64 -w0 /usr/share/terminfo/x/xterm-kitty`. The CONFIGURE step count in the
butane comments is now "of 4" (SSH, kernel args, Traceway creds, hostname).

Arch gotcha: the `IMAGE=` line in the embedded `install-traceway-sysext.sh` must be
`traceway-otel-agent-arm64` (the Pi is arm64) and the downloaded `.raw` filename must equal the
image's extension-release name, or systemd-sysext silently refuses to merge it.

Version-match gotcha (the silent-skip trap): the image's
`usr/lib/extension-release.d/extension-release.<name>` must carry `ID=flatcar` **plus
`SYSEXT_LEVEL=1.0`** (the bakery's approach), not `VERSION_ID=_any`. `_any` is a wildcard only for
`ID=` — *not* for `VERSION_ID=`. With `ID=flatcar`, systemd compares `SYSEXT_LEVEL` against the
host (or `VERSION_ID` if no `SYSEXT_LEVEL`); a literal `VERSION_ID=_any` never equals the host's
real VERSION_ID, so systemd-sysext silently drops the image from the merge set. Symptom: the boot
log shows the `.raw` "Installed", then `Unit traceway-otel-agent.service not found`
(`status=5/NOTINSTALLED`), and the image is absent from the `(sd-merge) Using extensions '...'`
line while the others merge. (This is *not* a compression issue — the Flatcar arm64 kernel has
`CONFIG_SQUASHFS_XZ=y`, so `-comp xz` mounts fine.)

## How the sysext mechanism works (the non-obvious part)

The build (`.github/workflows/build.yml`) does **not** just package a binary — it bakes a
pre-enabled systemd unit into the image:

1. Downloads the upstream agent binary for arm64, verifies its checksum.
2. Lays out a `/usr` tree containing the binary, the `traceway-otel-agent.service` unit, **and a
   `multi-user.target.wants/` symlink** pointing at that unit.
3. Writes `usr/lib/extension-release.d/extension-release.<name>` with `ARCHITECTURE=` matching the
   Flatcar arch (mismatch → refuses to merge), `ID=flatcar`, and `SYSEXT_LEVEL=1.0` (see the
   version-match gotcha above — `VERSION_ID=_any` does *not* work, `_any` is an `ID=`-only wildcard).
4. Packs it with `mksquashfs ... -comp xz` into `<name>.raw` + a `.sha256`, published as release assets.

The baked-in `multi-user.target.wants` symlink is deliberate: a sysext image can't run
`systemctl enable`, and **Ignition cannot enable a unit it can't see** at provisioning time (the
sysext isn't mounted yet). So the unit is "pre-enabled" by shipping the symlink that `enable` would
have created. This is why `traceway-otel-agent.service` is *not* declared in either butane file.

Boot-time flow on a node: Ignition writes the token/config and the `install-traceway-sysext.sh`
script + a `install-traceway-sysext.service` oneshot → oneshot downloads the matching `.raw` from
this repo's GitHub release, verifies sha256, drops it in `/etc/extensions/`, runs `systemd-sysext
refresh` → the bundled unit's symlink activates and the agent starts. A
`/var/lib/traceway-otel-agent/.sysext-installed` stamp file (`ConditionPathExists=!`) makes the
oneshot run only once.

## No-RTC clock trap: Ignition must not fetch over HTTPS on a Pi

The Raspberry Pi 4 has **no battery-backed RTC**. At Ignition time (initramfs,
before NTP) systemd sets the clock to its own *build date* — a date in the past —
so any HTTPS fetch fails TLS cert validation with `tls: failed to verify
certificate` (GitHub's cert looks "not yet valid"). This is independent of the
network: it fails on Ethernet too. See coreos/fedora-coreos-tracker#1323 / #1624.

Consequence baked into this repo: **Ignition fetches nothing remote.** Both
sysexts are pulled at *boot* (after timesyncd corrects the clock), each by its own
oneshot:

- `install-traceway-sysext.service` → `install-traceway-sysext.sh` (this repo's
  release). Stamped via `/var/lib/traceway-otel-agent/.sysext-installed`.
- `install-docker-compose-sysext.service` → `install-docker-compose-sysext.sh`
  (Flatcar sysext-bakery `latest`). Idempotent via
  `ConditionPathExists=!/etc/extensions/docker_compose.raw` (the downloaded file is
  its own done-marker). Verifies against the bakery's single `SHA256SUMS`. The
  destination must be named `docker_compose.raw` — that's the image's
  extension-release name; mismatch → silent merge failure.

Both units are ordered `After=network-online.target time-sync.target`. Do **not**
"optimize" either fetch back into an Ignition `contents.source:` URL — it will
break on every Pi.

## Wi-Fi is steady-state only — first boot should use Ethernet

The optional Wi-Fi blocks in `cfg/butane.yaml` configure Wi-Fi for the *booted*
system, not for provisioning. WiFi is unavailable in the initramfs (no driver
stack there; the `wpa_supplicant` config only activates once the real system
boots), and the two boot-time sysext fetches race Wi-Fi association/DHCP — and
need the clock synced, which needs network. So **first boot should be on
Ethernet** (README, INSTALL §2d). After one successful boot the docker-compose
`.raw` is on disk and the traceway sysext is stamped, so nothing re-downloads —
the Pi then runs on Wi-Fi alone across reboots.

## Version coupling

Three things must agree when releasing a new agent version:

- **`AGENT_VERSION`** (repo root) — upstream agent tag the workflow downloads (overridable via
  `workflow_dispatch` input).
- The **git tag** you push (`v*`) — names the GitHub Release the nodes download from.
- **`SYSEXT_TAG`** inside `cfg/butane.yaml`'s install script — must point at that release tag.

Existing nodes don't auto-upgrade: `sudo rm /var/lib/traceway-otel-agent/.sysext-installed &&
sudo systemctl start install-traceway-sysext.service`.

## Conventions / gotchas

- `*.raw`, `*.raw.sha256`, the agent binary, `cfg/butane.yaml`, `cfg/ignition.json`, and
  `flatcar-install/flatcar-install` are gitignored. Only `cfg/butane.example.yaml` is committed.
  **Never commit `cfg/butane.yaml` or the transpiled `cfg/ignition.json`** — both contain the SSH key
  and Traceway token.
- Editable placeholders to fill before provisioning: SSH public key, `YOUR_PROJECT_TOKEN`,
  and `YOUR_GITHUB_USERNAME/traceway-sysext` + `SYSEXT_TAG` in the install script.
- The local downloaded `.raw` filename must equal the image's extension-release name
  (`traceway-otel-agent-arm64`) or the merge silently fails.

## Reference

`provision.sh` + `cfg/butane.yaml` are a direct automation of the official
[Flatcar on Raspberry Pi 4](https://www.flatcar.org/docs/latest/installing/bare-metal/raspberry-pi/)
guide — the `flatcar-install` invocation, required kernel arguments, EEPROM prep, and pftf/RPi4
UEFI-firmware-into-ESP step all mirror it. If the Pi install logic ever needs changing, check that
page first for upstream updates.
