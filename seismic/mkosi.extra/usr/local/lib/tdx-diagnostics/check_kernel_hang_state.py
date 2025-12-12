#!/usr/bin/env python3
"""
Monitor a hanging process to see what it's waiting on in the kernel.
This script helps diagnose where lseek is stuck by reading /proc info.
Run this in a separate terminal while another test is hanging.
"""

import os
import sys
import time
import subprocess

def find_python_processes():
    """Find Python processes that might be hung."""
    try:
        result = subprocess.run(['ps', 'aux'], capture_output=True, text=True)
        lines = result.stdout.split('\n')

        python_procs = []
        for line in lines:
            if 'python' in line.lower() and 'test' in line.lower():
                parts = line.split()
                if len(parts) >= 2:
                    pid = parts[1]
                    python_procs.append((pid, line))

        return python_procs
    except Exception as e:
        print(f"Error finding processes: {e}")
        return []

def check_proc_info(pid):
    """Read /proc info for a specific PID."""
    print(f"\n{'='*70}")
    print(f"Process Info for PID {pid}")
    print(f"{'='*70}\n")

    # Check kernel stack
    print("[Kernel Stack] /proc/{pid}/stack:")
    try:
        with open(f'/proc/{pid}/stack', 'r') as f:
            stack = f.read()
            print(stack)
    except Exception as e:
        print(f"  Error: {e}")

    # Check syscall
    print(f"\n[Current Syscall] /proc/{pid}/syscall:")
    try:
        with open(f'/proc/{pid}/syscall', 'r') as f:
            syscall = f.read()
            print(f"  {syscall}")
    except Exception as e:
        print(f"  Error: {e}")

    # Check status
    print(f"\n[Process Status] /proc/{pid}/status:")
    try:
        with open(f'/proc/{pid}/status', 'r') as f:
            status = f.read()
            # Print just the relevant lines
            for line in status.split('\n')[:20]:
                if line.strip():
                    print(f"  {line}")
    except Exception as e:
        print(f"  Error: {e}")

    # Check wchan (what channel/event it's waiting on)
    print(f"\n[Wait Channel] /proc/{pid}/wchan:")
    try:
        with open(f'/proc/{pid}/wchan', 'r') as f:
            wchan = f.read().strip()
            print(f"  {wchan}")
    except Exception as e:
        print(f"  Error: {e}")

def monitor_pid(pid):
    """Continuously monitor a PID."""
    print(f"Monitoring PID {pid}. Press Ctrl+C to stop.")
    print("=" * 70)

    try:
        while True:
            check_proc_info(pid)
            print(f"\nRefreshing in 5 seconds...")
            time.sleep(5)
    except KeyboardInterrupt:
        print("\nMonitoring stopped.")

def main():
    if len(sys.argv) > 1:
        # PID provided as argument
        pid = sys.argv[1]
        monitor_pid(pid)
    else:
        # Try to find hanging Python processes
        print("Searching for Python test processes...")
        procs = find_python_processes()

        if not procs:
            print("\nNo Python test processes found.")
            print(f"\nUsage: {sys.argv[0]} <pid>")
            print("Run this while a test is hanging in another terminal.")
            sys.exit(1)

        print(f"\nFound {len(procs)} Python process(es):")
        for i, (pid, line) in enumerate(procs, 1):
            print(f"{i}. PID {pid}: {line}")

        if len(procs) == 1:
            pid = procs[0][0]
            print(f"\nMonitoring PID {pid}")
            monitor_pid(pid)
        else:
            print("\nPlease specify which PID to monitor:")
            print(f"Usage: {sys.argv[0]} <pid>")

if __name__ == "__main__":
    main()
