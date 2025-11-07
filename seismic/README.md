# Seismic Module

Builds TDX images with the Seismic Systems stack for Ethereum consensus and execution.

## Components

### Summit (Consensus Client)
- Repository: https://github.com/SeismicSystems/summit
- Branch: main
- Commit: 2022223a75f7e9e6d008638501ad95d1662d5ebc
- Binary: `/usr/bin/summit`

### Seismic-Reth (Execution Client)
- Repository: https://github.com/SeismicSystems/seismic-reth
- Branch: seismic
- Commit: 0981f14418d40ddff6711754e05259334e8ee144
- Binary: `/usr/bin/seismic-reth`

### Seismic Enclave Server
- Repository: https://github.com/SeismicSystems/enclave
- Branch: seismic
- Commit: 43e805a8a438d2e7a659fcf9e388ca6e445cbc9f
- Binary: `/usr/bin/seismic-enclave-server`

## Features

- TPM 2.0 support (tpm2-tools, tpm2-abrmd)
- All binaries built from source with reproducibility flags
- Persistent storage for each component
- Based on bob-common infrastructure
- Kernel configured for TPM and TDX

## Building

```bash
# Azure
make build IMAGE=seismic PROFILE=azure

# GCP
make build IMAGE=seismic PROFILE=gcp

# Bare metal
make build IMAGE=seismic
```

Outputs go to `build/` with format: `seismic-{profile}-{timestamp}.{ext}`

## Pre-built Binaries

Set these environment variables to skip compilation:

```bash
export SUMMIT_BINARY=/path/to/summit
export SEISMIC_RETH_BINARY=/path/to/seismic-reth
export ENCLAVE_BINARY=/path/to/seismic-enclave-server
```

## Persistent Storage

Each component gets a persistent directory:
- `/persistent/summit`
- `/persistent/seismic-reth`
- `/persistent/enclave`

## TPM Packages

Installed packages:
- tpm2-tools
- tpm2-abrmd
- libtss2-esys-3.0.2-0
- libtss2-tcti-device0
- libtss2-tcti-mssim0

## Additional Documentation

- [BUILD_GUIDE.md](BUILD_GUIDE.md) - Build commands and workflows
- [MEASUREMENTS_GUIDE.md](MEASUREMENTS_GUIDE.md) - TDX attestation measurements
- [SEISMIC_OUTPUTS.md](SEISMIC_OUTPUTS.md) - Output files and organization
