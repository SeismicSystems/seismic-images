.DEFAULT_GOAL := help

VERSION := $(shell git describe --tags --always --dirty="-dev")
TIMESTAMP := $(shell date +%Y%m%d%H%M%S)
SHELL := /bin/bash
WRAPPER := scripts/env_wrapper.sh

##@ Help

# Awk script from https://github.com/paradigmxyz/reth/blob/main/Makefile
.PHONY: help
help: ## Display this help.
	@awk 'BEGIN {FS = ":.*##"; printf "Usage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)

.PHONY: v
v: ## Show the version
	@echo "Version: ${VERSION}"

##@ Build

build build-dev: check-module

check-module:
ifndef IMAGE
	$(error IMAGE is not set. Please specify IMAGE=<image> when running make build or make build-dev)
endif

.PHONY: all build build-dev setup measure clean check-perms check-module

# Default target
all: build

# Ensure repo was cloned with correct permissions
check-perms: ## Check repository permissions
	@scripts/check_perms.sh

# Setup dependencies (Linux only)
setup: ## Install dependencies (Linux only)
	@scripts/setup_deps.sh

# Build module
build: check-perms setup ## Build the specified module
ifdef PROFILE
	$(WRAPPER) mkosi --force --profile=$(PROFILE) -I $(IMAGE).conf
else
	$(WRAPPER) mkosi --force -I $(IMAGE).conf
endif
	@echo "Renaming outputs with timestamp: $(TIMESTAMP)"
ifdef PROFILE
	@for f in build/$(IMAGE).*; do \
		[ -f "$$f" ] || continue; \
		ext="$${f##*.}"; \
		mv "$$f" "build/$(IMAGE)-$(PROFILE)-$(TIMESTAMP).$$ext"; \
		echo "  $$f → build/$(IMAGE)-$(PROFILE)-$(TIMESTAMP).$$ext"; \
	done
else
	@for f in build/$(IMAGE).*; do \
		[ -f "$$f" ] || continue; \
		ext="$${f##*.}"; \
		mv "$$f" "build/$(IMAGE)-baremetal-$(TIMESTAMP).$$ext"; \
		echo "  $$f → build/$(IMAGE)-baremetal-$(TIMESTAMP).$$ext"; \
	done
endif

# Build module with devtools profile
build-dev: check-perms setup ## Build module with development tools
ifdef PROFILE
	$(WRAPPER) mkosi --force --profile=devtools,$(PROFILE) -I $(IMAGE).conf
else
	$(WRAPPER) mkosi --force --profile=devtools -I $(IMAGE).conf
endif
	@echo "Renaming outputs with timestamp: $(TIMESTAMP)"
ifdef PROFILE
	@for f in build/$(IMAGE).*; do \
		[ -f "$$f" ] || continue; \
		ext="$${f##*.}"; \
		mv "$$f" "build/$(IMAGE)-$(PROFILE)-$(TIMESTAMP).$$ext"; \
		echo "  $$f → build/$(IMAGE)-$(PROFILE)-$(TIMESTAMP).$$ext"; \
	done
else
	@for f in build/$(IMAGE).*; do \
		[ -f "$$f" ] || continue; \
		ext="$${f##*.}"; \
		mv "$$f" "build/$(IMAGE)-baremetal-$(TIMESTAMP).$$ext"; \
		echo "  $$f → build/$(IMAGE)-baremetal-$(TIMESTAMP).$$ext"; \
	done
endif

##@ Utilities

measure: check-module ## Export TDX measurements for the built EFI file
	@EFI_FILE=$$(find build -maxdepth 1 -name "*.efi" -type f | head -1); \
	if [ -z "$$EFI_FILE" ]; then \
		echo "Error: No .efi file found in build/. Run 'make build IMAGE=$(IMAGE)' first."; \
		exit 1; \
	fi; \
	echo "Using EFI file: $$EFI_FILE"; \
	$(WRAPPER) measured-boot "$$EFI_FILE" build/measurements.json --direct-uki; \
	echo "Measurements exported to build/measurements.json"

measure-gcp: check-module ## Export TDX measurements for GCP
	@EFI_FILE=$$(find build -maxdepth 1 -name "*.efi" -type f | head -1); \
	if [ -z "$$EFI_FILE" ]; then \
		echo "Error: No .efi file found in build/. Run 'make build IMAGE=$(IMAGE)' first."; \
		exit 1; \
	fi; \
	echo "Using EFI file: $$EFI_FILE"; \
	$(WRAPPER) dstack-mr -uki "$$EFI_FILE" -json > build/gcp_measurements.json; \
	echo "GCP Measurements exported to build/gcp_measurements.json"

# Clean build artifacts
clean: ## Remove cache and build artifacts
	rm -rf build/ mkosi.builddir/ mkosi.cache/ lima-nix/
	@if command -v limactl >/dev/null 2>&1 && limactl list | grep -q '^tee-builder'; then \
		echo "Stopping and deleting lima VM 'tee-builder'..."; \
		limactl stop tee-builder || true; \
		limactl delete tee-builder || true; \
	fi
