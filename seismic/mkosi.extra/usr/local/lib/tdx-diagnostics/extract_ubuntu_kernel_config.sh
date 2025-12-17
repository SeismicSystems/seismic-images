#!/bin/bash
# Script to extract kernel config from Ubuntu 24.04 TDX image
# To be run on a Google Cloud Ubuntu 24.04 LTS + TDX VM
#
# Usage:
#   1. Create a TDX CVM with Ubuntu 24.04 LTS + TDX image via GCP UI
#   2. SSH into the VM
#   3. Run this script: ./extract_ubuntu_kernel_config.sh
#   4. Download the resulting kernel config file

set -e

OUTPUT_FILE="ubuntu-24.04-tdx-kernel.config"

echo "Extracting Ubuntu 24.04 TDX kernel configuration..."
echo ""

# Method 1: Try /proc/config.gz (if kernel was built with CONFIG_IKCONFIG_PROC=y)
if [ -f /proc/config.gz ]; then
    echo "Found /proc/config.gz - extracting..."
    zcat /proc/config.gz > "$OUTPUT_FILE"
    echo "Success! Kernel config saved to: $OUTPUT_FILE"
    echo ""
    echo "Download this file and send it to the Google engineer."
    echo "You can use: gcloud compute scp <instance-name>:$OUTPUT_FILE ./"
    exit 0
fi

# Method 2: Try /boot/config-<kernel-version>
KERNEL_VERSION=$(uname -r)
if [ -f "/boot/config-$KERNEL_VERSION" ]; then
    echo "Found /boot/config-$KERNEL_VERSION - copying..."
    cp "/boot/config-$KERNEL_VERSION" "$OUTPUT_FILE"
    echo "Success! Kernel config saved to: $OUTPUT_FILE"
    echo ""
    echo "Download this file and send it to the Google engineer."
    echo "You can use: gcloud compute scp <instance-name>:$OUTPUT_FILE ./"
    exit 0
fi

# Method 3: Search /boot for any config files
echo "Searching /boot for kernel config files..."
CONFIG_FILES=$(ls /boot/config-* 2>/dev/null || true)
if [ -n "$CONFIG_FILES" ]; then
    echo "Found config files in /boot:"
    ls -lh /boot/config-*
    LATEST_CONFIG=$(ls -t /boot/config-* | head -1)
    echo ""
    echo "Using latest config: $LATEST_CONFIG"
    cp "$LATEST_CONFIG" "$OUTPUT_FILE"
    echo "Success! Kernel config saved to: $OUTPUT_FILE"
    echo ""
    echo "Download this file and send it to the Google engineer."
    echo "You can use: gcloud compute scp <instance-name>:$OUTPUT_FILE ./"
    exit 0
fi

# If we get here, we couldn't find the config
echo "ERROR: Could not find kernel configuration file!"
echo ""
echo "Tried:"
echo "  - /proc/config.gz"
echo "  - /boot/config-$KERNEL_VERSION"
echo "  - /boot/config-*"
echo ""
echo "Please notify the Google engineer that the kernel config is not available."
exit 1
