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

# The VHD to upload. Defaults to the latest.vhd symlink the build wrapper
# leaves behind; CI, which runs mkosi without the wrapper, names the file.
VHD ?= build/latest.vhd

# A blob is never overwritten: its name carries the commit that built it and
# a node may already be booting those bytes. `--overwrite false` is the
# guarantee (spelled out rather than left to the CLI's default, which has
# flipped before); the exists check ahead of it is what makes pushing an
# image that is already there a no-op that prints the same URL instead of a
# failure — a re-run of the CI publish depends on that.
.PHONY: push-azure push-azure-dev push-azure-releases
push-azure: ## Upload the built .vhd to Azure blob storage (uses AZURE_CONTAINER, VHD)
	@case "$(AZURE_CONTAINER)" in \
		dev|releases) ;; \
		*) echo "Error: AZURE_CONTAINER='$(AZURE_CONTAINER)' must be one of: dev, releases" >&2; exit 1 ;; \
	esac; \
	if [ ! -e "$(VHD)" ]; then \
		echo "Error: $(VHD) not found. Run 'make build' or 'make build-dev' first, or pass VHD=<path>." >&2; \
		exit 1; \
	fi; \
	BLOB_NAME=$$(basename $$(realpath $(VHD))); \
	if [ "$$(az storage blob exists \
			--account-name $(AZURE_STORAGE_ACCOUNT) \
			--container-name $(AZURE_CONTAINER) \
			--name $$BLOB_NAME \
			--auth-mode $(AZURE_AUTH_MODE) \
			--query exists -o tsv)" = "true" ]; then \
		echo "$$BLOB_NAME is already in $(AZURE_STORAGE_ACCOUNT)/$(AZURE_CONTAINER)/; not overwriting."; \
	else \
		echo "Uploading $$BLOB_NAME → $(AZURE_STORAGE_ACCOUNT)/$(AZURE_CONTAINER)/ ..."; \
		az storage blob upload \
			--account-name $(AZURE_STORAGE_ACCOUNT) \
			--container-name $(AZURE_CONTAINER) \
			--name $$BLOB_NAME \
			--file $(VHD) \
			--overwrite false \
			--auth-mode $(AZURE_AUTH_MODE); \
	fi; \
	echo ""; \
	echo "Here is the vhd_blob_url:"; \
	echo "  https://$(AZURE_STORAGE_ACCOUNT).blob.core.windows.net/$(AZURE_CONTAINER)/$$BLOB_NAME"

push-azure-dev: ## Upload the .vhd to dev/ (ephemeral — default)
	@$(MAKE) push-azure AZURE_CONTAINER=dev

push-azure-releases: ## Upload the .vhd to releases/ (long-term)
	@$(MAKE) push-azure AZURE_CONTAINER=releases

##@ Release assets

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

measure-gcp: ## Export GCP TDX measurements for the built EFI file
	@$(WRAPPER) dstack-mr -uki $(FILE) > $(MEASUREMENTS_GCP)
	echo "GCP Measurements exported to $(MEASUREMENTS_GCP)"

# The release's founding inputs, from the built image: the seismic-reth and
# summit binaries out of the initrd, both genesis files, and SHA256SUMS over
# them and the UKI. See the readme's "Founding inputs".
.PHONY: founding-inputs
founding-inputs: ## Gather the founding inputs into build/ and write SHA256SUMS (uses INITRD, FILE)
	@$(WRAPPER) scripts/seismic/founding_inputs.sh $(INITRD) $(FILE)

# Everything a release carries that a rebuild can reproduce, from one FILE
# and INITRD: the measurements and the founding inputs with their
# SHA256SUMS. The one asset not here is image.json, below — it records where
# the bytes were put, which a build does not know.
.PHONY: release-assets
release-assets: measure founding-inputs ## Measure the UKI and gather the founding inputs (uses FILE, INITRD)

# Where the image's bytes are and what they are, for consumers to read
# rather than reconstruct; see the readme's "image.json". Made after the VHD
# is pushed, by the publish job or by whoever pushed: the storage account's
# ARM ID is asked of `az` (an `az login` that can read the account), or
# passed as AZURE_STORAGE_ACCOUNT_ID. Not through the wrapper: it needs the
# host's `az` and `jq`, nothing from the build environment. Refuses a
# measurements file and a SHA256SUMS made from different builds.
SUMS ?= build/SHA256SUMS
COMMIT ?= $(shell git rev-parse HEAD)
.PHONY: image-json
image-json: ## Write build/image.json and add it to SHA256SUMS (uses AZURE_STORAGE_ACCOUNT, AZURE_CONTAINER, AZURE_STORAGE_ACCOUNT_ID, COMMIT)
	@AZURE_STORAGE_ACCOUNT=$(AZURE_STORAGE_ACCOUNT) AZURE_CONTAINER=$(AZURE_CONTAINER) \
		AZURE_STORAGE_ACCOUNT_ID=$(AZURE_STORAGE_ACCOUNT_ID) \
		scripts/seismic/image_json.sh $(MEASUREMENTS_AZURE) $(SUMS) $(COMMIT)

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
