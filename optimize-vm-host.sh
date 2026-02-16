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

echo "[1/6] Installing helper packages (best-effort)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null 2>&1 || true
apt-get install -y cpufrequtils >/dev/null 2>&1 || true

echo ""
echo "[2/6] Optimizing CPU Governor..."
if [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
  for gov in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo "performance" > "${gov}" 2>/dev/null || true
  done

  # Persist via cpufrequtils
  cat > /etc/default/cpufrequtils << 'EOF'
GOVERNOR="performance"
EOF
  systemctl enable cpufrequtils >/dev/null 2>&1 || true
  systemctl restart cpufrequtils >/dev/null 2>&1 || true

  GOVERNOR="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "N/A")"
  echo "   ✓ CPU Governor: ${GOVERNOR}"
else
  echo "   ⚠ CPU frequency scaling not available"
fi

echo ""
echo "[3/6] Configuring sysctl tuning..."

# Write tuning to a dedicated sysctl.d file (avoids duplicates in sysctl.conf)
cat > "${SYSCTL_FILE}" << 'EOF'
# VM Hosting Optimizations (KVM/QEMU)
vm.swappiness=10
vm.dirty_background_ratio=5
vm.dirty_ratio=10
vm.vfs_cache_pressure=50
vm.overcommit_memory=0
vm.min_free_kbytes=131072

# Network tuning (host stack)
net.core.netdev_max_backlog=5000
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_slow_start_after_idle=0
EOF

# Ensure BBR module loads at boot
mkdir -p /etc/modules-load.d
echo "tcp_bbr" > /etc/modules-load.d/bbr.conf

# Apply now
sysctl --system >/dev/null 2>&1 || true

echo "   ✓ Swappiness: $(sysctl -n vm.swappiness 2>/dev/null || echo N/A)"
echo "   ✓ Dirty ratio: $(sysctl -n vm.dirty_ratio 2>/dev/null || echo N/A)%"
echo "   ✓ VFS cache pressure: $(sysctl -n vm.vfs_cache_pressure 2>/dev/null || echo N/A)"
echo "   ✓ Overcommit memory: $(sysctl -n vm.overcommit_memory 2>/dev/null || echo N/A)"
echo "   ✓ Min free kbytes: $(sysctl -n vm.min_free_kbytes 2>/dev/null || echo N/A)"
echo "   ✓ TCP CC: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo N/A)"

echo ""
echo "[4/6] Configuring Transparent Hugepages..."

if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
  # Recommended for mixed VPS hosting
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
echo "[5/6] Persisting disk schedulers (NVMe and SATA SSD) via udev..."

cat > /etc/udev/rules.d/60-io-schedulers.rules << 'EOF'
# NVMe: use none
ACTION=="add|change", KERNEL=="nvme*n1", ATTR{queue/scheduler}="none"

# SATA/SAS: use mq-deadline (kernel will keep default if unsupported)
ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/scheduler}="mq-deadline"
EOF

udevadm control --reload-rules >/dev/null 2>&1 || true
udevadm trigger >/dev/null 2>&1 || true

# Apply immediately best-effort
for dev in /sys/block/nvme*n1/queue/scheduler; do
  [ -e "$dev" ] || continue
  if grep -q '\<none\>' "$dev"; then
    echo none > "$dev" 2>/dev/null || true
  fi
done

for dev in /sys/block/sd*/queue/scheduler; do
  [ -e "$dev" ] || continue
  if grep -q '\<mq-deadline\>' "$dev"; then
    echo mq-deadline > "$dev" 2>/dev/null || true
  fi
done

echo "   ✓ udev rule: /etc/udev/rules.d/60-io-schedulers.rules"

echo ""
echo "[6/6] Verifying..."

sysctl --system >/dev/null 2>&1 || true
echo "   ✓ Sysctl file: ${SYSCTL_FILE}"
echo "   ✓ THP service: configure-thp.service (enabled if present)"

echo ""
echo "=========================================="
echo "✓ Optimization Complete!"
echo "=========================================="
echo ""
echo "Notes:"
echo "  • Reboot is recommended once to confirm CPU governor + udev scheduler rules apply at boot"
echo "  • These are host-level defaults intended for mixed KVM VPS workloads"
echo ""
