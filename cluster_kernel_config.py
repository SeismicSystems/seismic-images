#!/usr/bin/env python3

import re
import sys
from collections import defaultdict

def categorize_config_option(config_name):
    """Categorize a kernel config option based on its name."""
    
    # Define categories based on common kernel subsystem patterns
    categories = {
        'Networking': [
            r'NET_', r'IPV[46]_', r'TCP_', r'UDP_', r'INET_', r'NETDEV_', r'ETHERNET',
            r'WIRELESS', r'WIFI', r'BLUETOOTH', r'6LOWPAN', r'BRIDGE_', r'VLAN_',
            r'NETFILTER', r'PACKET_', r'UNIX_', r'AF_', r'SOCK_', r'SKB_'
        ],
        'Filesystems': [
            r'FS_', r'EXT[234]_', r'XFS_', r'BTRFS_', r'NTFS_', r'FAT_', r'VFAT_',
            r'ISO9660_', r'UDF_', r'NFS_', r'CIFS_', r'FUSE_', r'PROC_', r'SYSFS_',
            r'TMPFS_', r'CRAMFS_', r'SQUASHFS_', r'OVERLAYFS_'
        ],
        'Block Storage': [
            r'BLK_', r'BLOCK_', r'SCSI_', r'ATA_', r'SATA_', r'PATA_', r'IDE_',
            r'MD_', r'DM_', r'RAID_', r'LVM_', r'NVME_', r'MMC_', r'CDROM_'
        ],
        'Graphics/DRM': [
            r'DRM_', r'FB_', r'FRAMEBUFFER', r'GPU_', r'VIDEO_', r'GRAPHICS_',
            r'I915_', r'NOUVEAU_', r'RADEON_', r'AMDGPU_'
        ],
        'Sound/Audio': [
            r'SND_', r'SOUND_', r'ALSA_', r'OSS_', r'AC97_', r'HDA_', r'USB_AUDIO'
        ],
        'USB': [
            r'USB_', r'USBHID_', r'USB_HID_'
        ],
        'Input Devices': [
            r'INPUT_', r'HID_', r'MOUSE_', r'KEYBOARD_', r'JOYSTICK_', r'TOUCHSCREEN_'
        ],
        'Power Management': [
            r'PM_', r'ACPI_', r'APM_', r'CPU_FREQ_', r'CPUFREQ_', r'SUSPEND_',
            r'HIBERNATE_', r'HOTPLUG_CPU'
        ],
        'Security': [
            r'SECURITY_', r'LSM_', r'SELINUX_', r'APPARMOR_', r'SMACK_', r'TOMOYO_',
            r'KEYS_', r'CRYPTO_', r'ENCRYPTED_', r'TRUSTED_'
        ],
        'Virtualization': [
            r'KVM_', r'XEN_', r'VIRT_', r'HYPERV_', r'VMWARE_', r'PARAVIRT_',
            r'VIRTIO_'
        ],
        'CPU Architecture': [
            r'X86_', r'ARM_', r'ARM64_', r'MIPS_', r'SMP_', r'NUMA_', r'MCE_',
            r'CPU_', r'ARCH_'
        ],
        'Memory Management': [
            r'MM_', r'MEMORY_', r'SWAP_', r'ZRAM_', r'ZSWAP_', r'SLUB_', r'SLAB_',
            r'HIGHMEM_', r'SPARSEMEM_', r'FLATMEM_'
        ],
        'Device Drivers': [
            r'I2C_', r'SPI_', r'GPIO_', r'PWM_', r'PINCTRL_', r'REGULATOR_',
            r'HWMON_', r'THERMAL_', r'WATCHDOG_', r'RTC_', r'LEDS_'
        ],
        'Debugging/Tracing': [
            r'DEBUG_', r'TRACE_', r'KPROBES_', r'FTRACE_', r'PERF_', r'LOCKDEP_',
            r'PROVE_', r'DETECT_'
        ],
        'Containers/Namespaces': [
            r'NAMESPACES', r'CGROUP_', r'MEMCG_', r'USER_NS', r'PID_NS', r'NET_NS',
            r'UTS_NS', r'IPC_NS', r'MNT_NS'
        ],
        'Hardware Platforms': [
            r'ACORN_', r'AMIGA_', r'ATARI_', r'MAC_', r'SGI_', r'SUN_', r'SPARC_',
            r'ALPHA_', r'IA64_', r'PARISC_', r'S390_', r'SUPERH_'
        ]
    }
    
    config_upper = config_name.upper()
    
    for category, patterns in categories.items():
        for pattern in patterns:
            if re.search(pattern, config_upper):
                return category
    
    # Try to guess from common prefixes
    if config_upper.startswith('CONFIG_'):
        config_without_prefix = config_upper[7:]  # Remove CONFIG_
        
        # Look for common subsystem indicators
        if any(x in config_without_prefix for x in ['DRIVER', 'DEV']):
            return 'Device Drivers'
        elif any(x in config_without_prefix for x in ['NET', 'SOCK']):
            return 'Networking'
        elif any(x in config_without_prefix for x in ['FILE', 'FS']):
            return 'Filesystems'
        elif any(x in config_without_prefix for x in ['CRYPT', 'HASH']):
            return 'Security'
    
    return 'Miscellaneous'

def parse_diffconfig_output(filename):
    """Parse the diffconfig output and categorize differences."""
    
    categories = defaultdict(list)
    
    with open(filename, 'r') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
                
            # Parse different line formats:
            # -CONFIG_OPTION value
            # +CONFIG_OPTION value  
            # CONFIG_OPTION old_value -> new_value
            
            if line.startswith('-') or line.startswith('+'):
                # Removed or added option
                parts = line[1:].split()
                if parts:
                    config_name = parts[0]
                    category = categorize_config_option(config_name)
                    categories[category].append(line)
            elif ' -> ' in line:
                # Changed option
                parts = line.split()
                if parts:
                    config_name = parts[0]
                    category = categorize_config_option(config_name)
                    categories[category].append(line)
            else:
                # Fallback for other formats
                parts = line.split()
                if parts and parts[0].startswith('CONFIG_'):
                    config_name = parts[0]
                    category = categorize_config_option(config_name)
                    categories[category].append(line)
    
    return categories

def main():
    if len(sys.argv) != 2:
        print("Usage: python3 cluster_kernel_config.py <diffconfig_output_file>")
        sys.exit(1)
    
    input_file = sys.argv[1]
    categories = parse_diffconfig_output(input_file)
    
    # Write clustered output
    output_file = 'kernel-config-diff-clustered.txt'
    
    with open(output_file, 'w') as f:
        f.write("Kernel Configuration Differences - Clustered by Subsystem\n")
        f.write("=" * 60 + "\n\n")
        
        # Sort categories by number of differences (most changes first)
        sorted_categories = sorted(categories.items(), key=lambda x: len(x[1]), reverse=True)
        
        for category, configs in sorted_categories:
            f.write(f"{category} ({len(configs)} changes):\n")
            f.write("-" * 40 + "\n")
            for config in sorted(configs):
                f.write(f"  {config}\n")
            f.write("\n")
    
    print(f"Clustered analysis written to {output_file}")
    
    # Print summary
    print("\nSummary by category:")
    for category, configs in sorted_categories:
        print(f"  {category}: {len(configs)} changes")

if __name__ == "__main__":
    main()