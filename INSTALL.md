# Installing Flatcar + Traceway on a Raspberry Pi 4

This guide walks you from a blank SD card to a running Flatcar node sending
host metrics to Traceway. Everything is driven from this repo on your
laptop — the Pi itself needs no manual setup.

> The `provision.sh` + `cfg/butane.yaml` flow automates the official
> [Flatcar on Raspberry Pi 4](https://www.flatcar.org/docs/latest/installing/bare-metal/raspberry-pi/)
> procedure (same `flatcar-install` flags, kernel args, and pftf/RPi4 UEFI step).
> Consult that page if upstream changes the install steps.

---

## What you need

**Hardware**
- Raspberry Pi 4 (any RAM variant)
- SD card or USB 3.0 drive (USB is faster; 8 GB minimum)
- A way to read/write the card from your laptop (SD slot or USB adapter)

**On your laptop**
- Linux or macOS (the `provision.sh` script uses `lsblk`; on macOS use
  `diskutil list` to identify the device and replace `lsblk` references below)
- `curl`, `jq`, `unzip` (usually pre-installed)
- [`butane`](https://coreos.github.io/butane/getting-started/) — the
  Flatcar/CoreOS config transpiler

```bash
# macOS
brew install butane

# Linux (download binary)
curl -fsSL https://github.com/coreos/butane/releases/latest/download/butane-x86_64-unknown-linux-gnu \
     -o /usr/local/bin/butane && chmod +x /usr/local/bin/butane
```

---

## One-time Pi prep — update the EEPROM

> Skip this if your Pi has already run a recent Raspberry Pi OS.

The UEFI firmware we use (pftf/RPi4) requires an up-to-date EEPROM.
The easiest way is to flash Raspberry Pi OS once, boot it, wait 30 seconds
for the auto-update, then power off. Alternatively use **Raspberry Pi Imager**:

1. Open Raspberry Pi Imager → **Operating System → Misc utility images →
   Bootloader → USB Boot** (or SD Boot, depending on your target medium).
2. Flash to a spare SD card, insert it, and power on.
3. Wait for a steady green LED blink (≈10 seconds), then power off and
   remove the card.

You only need to do this once per Pi.

---

## Step 1 — Fetch the flatcar-install script

The `flatcar-install/` directory in this repo is the right place to keep
the installer. Fetch it with:

```bash
make fetch-installer
```

This downloads the official script from the Flatcar GitHub and marks it
executable. It is gitignored — you'll need to re-run this on a fresh clone.

---

## Step 2 — Configure your SD card image

The repo ships a committed template, **`cfg/butane.example.yaml`**. Copy it to
**`cfg/butane.yaml`** — that filename is gitignored, so your SSH key and token
never end up in git:

```bash
cp cfg/butane.example.yaml cfg/butane.yaml
```

All user-editable config now lives in your **`cfg/butane.yaml`**. Open it and make
the following changes:

### 2a. Add your SSH public key

Find the `passwd:` section and replace the placeholder with your real key:

```yaml
passwd:
  users:
    - name: core
      ssh_authorized_keys:
        - "ssh-ed25519 AAAAC3Nza... your-public-key-here"
```

Get your public key with:

```bash
cat ~/.ssh/id_ed25519.pub
# or
cat ~/.ssh/id_rsa.pub
```

If you don't have an SSH key pair yet:

```bash
ssh-keygen -t ed25519 -C "pi"
```

> **Important:** without a valid SSH key you will not be able to log in
> to the Pi. Flatcar has no password login by default.

### 2b. Set your Traceway project token

Find the `/etc/traceway-otel-agent/token` file block and replace
`YOUR_PROJECT_TOKEN`:

```yaml
- path: /etc/traceway-otel-agent/token
  mode: 0600
  contents:
    inline: |
      TRACEWAY_TOKEN=YOUR_PROJECT_TOKEN   # ← paste your token here
      TRACEWAY_ENDPOINT=https://cloud.tracewayapp.com/api/otel
      TRACEWAY_SERVICE_NAME=              # ← optional: leave blank to use hostname
```

Your token is in your Traceway dashboard under **Settings → project →
copy token**.

### 2c. Point to your sysext release

Find the `install-traceway-sysext.sh` file block and update the two
variables at the top:

```bash
GITHUB_REPO="YOUR_GITHUB_USERNAME/traceway-sysext"   # ← your fork
SYSEXT_TAG="v0.5.0"                                   # ← the release tag you built
```

---

## Step 3 — Transpile to Ignition JSON

Butane (`.yaml`) is the human-readable source; Ignition (`.json`) is what
Flatcar actually reads. Generate it:

```bash
make transpile
```

This writes `cfg/ignition.json`. The file is gitignored — it contains your
SSH key and Traceway token and should not be committed.

If Butane reports a validation error, fix it in `cfg/butane.yaml` and
re-run.

---

## Step 4 — Identify your SD card

Insert the SD card (or USB drive) and find its device path:

```bash
# Linux
lsblk

# macOS
diskutil list
```

Look for a device whose size matches your card. It will be something like
`/dev/sdb` on Linux or `/dev/disk4` on macOS. **Double-check this** —
the next step will erase the device completely.

---

## Step 5 — Write the SD card

```bash
make provision DEVICE=/dev/sdb
```

Or directly:

```bash
sudo ./provision.sh /dev/sdb
```

The script will:

1. Ask you to type `YES` to confirm the erase.
2. Run `flatcar-install` — downloads the Flatcar arm64 stable image
   (~400 MB), verifies it with GPG, and writes it to the device along
   with your Ignition config.
3. Mount the EFI System Partition and install the latest
   [pftf/RPi4 UEFI firmware](https://github.com/pftf/RPi4/releases)
   automatically.

The whole process takes about 5–10 minutes depending on your internet
connection and card write speed.

---

## Step 6 — Boot the Pi

1. Safely eject the card:

```bash
# Linux
udisksctl power-off -b /dev/sdb

# macOS
diskutil eject /dev/disk4
```

2. Insert the SD card (or USB drive) into the Raspberry Pi 4 and power it on.

On first boot, the Pi will:
- Run Ignition — creates the `core` user, writes the agent config and token,
  and places the sysext download script.
- Start `install-traceway-sysext.service` — downloads `traceway-otel-agent-arm64.raw`
  from your GitHub release, verifies the checksum, and activates the sysext.
- Start `traceway-otel-agent.service` — begins shipping CPU, memory, disk,
  filesystem, and network metrics to Traceway every 60 seconds.

First boot takes about 60–90 seconds. Subsequent boots are fast.

---

## Step 7 — SSH in

Find the Pi's IP address from your router, then:

```bash
ssh core@<pi-ip-address>
```

No password — authentication uses your SSH key from step 2a.

Check that the agent is running:

```bash
# Service status
sudo systemctl status traceway-otel-agent

# Live logs
sudo journalctl -u traceway-otel-agent -f

# Health check endpoint
curl http://127.0.0.1:13133/
```

Metrics appear in your Traceway dashboard within about 60 seconds of the
agent starting.

---

## Upgrading the sysext

1. Bump `AGENT_VERSION` in the repo root.
2. Push a new git tag (`git tag v0.5.1 && git push origin v0.5.1`) to
   trigger the GitHub Actions build.
3. Update `SYSEXT_TAG` in `cfg/butane.yaml` and re-transpile. For new
   nodes this is picked up automatically on first boot.
4. For **existing** nodes, SSH in and run:

```bash
sudo rm /var/lib/traceway-otel-agent/.sysext-installed
sudo systemctl start install-traceway-sysext.service
```

---

## File layout

```
cfg/
  butane.example.yaml ← committed template (copy this)
  butane.yaml         ← your config: edit it (SSH key, token, repo/tag); gitignored
  ignition.json       ← generated by `make transpile` (gitignored)
  .gitignore

flatcar-install/
  flatcar-install   ← fetched by `make fetch-installer` (gitignored)
  README.md
  .gitignore

provision.sh        ← writes the SD card (calls flatcar-install + UEFI step)
Makefile            ← shortcuts: fetch-installer, transpile, provision
INSTALL.md          ← this file
```

---

## Troubleshooting

**Pi doesn't boot / no UEFI splash screen**
The EEPROM may be too old. Repeat the EEPROM update in the one-time prep
section above.

**SSH connection refused**
The Pi is probably still on its first boot. Wait 90 seconds and try again.
If it still fails, connect a monitor — Flatcar will show a login prompt on
`tty1` (autologin is enabled by the kernel args). Check
`sudo systemctl status ignition-setup-base` for errors.

**`install-traceway-sysext.service` failed**
The Pi needs internet access to download the sysext. Check:
```bash
sudo journalctl -u install-traceway-sysext -b
```
Common causes: the GitHub repo/tag doesn't exist yet (did you push the tag
and wait for Actions to finish?), or no network on first boot (check your
router/DHCP).

**No metrics in Traceway**
```bash
sudo journalctl -u traceway-otel-agent -b --no-pager | tail -40
curl http://127.0.0.1:13133/
```
Check that `TRACEWAY_TOKEN` in `/etc/traceway-otel-agent/token` is correct
and that the Pi can reach `cloud.tracewayapp.com` on port 443.
