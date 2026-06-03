.PHONY: fetch-installer transpile provision help

DEVICE ?= /dev/sdX

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

transpile: ## Transpile cfg/butane.yaml → cfg/ignition.json (requires butane)
	@which butane > /dev/null 2>&1 || \
	  (echo "butane not found. Install: https://coreos.github.io/butane/getting-started/"; exit 1)
	butane --pretty --strict cfg/butane.yaml > cfg/ignition.json
	@echo "Written: cfg/ignition.json"

provision: ## Write image to DEVICE (default: /dev/sdX). Run: make provision DEVICE=/dev/sdb
	@[ "$(DEVICE)" != "/dev/sdX" ] || \
	  (echo "Set DEVICE to your SD card, e.g.: make provision DEVICE=/dev/sdb"; exit 1)
	sudo ./provision.sh $(DEVICE)
