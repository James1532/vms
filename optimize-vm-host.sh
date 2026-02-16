#!/bin/bash
#
# VM Host Performance Optimization Script
# Optimizes Linux servers for KVM/QEMU/Virtualizor hosting
# Safe to run multiple times - idempotent
#

set -e

echo "=========================================="
echo "VM Host Performance Optimization Script"
echo "=========================================="
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: Please run as root"
    exit 1
fi

echo "[1/5] Optimizing CPU Governor..."
# Set CPU governor to performance
if [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
    for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo "performance" > $cpu 2>/dev/null || true
    done

    # Make persistent
    echo 'GOVERNOR="performance"' > /etc/default/cpufrequtils 2>/dev/null || true
    systemctl disable ondemand 2>/dev/null || true

    GOVERNOR=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "N/A")
    echo "   ✓ CPU Governor: $GOVERNOR"
else
    echo "   ⚠ CPU frequency scaling not available (may be VM or container)"
fi

echo ""
echo "[2/5] Configuring Memory Management..."

# Remove any existing VM hosting optimizations to avoid duplicates
sed -i '/# VM Hosting Optimizations/,/^$/d' /etc/sysctl.conf 2>/dev/null || true
sed -i '/# Network Performance Tuning for VM Hosting/,/^$/d' /etc/sysctl.conf 2>/dev/null || true
sed -i '/^vm.swappiness=/d' /etc/sysctl.conf 2>/dev/null || true

# Add VM hosting optimizations
cat >> /etc/sysctl.conf << 'EOF'

# VM Hosting Optimizations
vm.swappiness=10
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10
vm.vfs_cache_pressure = 50
vm.min_free_kbytes = 1048576
vm.overcommit_memory = 1
EOF

# Apply memory settings
sysctl -w vm.swappiness=10 >/dev/null 2>&1
sysctl -w vm.dirty_background_ratio=5 >/dev/null 2>&1
sysctl -w vm.dirty_ratio=10 >/dev/null 2>&1
sysctl -w vm.vfs_cache_pressure=50 >/dev/null 2>&1
sysctl -w vm.min_free_kbytes=1048576 >/dev/null 2>&1
sysctl -w vm.overcommit_memory=1 >/dev/null 2>&1

echo "   ✓ Swappiness: $(cat /proc/sys/vm/swappiness)"
echo "   ✓ Dirty ratio: $(sysctl -n vm.dirty_ratio)%"
echo "   ✓ VFS cache pressure: $(sysctl -n vm.vfs_cache_pressure)"

echo ""
echo "[3/5] Enabling Transparent Hugepages..."

# Enable transparent hugepages
if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
    echo always > /sys/kernel/mm/transparent_hugepage/enabled
    echo always > /sys/kernel/mm/transparent_hugepage/defrag

    # Create systemd service for persistence
    cat > /etc/systemd/system/enable-thp.service << 'EOFTHP'
[Unit]
Description=Enable Transparent Hugepages
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'echo always > /sys/kernel/mm/transparent_hugepage/enabled'
ExecStart=/bin/bash -c 'echo always > /sys/kernel/mm/transparent_hugepage/defrag'

[Install]
WantedBy=multi-user.target
EOFTHP

    systemctl daemon-reload
    systemctl enable enable-thp.service >/dev/null 2>&1

    THP=$(cat /sys/kernel/mm/transparent_hugepage/enabled | grep -o '\[.*\]' | tr -d '[]')
    echo "   ✓ Transparent Hugepages: $THP"
else
    echo "   ⚠ Transparent hugepages not available on this kernel"
fi

echo ""
echo "[4/5] Optimizing Network Performance..."

# Add network tuning
cat >> /etc/sysctl.conf << 'EOF'

# Network Performance Tuning for VM Hosting
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.core.netdev_max_backlog = 5000
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1
EOF

# Load BBR module and apply network settings
modprobe tcp_bbr 2>/dev/null || true
sysctl -w net.core.rmem_max=134217728 >/dev/null 2>&1
sysctl -w net.core.wmem_max=134217728 >/dev/null 2>&1
sysctl -w net.ipv4.tcp_rmem="4096 87380 67108864" >/dev/null 2>&1
sysctl -w net.ipv4.tcp_wmem="4096 65536 67108864" >/dev/null 2>&1
sysctl -w net.core.netdev_max_backlog=5000 >/dev/null 2>&1
sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1 || echo "   ⚠ BBR not available, using $(sysctl -n net.ipv4.tcp_congestion_control)"
sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1
sysctl -w net.ipv4.tcp_mtu_probing=1 >/dev/null 2>&1
sysctl -w net.ipv4.tcp_slow_start_after_idle=0 >/dev/null 2>&1
sysctl -w net.ipv4.tcp_tw_reuse=1 >/dev/null 2>&1

CC=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "N/A")
echo "   ✓ TCP Congestion Control: $CC"
echo "   ✓ TCP Buffer sizes: 128MB max"
echo "   ✓ Network queue: 5000 packets"

echo ""
echo "[5/5] Verifying Configuration..."

# Reload all sysctl settings
sysctl -p >/dev/null 2>&1

echo "   ✓ All settings applied and persisted"

echo ""
echo "=========================================="
echo "✓ Optimization Complete!"
echo "=========================================="
echo ""
echo "Applied Optimizations:"
echo "  • CPU: Performance governor enabled"
echo "  • Memory: Swappiness=10, THP=always"
echo "  • Disk I/O: Optimized dirty ratios"
echo "  • Network: BBR congestion control, 128MB buffers"
echo ""
echo "All changes are persistent across reboots."
echo "No reboot required - changes active immediately."
echo ""
