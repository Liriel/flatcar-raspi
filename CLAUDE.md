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
agent config, the embedded `install-traceway-sysext.sh` download script, and a docker-compose
sysext from the flatcar/sysext-bakery. `INSTALL.md` is the full walkthrough; `README.md` the overview.

Arch gotcha: the `IMAGE=` line in the embedded `install-traceway-sysext.sh` must be
`traceway-otel-agent-arm64` (the Pi is arm64) and the downloaded `.raw` filename must equal the
image's extension-release name, or systemd-sysext silently refuses to merge it.

## How the sysext mechanism works (the non-obvious part)

The build (`.github/workflows/build.yml`) does **not** just package a binary — it bakes a
pre-enabled systemd unit into the image:

1. Downloads the upstream agent binary for arm64, verifies its checksum.
2. Lays out a `/usr` tree containing the binary, the `traceway-otel-agent.service` unit, **and a
   `multi-user.target.wants/` symlink** pointing at that unit.
3. Writes `usr/lib/extension-release.d/extension-release.<name>` with `ARCHITECTURE=` matching the
   Flatcar arch (mismatch → refuses to merge) and `VERSION_ID=_any`.
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
