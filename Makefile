.DEFAULT_GOAL := help

VERSION := $(shell git describe --tags --always --dirty="-dev")
SHELL := /usr/bin/env bash
WRAPPER := scripts/env_wrapper.sh

FILE ?= build/latest.efi
INITRD ?= build/latest.initrd

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

.PHONY: all build build-dev setup measure measure-portable measure-portable-gcp clean check-module

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

##@ Measure

# One measurements file per attestation type, named for it: the admission
# pipeline keys a policy record on `attestation_type`, and an image published
# for more than one cloud carries one file per type under one release, so
# the name says which registers are inside before anyone opens it. The GCP
# type string is provisional until its admission schema exists.
MEASUREMENTS_AZURE := build/measurements.azure-tdx.json
MEASUREMENTS_GCP := build/measurements.gcp-tdx.json

# The stamped measurement_id is the versioned VHD filename the PCRs
# measure, so anything consuming the measurements reads which image they
# bind to from the file itself instead of being told out-of-band.
measure: ## Export Azure TDX measurements for the built EFI file
	@$(WRAPPER) measured-boot $(FILE) $(MEASUREMENTS_AZURE) --direct-uki
	@MEASUREMENT_ID="$$(basename "$$(realpath $(FILE))" .efi).vhd"; \
	$(WRAPPER) bash -c "STAMPED=\$$(jq --arg id '$$MEASUREMENT_ID' '. + {measurement_id: \$$id}' $(MEASUREMENTS_AZURE)) && printf '%s\\n' \"\$$STAMPED\" > $(MEASUREMENTS_AZURE)" && \
	echo "Measurements exported to $(MEASUREMENTS_AZURE) (measurement_id: $$MEASUREMENT_ID)"

measure-portable: ## Export portable measurements for the built EFI file
	@$(WRAPPER) bash -c 'attest measure portable "$$1" > build/portable_measurements.json' _ "$(FILE)"
	echo "Portable measurements exported to build/portable_measurements.json"

measure-portable-gcp: measure-portable ## Export a portable GCP-only attestation policy for the built EFI file
	@$(WRAPPER) bash -c 'jq -e "[{attestation_type: \"gcp-tdx\", dcap_image_hashes: .dcap}]" build/portable_measurements.json > build/measurements-gcp.json'
	echo "GCP attestation policy exported to build/measurements-gcp.json"

measure-gcp: ## Predict RTMR1 and RTMR2 for a GCP TDX boot (no vTPM) of the built EFI file
	@python3 scripts/predict_gcp_rtmrs.py --efi $(FILE) --out $(MEASUREMENTS_GCP) && \
	echo "GCP measurements exported to $(MEASUREMENTS_GCP)"

##@ Seismic

# A Seismic image's release, in two steps: `release-assets` makes everything
# it carries, locally, and `push-azure` uploads the VHD to where its
# image.json says.

# Where the VHD will be. image.json names its blob before it is pushed, so
# the container is chosen here, with the build, and `make push-azure` reads
# it back:
#   dev        ephemeral — manual + CI non-release builds (default)
#   releases   long-term — tagged releases that operators pull from
# The account's ARM ID is not a secret: every release's image.json carries
# it. Another account passes its own.
AZURE_STORAGE_ACCOUNT ?= seismicimages
AZURE_CONTAINER ?= dev
AZURE_STORAGE_ACCOUNT_ID ?= /subscriptions/214887ea-51a7-4ca7-9cec-29b3cf3d311c/resourceGroups/seismic-images/providers/Microsoft.Storage/storageAccounts/seismicimages
COMMIT ?= $(shell git rev-parse HEAD)

# Everything a release carries, from one FILE and INITRD, with one SHA256SUMS
# over it: the measurements (`measure`), then the founding inputs and
# image.json (scripts/seismic/release_assets.sh; the readme's "Founding
# inputs" and "image.json"). Local work only: nothing here needs
# credentials, and nothing is uploaded. The wrapper does not carry the
# environment into the build VM, so the settings go through `env`.
.PHONY: release-assets
release-assets: measure ## Measure the UKI, gather the founding inputs and write image.json
	@$(WRAPPER) env AZURE_STORAGE_ACCOUNT=$(AZURE_STORAGE_ACCOUNT) AZURE_CONTAINER=$(AZURE_CONTAINER) \
		AZURE_STORAGE_ACCOUNT_ID=$(AZURE_STORAGE_ACCOUNT_ID) \
		scripts/seismic/release_assets.sh $(INITRD) $(FILE) $(MEASUREMENTS_AZURE) $(COMMIT)

# Upload the VHD to the blob build/image.json names, which makes the record
# true; the one step that needs Azure credentials. The destination is the
# record's, so to push elsewhere, re-run `make release-assets` with another
# AZURE_CONTAINER. See scripts/seismic/push_azure.sh.
#   make push-azure                       # after make release-assets
#   make push-azure AZURE_AUTH_MODE=key   # if you don't have RBAC
AZURE_AUTH_MODE ?= login
IMAGE_JSON ?= build/image.json
.PHONY: push-azure
push-azure: ## Upload the VHD to where build/image.json says
	@AZURE_AUTH_MODE=$(AZURE_AUTH_MODE) scripts/seismic/push_azure.sh $(IMAGE_JSON)

##@ Utilities

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
