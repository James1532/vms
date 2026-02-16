#!/bin/bash
#
# VM Host Performance Optimization Script
# Optimizes Linux servers for KVM/QEMU/Virtualizor hosting (Ubuntu 22.04)
# Safe to run multiple times (idempotent)
#

set -euo pipefail

echo "=========================================="
echo "VM Host Performance Optimization Script"
echo "=========================================="
echo ""

if [ "${EUID}" -ne 0 ]; then
  echo "ERROR: Please run as root"
  exit 1
fi

SYSCTL_FILE="/etc/sysctl.d/99-vm-host-tuning.conf"

echo "[1/5] Optimizing CPU Governor..."
if [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
  for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo "performance" > "${gov}" 2>/dev/null || true
  done

  # Persist best-effort
  if command -v apt >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y cpufrequtils >/dev/null 2>&1 || true
  fi
  echo 'GOVERNOR="performance"' > /etc/default/cpufrequtils 2>/dev/null || true
  systemctl disable ondemand 2>/dev/null || true
  systemctl enable cpufrequtils 2>/dev/null || true

  GOVERNOR="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "N/A")"
  echo "   ✓ CPU Governor: ${GOVERNOR}"
else
  echo "   ⚠ CPU frequency scaling not available"
fi

echo ""
echo "[2/5] Configuring Memory Management..."

# Write tuning to a dedicated sysctl.d file (avoids appending duplicates to sysctl.conf)
cat > "${SYSCTL_FILE}" << 'EOF'
# VM Hosting Optimizations (KVM/QEMU)
vm.swappiness=10
vm.dirty_background_ratio=5
vm.dirty_ratio=10
vm.vfs_cache_pressure=50
vm.overcommit_memory=0
vm.min_free_kbytes=131072

# Network Performance Tuning (host stack)
net.core.netdev_max_backlog=5000
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_slow_start_after_idle=0
EOF

# Apply now
sysctl --system >/dev/null 2>&1 || true

echo "   ✓ Swappiness: $(sysctl -n vm.swappiness 2>/dev/null || echo N/A)"
echo "   ✓ Dirty ratio: $(sysctl -n vm.dirty_ratio 2>/dev/null || echo N/A)%"
echo "   ✓ VFS cache pressure: $(sysctl -n vm.vfs_cache_pressure 2>/dev/null || echo N/A)"
echo "   ✓ Overcommit memory: $(sysctl -n vm.overcommit_memory 2>/dev/null || echo N/A)"
echo "   ✓ Min free kbytes: $(sysctl -n vm.min_free_kbytes 2>/dev/null || echo N/A)"

echo ""
echo "[3/5] Configuring Transparent Hugepages..."

if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
  # Recommended for mixed VPS hosting: avoid compaction latency spikes
  echo madvise > /sys/kernel/mm/transparent_hugepage/enabled || true
  echo never   > /sys/kernel/mm/transparent_hugepage/defrag  || true

  cat > /etc/systemd/system/configure-thp.service << 'EOFTHP'
[Unit]
Description=Configure Transparent Hugepages for VM Hosting
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'echo madvise > /sys/kernel/mm/transparent_hugepage/enabled'
ExecStart=/bin/bash -c 'echo never > /sys/kernel/mm/transparent_hugepage/defrag'

[Install]
WantedBy=multi-user.target
EOFTHP

  systemctl daemon-reload
  systemctl enable configure-thp.service >/dev/null 2>&1 || true

  THP_EN="$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null | tr -s ' ' | sed 's/.*\[\(.*\)\].*/\1/')"
  THP_DF="$(cat /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null | tr -s ' ' | sed 's/.*\[\(.*\)\].*/\1/')"
  echo "   ✓ THP enabled: ${THP_EN}"
  echo "   ✓ THP defrag:  ${THP_DF}"
else
  echo "   ⚠ Transparent hugepages not available on this kernel"
fi

echo ""
echo "[4/5] Optimizing Disk Schedulers (NVMe and SATA SSD)..."

# NVMe: prefer 'none'
for dev in /sys/block/nvme*n1/queue/scheduler; do
  [ -e "$dev" ] || continue
  if grep -q '\<none\>' "$dev"; then
    echo none > "$dev" 2>/dev/null || true
    echo "   ✓ $(basename "$(dirname "$(dirname "$dev")")"): scheduler set to none"
  fi
done

# SATA/SAS SSD: prefer mq-deadline if available, else leave as-is
for dev in /sys/block/sd*/queue/scheduler; do
  [ -e "$dev" ] || continue
  if grep -q '\<mq-deadline\>' "$dev"; then
    echo mq-deadline > "$dev" 2>/dev/null || true
    echo "   ✓ $(basename "$(dirname "$(dirname "$dev")")"): scheduler set to mq-deadline"
  fi
done

echo ""
echo "[5/5] Verifying Configuration..."

sysctl --system >/dev/null 2>&1 || true

CC="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo N/A)"
QDISC="$(sysctl -n net.core.default_qdisc 2>/dev/null || echo N/A)"
echo "   ✓ TCP Congestion Control: ${CC}"
echo "   ✓ Default qdisc: ${QDISC}"
echo "   ✓ Sysctl file: ${SYSCTL_FILE}"

echo ""
echo "=========================================="
echo "✓ Optimization Complete!"
echo "=========================================="
echo ""
echo "Applied Optimizations:"
echo "  • CPU: Performance governor enabled (best-effort persist)"
echo "  • Memory: Swappiness=10, min_free_kbytes=131072, overcommit_memory=0"
echo "  • THP: enabled=madvise, defrag=never"
echo "  • Network: BBR + fq (host stack)"
echo "  • Disk: NVMe scheduler=none, SATA scheduler=mq-deadline (when available)"
echo ""
echo "Most changes persist across reboots via sysctl.d and systemd service."
echo ""
