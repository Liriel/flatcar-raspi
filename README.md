# traceway-sysext

A [systemd-sysext](https://www.flatcar.org/docs/latest/provisioning/sysext/) image
that bundles the [Traceway OTel Agent](https://github.com/tracewayapp/traceway-otel-agent)
and deploys it onto a **Raspberry Pi 4** running
[Flatcar Container Linux](https://www.flatcar.org/) (arm64).

> **For the full step-by-step SD-card walkthrough, see [INSTALL.md](INSTALL.md).**
> This README is the high-level overview.

## How it works

```
GitHub Actions (on git tag)
  └─ downloads traceway-otel-agent binary from upstream release
  └─ builds a squashfs sysext image (.raw)
  └─ publishes it as a GitHub Release asset

Raspberry Pi 4 (first boot via Ignition)
  └─ install-traceway-sysext.service downloads the .raw from this repo's release
  └─ image is placed in /etc/extensions/
  └─ systemd-sysext merges /usr from the image → binary lands on PATH
  └─ the bundled (pre-enabled) traceway-otel-agent.service starts
  └─ agent reads its token from /etc/traceway-otel-agent/token
```

## Repository structure

```
.
├── AGENT_VERSION                    # pinned upstream agent version
├── Makefile                         # fetch-installer / transpile / provision
├── provision.sh                     # writes Flatcar + Ignition + RPi4 UEFI to an SD card
├── INSTALL.md                       # full SD-card install walkthrough
├── .github/workflows/build.yml      # builds + publishes the sysext on tag push
├── cfg/
│   ├── butane.example.yaml          # committed template — copy to butane.yaml and edit
│   └── butane.yaml                  # your config (gitignored): SSH key, token, agent + docker-compose sysext
└── flatcar-install/                 # holds the fetched flatcar-install script (gitignored)
```

## First-time setup

### 1. Fork / clone this repo

Push it to your own GitHub account. The Actions workflow needs
`contents: write` permission (already set in `build.yml`) so it can create releases.

### 2. Trigger a build

```bash
git tag v0.5.0
git push origin v0.5.0
```

GitHub Actions builds `traceway-otel-agent-arm64.raw` (the image the Pi uses) and
publishes it under **Releases → v0.5.0**.

### 3. Create and edit your config

The committed `cfg/butane.example.yaml` is a template. Copy it to `cfg/butane.yaml`
(which is gitignored, so your secrets never get committed):

```bash
cp cfg/butane.example.yaml cfg/butane.yaml
```

Then fill in the placeholders in `cfg/butane.yaml` (all marked `CONFIGURE` in the file):

| Placeholder | What to put |
|---|---|
| `ssh-ed25519 AAAAC3Nza...` | Your SSH public key (`cat ~/.ssh/id_ed25519.pub`) |
| `YOUR_PROJECT_TOKEN` | Your Traceway project token (Settings → project → copy token) |
| `YOUR_GITHUB_USERNAME/traceway-sysext` + `SYSEXT_TAG` | Your repo path and the release tag you built |

Optionally set `TRACEWAY_SERVICE_NAME` to a fixed label (defaults to hostname).

### 4. Transpile and write the SD card

```bash
make fetch-installer           # one-time: grab the flatcar-install script
make transpile                 # cfg/butane.yaml → cfg/ignition.json (butane, or docker fallback)
make provision DEVICE=/dev/sdb # write Flatcar + Ignition + RPi4 UEFI firmware (DESTRUCTIVE)
```

See [INSTALL.md](INSTALL.md) for EEPROM prep, device identification, and first-boot details.

On first boot the Pi will download the `traceway-otel-agent-arm64.raw` from your
release, verify its sha256, merge the sysext, and start the agent. Metrics appear in
your Traceway dashboard within ~60 seconds.

## Upgrading the agent

1. Update `AGENT_VERSION` to the new upstream release tag.
2. Push a new git tag (e.g. `v0.5.1`).
3. Update `SYSEXT_TAG` in `cfg/butane.yaml` to match, then `make transpile`.
4. New nodes pick it up on first boot. For existing nodes, SSH in and run:
   ```bash
   sudo rm /var/lib/traceway-otel-agent/.sysext-installed
   sudo systemctl start install-traceway-sysext.service
   ```

## Checking agent health on a running node

```bash
# Service status
sudo systemctl status traceway-otel-agent

# Live logs
sudo journalctl -u traceway-otel-agent -f

# Health endpoint (the agent exposes this)
curl http://127.0.0.1:13133/

# Confirm sysext is merged
systemd-sysext status
```

## Optional: log tailing and per-process metrics

Add extra env vars to `/etc/traceway-otel-agent/token`:

```
TRACEWAY_LOG_PATHS=/var/log/myapp/*.log
TRACEWAY_PROCESS_NAMES=myapp,nginx
```

Then restart the service: `sudo systemctl restart traceway-otel-agent`.

The agent config at `/etc/traceway-otel-agent/config.yaml` is yours to edit —
it's written by Ignition and not touched on upgrades.
