.PHONY: fetch-installer transpile provision help

DEVICE ?= /dev/sdX

# Container image used as a fallback when butane is not installed locally.
BUTANE_IMAGE ?= quay.io/coreos/butane:latest

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?## "}; {printf "  %-20s %s\n", $$1, $$2}'

fetch-installer: ## Download the flatcar-install script into flatcar-install/
	@echo "Fetching flatcar-install..."
	@curl -fsSL \
	  https://raw.githubusercontent.com/flatcar/init/flatcar-master/bin/flatcar-install \
	  -o flatcar-install/flatcar-install
	@chmod +x flatcar-install/flatcar-install
	@echo "Done: flatcar-install/flatcar-install"

transpile: ## Transpile cfg/butane.yaml → cfg/ignition.json (uses local butane, else docker)
	@if which butane > /dev/null 2>&1; then \
	  echo "Using local butane..."; \
	  butane --pretty --strict cfg/butane.yaml > cfg/ignition.json; \
	elif which docker > /dev/null 2>&1; then \
	  echo "butane not found; using $(BUTANE_IMAGE) via docker..."; \
	  docker run --rm -i $(BUTANE_IMAGE) --pretty --strict < cfg/butane.yaml > cfg/ignition.json; \
	else \
	  echo "Neither butane nor docker found."; \
	  echo "Install butane: https://coreos.github.io/butane/getting-started/"; \
	  echo "Or install docker to use $(BUTANE_IMAGE)."; \
	  exit 1; \
	fi
	@echo "Written: cfg/ignition.json"

provision: ## Write image to DEVICE (default: /dev/sdX). Run as root: make provision DEVICE=/dev/sdb
	@[ "$(DEVICE)" != "/dev/sdX" ] || \
	  (echo "Set DEVICE to your SD card, e.g.: make provision DEVICE=/dev/sdb"; exit 1)
	@[ "$$(id -u)" = "0" ] || \
	  (echo "make provision must be run as root (no sudo): run it from a root shell."; exit 1)
	./provision.sh $(DEVICE)
