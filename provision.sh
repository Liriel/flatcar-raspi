#!/usr/bin/env bash
# provision.sh — write a Flatcar + Traceway sysext image to an SD card / USB drive
#
# Usage (run as root, e.g. from a root shell — no sudo required):
#   ./provision.sh /dev/sdX
#
# What it does:
#   1. Checks cfg/ignition.json exists (reminds you to transpile if not).
#   2. Runs flatcar-install (from flatcar-install/flatcar-install) to write
#      Flatcar arm64 stable to the target device and embed the Ignition config.
#   3. Mounts the EFI System Partition and installs the RPi4 UEFI firmware
#      (pftf/RPi4 latest release) so the Pi can actually boot.
#
# Requirements on the host:
#   curl, jq, unzip  (and root privileges — run as root, not via sudo)
#   The flatcar-install script must be present at flatcar-install/flatcar-install
#   (run `make fetch-installer` or follow INSTALL.md step 1 if it's missing).

set -euo pipefail

DEVICE="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IGNITION_CONFIG="${SCRIPT_DIR}/cfg/ignition.json"
INSTALLER="${SCRIPT_DIR}/flatcar-install/flatcar-install"

# pftf/RPi4 UEFI firmware version. Pinned (not "latest") — the version matters:
#   v1.41  KNOWN GOOD — boots Flatcar arm64 on a Pi 4 with a current EEPROM.
#   v1.52  (was "latest" 2026-06) FAILED — UEFI splash loads but freezes before
#          GRUB handoff and ignores keyboard input.
#   v1.37  FAILED — too old for a freshly-updated EEPROM: rainbow screen +
#          7 green-LED blinks ("kernel image not found", i.e. start4.elf can't
#          load RPI_EFI.fd).
# So newer isn't safer and older isn't safer — v1.41 is the sweet spot.
# Override if needed: PFTF_VERSION=v1.42 ./provision.sh /dev/sdX
PFTF_VERSION="${PFTF_VERSION:-v1.41}"

# ── Preflight ────────────────────────────────────────────────────────────────

if [[ -z "${DEVICE}" ]]; then
  echo "Usage: $0 /dev/sdX  (run as root)" >&2
  echo "Use lsblk to identify your SD card / USB drive." >&2
  exit 1
fi

if [[ "${EUID}" -ne 0 ]]; then
  echo "This script must be run as root." >&2
  exit 1
fi

if [[ ! -b "${DEVICE}" ]]; then
  echo "Error: ${DEVICE} is not a block device." >&2
  exit 1
fi

if [[ ! -f "${IGNITION_CONFIG}" ]]; then
  echo "Error: cfg/ignition.json not found." >&2
  echo ""
  echo "Transpile your Butane config first:"
  echo "  butane --pretty --strict cfg/butane.yaml > cfg/ignition.json"
  echo ""
  echo "Install Butane: https://coreos.github.io/butane/getting-started/"
  exit 1
fi

if [[ ! -x "${INSTALLER}" ]]; then
  echo "Error: flatcar-install/flatcar-install not found or not executable." >&2
  echo ""
  echo "Fetch it with:"
  echo "  make fetch-installer"
  echo "or manually:"
  echo "  curl -L https://raw.githubusercontent.com/flatcar/init/flatcar-master/bin/flatcar-install \\"
  echo "       -o flatcar-install/flatcar-install"
  echo "  chmod +x flatcar-install/flatcar-install"
  exit 1
fi

# Confirm before wiping the device
echo "============================================================"
echo "  WARNING: This will ERASE everything on ${DEVICE}"
echo "============================================================"
lsblk "${DEVICE}" 2>/dev/null || true
echo ""
read -r -p "Type YES to continue: " confirm
if [[ "${confirm}" != "YES" ]]; then
  echo "Aborted."
  exit 0
fi

# ── Step 1: Write Flatcar to the device ─────────────────────────────────────

FLATCAR_IMAGE="${SCRIPT_DIR}/flatcar-install/flatcar_production_image.bin.bz2"

if [[ -f "${FLATCAR_IMAGE}" ]]; then
  echo ""
  echo "► Using cached Flatcar image (delete to force re-download):"
  echo "    ${FLATCAR_IMAGE}"
else
  echo ""
  echo "► Downloading Flatcar arm64 stable image ..."
  echo "  (This downloads ~400 MB and may take a few minutes)"
  echo ""
  pushd "${SCRIPT_DIR}/flatcar-install" > /dev/null
  "${INSTALLER}" -D -C stable -B arm64-usr -o ''
  popd > /dev/null
fi

echo ""
echo "► Writing Flatcar to ${DEVICE} ..."
echo ""

"${INSTALLER}" \
  -f "${FLATCAR_IMAGE}" \
  -d "${DEVICE}" \
  -i "${IGNITION_CONFIG}"

echo ""
echo "► Flatcar written successfully."

# ── Step 2: Install RPi4 UEFI firmware onto the EFI System Partition ────────

echo ""
echo "► Installing RPi4 UEFI firmware ..."

EFI_PART=$(lsblk "${DEVICE}" -o LABEL,PATH | awk '$1 == "EFI-SYSTEM" {print $2}')

if [[ -z "${EFI_PART}" ]]; then
  echo "Error: Could not find EFI-SYSTEM partition on ${DEVICE}." >&2
  echo "The Flatcar install may have not completed correctly." >&2
  exit 1
fi

EFI_MOUNT=$(mktemp -d)
mount "${EFI_PART}" "${EFI_MOUNT}"

pushd "${EFI_MOUNT}" > /dev/null

UEFI_VERSION="${PFTF_VERSION}"
echo "  Downloading pinned RPi4_UEFI_Firmware_${UEFI_VERSION}.zip ..."
curl -fsSL "https://github.com/pftf/RPi4/releases/download/${UEFI_VERSION}/RPi4_UEFI_Firmware_${UEFI_VERSION}.zip" \
     -o uefi.zip
unzip -q uefi.zip
rm uefi.zip

popd > /dev/null
umount "${EFI_MOUNT}"
rmdir "${EFI_MOUNT}"

echo "  RPi4 UEFI firmware ${UEFI_VERSION} installed."

# ── Done ─────────────────────────────────────────────────────────────────────

echo ""
echo "============================================================"
echo "  Done! Your SD card / USB drive is ready."
echo ""
echo "  1. Safely remove: udisksctl power-off -b ${DEVICE}"
echo "  2. Insert into your Raspberry Pi 4 and power on."
echo "  3. On first boot the Pi will:"
echo "       • Configure itself via Ignition"
echo "       • Download the Traceway sysext from GitHub"
echo "       • Start traceway-otel-agent.service"
echo "  4. SSH in once it's up:"
echo "       ssh core@<pi-ip-address>"
echo "  5. Metrics appear in your Traceway dashboard within ~60s."
echo "============================================================"
