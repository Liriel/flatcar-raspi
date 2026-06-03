# traceway-sysext

A [systemd-sysext](https://www.flatcar.org/docs/latest/provisioning/sysext/) image
that bundles the [Traceway OTel Agent](https://github.com/tracewayapp/traceway-otel-agent)
for use on [Flatcar Container Linux](https://www.flatcar.org/).

## How it works

```
GitHub Actions (on git tag)
  └─ downloads traceway-otel-agent binary from upstream release
  └─ builds a squashfs sysext image (.raw)
  └─ publishes it as a GitHub Release asset

Flatcar node (first boot via Ignition)
  └─ install-traceway-sysext.service downloads the .raw from this repo's release
  └─ image is placed in /etc/extensions/
  └─ systemd-sysext merges /usr from the image → binary lands on PATH
  └─ ensure-sysext.service (built into Flatcar) activates the bundled systemd unit
  └─ traceway-otel-agent.service starts, reads token from /etc/traceway-otel-agent/token
```

## Repository structure

```
.
├── AGENT_VERSION                    # pinned upstream agent version
├── .github/workflows/build.yml      # builds + publishes the sysext on tag push
└── ignition/
    └── butane.yaml                  # Butane config → transpile to Ignition JSON
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

GitHub Actions will build `traceway-otel-agent-arm64.raw` and `traceway-otel-agent-x86-64.raw` and publish them under
**Releases → v0.5.0**.

### 3. Edit `ignition/butane.yaml`

Open the file and fill in the two placeholders:

| Placeholder | What to put |
|---|---|
| `YOUR_PROJECT_TOKEN` | Your Traceway project token (Settings → project → copy token) |
| `YOUR_GITHUB_USERNAME/traceway-sysext` | Your GitHub repo path (e.g. `acmecorp/traceway-sysext`) |

Optionally set `TRACEWAY_SERVICE_NAME` to a fixed label (defaults to hostname).

### 4. Transpile to Ignition JSON

```bash
# Install Butane if you don't have it
# https://coreos.github.io/butane/getting-started/
butane --pretty --strict ignition/butane.yaml > ignition/ignition.json
```

### 5. Provision your Flatcar node

Pass `ignition/ignition.json` as **user data** / **custom data** when
creating your VM (AWS, GCP, Azure, bare metal, QEMU — all use the same file).

On first boot, the node will:
1. Download the matching `traceway-otel-agent-<arch>.raw` from this repo's release.
2. Verify its sha256 checksum.
3. Merge the sysext so the binary is available at `/usr/bin/traceway-otel-agent`.
4. Start `traceway-otel-agent.service`.

Metrics appear in your Traceway dashboard within ~60 seconds.

## Upgrading the agent

1. Update `AGENT_VERSION` to the new upstream release tag.
2. Push a new git tag (e.g. `v0.5.1`).
3. Update `SYSEXT_TAG` in `ignition/butane.yaml` to match.
4. Re-transpile and re-provision (or manually run `/opt/bin/install-traceway-sysext.sh`
   on existing nodes after deleting `/var/lib/traceway-otel-agent/.sysext-installed`).

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
