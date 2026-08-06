.DEFAULT_GOAL := help

VERSION := $(shell git describe --tags --always --dirty="-dev")
SHELL := /usr/bin/env bash
WRAPPER := scripts/env_wrapper.sh

FILE ?= build/latest.efi

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

.PHONY: all build build-dev setup measure clean check-module

# Default target
all: build

# Setup dependencies (Linux only)
setup: ## Install dependencies (Linux only)
	@scripts/setup_deps.sh

preflight:
	@$(WRAPPER) echo "Ready to build"

# Build module
build: setup ## Build the specified module
	$(WRAPPER) mkosi --force --image-id $(IMAGE) --include=images/$(IMAGE).conf

# Build module with devtools profile
build-dev: setup ## Build module with development tools
	$(WRAPPER) mkosi --force --image-id $(IMAGE)-dev --profile=devtools --include=images/$(IMAGE).conf

##@ Publish

# Azure Blob Storage configuration.
#
# AZURE_CONTAINER must be one of:
#   dev        ephemeral — manual + CI non-release builds (default)
#   releases   long-term — tagged releases that operators pull from
#
# Override on the command line, or use the convenience targets below:
#   make push-azure AZURE_CONTAINER=releases
#   make push-azure-releases                   # equivalent
#   make push-azure AZURE_AUTH_MODE=key        # if you don't have RBAC
#   make push-azure AZURE_STORAGE_ACCOUNT=...  # for a different registry
AZURE_STORAGE_ACCOUNT ?= seismicimages
AZURE_CONTAINER ?= dev
AZURE_AUTH_MODE ?= login

.PHONY: push-azure push-azure-dev push-azure-releases
push-azure: ## Upload latest built .vhd to Azure blob storage (uses AZURE_CONTAINER)
	@case "$(AZURE_CONTAINER)" in \
		dev|releases) ;; \
		*) echo "Error: AZURE_CONTAINER='$(AZURE_CONTAINER)' must be one of: dev, releases" >&2; exit 1 ;; \
	esac; \
	if [ ! -L build/latest.vhd ]; then \
		echo "Error: build/latest.vhd not found. Run 'make build' or 'make build-dev' first." >&2; \
		exit 1; \
	fi; \
	VHD_PATH=build/latest.vhd; \
	BLOB_NAME=$$(basename $$(realpath $$VHD_PATH)); \
	echo "Uploading $$BLOB_NAME → $(AZURE_STORAGE_ACCOUNT)/$(AZURE_CONTAINER)/ ..."; \
	az storage blob upload \
		--account-name $(AZURE_STORAGE_ACCOUNT) \
		--container-name $(AZURE_CONTAINER) \
		--name $$BLOB_NAME \
		--file $$VHD_PATH \
		--auth-mode $(AZURE_AUTH_MODE); \
	echo ""; \
	echo "Done. Here is the vhd_blob_url:"; \
	echo "  https://$(AZURE_STORAGE_ACCOUNT).blob.core.windows.net/$(AZURE_CONTAINER)/$$BLOB_NAME"

push-azure-dev: ## Upload latest .vhd to dev/ (ephemeral — default)
	@$(MAKE) push-azure AZURE_CONTAINER=dev

push-azure-releases: ## Upload latest .vhd to releases/ (long-term)
	@$(MAKE) push-azure AZURE_CONTAINER=releases

##@ Utilities

# The stamped measurement_id is the versioned VHD filename the PCRs
# measure, so anything consuming the measurements reads which image they
# bind to from the file itself instead of being told out-of-band.
measure: ## Export TDX measurements for the built EFI file
	@$(WRAPPER) measured-boot $(FILE) build/measurements.json --direct-uki
	@MEASUREMENT_ID="$$(basename "$$(realpath $(FILE))" .efi).vhd"; \
	$(WRAPPER) jq --arg id "$$MEASUREMENT_ID" '. + {measurement_id: $$id}' build/measurements.json > build/measurements.json.tmp && \
	mv build/measurements.json.tmp build/measurements.json; \
	echo "Measurements exported to build/measurements.json (measurement_id: $$MEASUREMENT_ID)"

measure-gcp: ## Export TDX measurements for GCP
	@$(WRAPPER) dstack-mr -uki $(FILE) > build/gcp_measurements.json
	echo "GCP Measurements exported to build/gcp_measurements.json"

# Clean build artifacts
clean: ## Remove cache and build artifacts
	rm -rf build/ mkosi.builddir/ mkosi.cache/ lima-nix/
	@REPO_DIR="$$(pwd)"; \
	REPO_HASH="$$(echo -n "$$REPO_DIR" | sha256sum | cut -c1-8)"; \
	LIMA_VM="tee-builder-$$REPO_HASH"; \
	if command -v limactl >/dev/null 2>&1 && limactl list | grep -q "^$$LIMA_VM"; then \
		echo "Stopping and deleting Lima VM '$$LIMA_VM'..."; \
		limactl stop "$$LIMA_VM" || true; \
		limactl delete "$$LIMA_VM" || true; \
	fi
