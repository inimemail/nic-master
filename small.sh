#!/usr/bin/env bash
set -euo pipefail

VERSION="2.1.1-safe-udp-aware"
WORKDIR="/opt/live-relay-tuner"
NIC_ENV_FILE="/etc/live-relay-nic.env"
NIC_HELPER="/usr/local/sbin/live-relay-nic-apply.sh"
NIC_SERVICE="/etc/systemd/system/live-relay-nic-tuning.service"
LIMITS_FILE="/etc/security/limits.d/99-live-relay.conf"
SYSTEMD_LIMIT_DIR="/etc/systemd/system.conf.d"
SYSTEMD_LIMIT_FILE="$SYSTEMD_LIMIT_DIR/99-live-relay.conf"
SYSCTL_DIR="/etc/sysctl.d"
SYSCTL_FILE="$SYSCTL_DIR/99-live-relay.conf"
STATE_FILE="$WORKDIR/state.env"
SYSCTL_LOG="/tmp/live-relay-sysctl.log"

GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
BLUE='\033[36m'
RESET='\033[0m'

log()  { echo -e "${GREEN}[信息]${RESET} $*"; }
warn() { echo -e "${YELLOW}[警告]${RESET} $*"; }
err()  { echo -e "${RED}[错误]${RESET} $*"; }
info() { echo -e "${BLUE}[处理中]${RESET} $*"; }

need_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    err "请使用 root 权限运行。"
    exit 1
  fi
}

mkdir -p "$WORKDIR" "$SYSCTL_DIR"

is_container() {
  grep -qaE 'docker|lxc|container|kubepods' /proc/1/cgroup 2>/dev/null || \
  grep -qaE 'container=' /proc/1/environ 2>/dev/null
}

detect_pm() {
  if command -v apt-get >/dev/null 2>&1; then echo apt; return; fi
  if command -v dnf >/dev/null 2>&1; then echo dnf; return; fi
  if command -v yum >/dev/null 2>&1; then echo yum; return; fi
  if command -v zypper >/dev/null 2>&1; then echo zypper; return; fi
  if command -v pacman >/dev/null 2>&1; then echo pacman; return; fi
  echo none
}

install_packages() {
  local pm="$1"; shift || true
  [ "$#" -gt 0 ] || return 0
  case "$pm" in
    apt)
      DEBIAN_FRONTEND=noninteractive apt-get update -y && \
      DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
      ;;
    dnf)
      dnf install -y "$@"
      ;;
    yum)
      yum install -y "$@"
      ;;
    zypper)
      zypper --non-interactive install "$@"
      ;;
    pacman)
      pacman -Sy --noconfirm "$@"
      ;;
    *)
      return 1
      ;;
  esac
}

ensure_cmd() {
  local cmd="$1"
  local pm pkg_apt pkg_rpm pkg_pac pkg_zypper
  case "$cmd" in
    ethtool) pkg_apt="ethtool"; pkg_rpm="ethtool"; pkg_pac="ethtool"; pkg_zypper="ethtool" ;;
    python3) pkg_apt="python3"; pkg_rpm="python3"; pkg_pac="python"; pkg_zypper="python3" ;;
    lscpu) pkg_apt="util-linux"; pkg_rpm="util-linux"; pkg_pac="util-linux"; pkg_zypper="util-linux" ;;
    ip) pkg_apt="iproute2"; pkg_rpm="iproute"; pkg_pac="iproute2"; pkg_zypper="iproute2" ;;
    tc) pkg_apt="iproute2"; pkg_rpm="iproute"; pkg_pac="iproute2"; pkg_zypper="iproute2" ;;
    modprobe) pkg_apt="kmod"; pkg_rpm="kmod"; pkg_pac="kmod"; pkg_zypper="kmod" ;;
    *) return 0 ;;
  esac

  if command -v "$cmd" >/dev/null 2>&1; then
    return 0
  fi

  pm=$(detect_pm)
  warn "$cmd 未找到，正在尝试自动安装。"
  case "$pm" in
    apt) install_packages "$pm" "$pkg_apt" ;;
    dnf|yum) install_packages "$pm" "$pkg_rpm" ;;
    pacman) install_packages "$pm" "$pkg_pac" ;;
    zypper) install_packages "$pm" "$pkg_zypper" ;;
    *) err "未找到受支持的包管理器，请手动安装 $cmd。"; return 1 ;;
  esac

  command -v "$cmd" >/dev/null 2>&1
}

current_cc_algo() {
  sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo cubic
}

pick_cc_algo() {
  local available current
  current=$(current_cc_algo)
  available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
  if echo " $available " | grep -q ' bbr '; then
    echo bbr
    return 0
  fi
  modprobe tcp_bbr >/dev/null 2>&1 || true
  available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
  if echo " $available " | grep -q ' bbr '; then
    echo bbr
    return 0
  fi
  warn "当前内核不支持 BBR，回退到当前拥塞控制算法：$current"
  echo "$current"
}

write_limits() {
  mkdir -p "$(dirname "$LIMITS_FILE")" "$SYSTEMD_LIMIT_DIR"
  cat > "$LIMITS_FILE" <<'EOF_LIMITS'
* soft nofile 1048576
* hard nofile 1048576
* soft nproc  1048576
* hard nproc  1048576
root soft nofile 1048576
root hard nofile 1048576
root soft nproc  1048576
root hard nproc  1048576
EOF_LIMITS

  cat > "$SYSTEMD_LIMIT_FILE" <<'EOF_SYSTEMD'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=1048576
DefaultTasksMax=infinity
EOF_SYSTEMD

  ulimit -SHn 1048576 || true
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reexec >/dev/null 2>&1 || systemctl daemon-reload >/dev/null 2>&1 || true
  fi
}

sysctl_proc_path() {
  echo "/proc/sys/${1//./\/}"
}

begin_sysctl_file() {
  local title="$1"
  cat > "$SYSCTL_FILE" <<EOF_HEADER
# =====================================================
# Live Relay Tuner $VERSION (Safe UDP Aware)
# $title
# 自动生成，请勿手工编辑
# =====================================================
EOF_HEADER
}

append_if_supported() {
  local key="$1" value="$2" path
  path=$(sysctl_proc_path "$key")
  if [ -e "$path" ]; then
    printf '%s = %s\n' "$key" "$value" >> "$SYSCTL_FILE"
  else
    warn "当前内核未提供 $key，已跳过。"
  fi
}

mem_total_kb() {
  awk '/MemTotal:/ {print $2; exit}' /proc/meminfo
}

mem_total_gb() {
  awk '/MemTotal:/ {printf "%d\n", int(($2 + 1048575) / 1048576)}' /proc/meminfo
}

calc_conntrack_buckets() {
  local mem_kb buckets
  mem_kb=$(mem_total_kb)
  buckets=$(( mem_kb / 16 ))
  [ "$buckets" -lt 1024 ] && buckets=1024
  [ "$buckets" -gt 262144 ] && buckets=262144
  echo "$buckets"
}

calc_conntrack_max() {
  local buckets multiplier
  buckets=$(calc_conntrack_buckets)
  multiplier="${CONNTRACK_MULTIPLIER:-2}"
  case "$multiplier" in
    ''|*[!0-9]*) multiplier=2 ;;
  esac
  [ "$multiplier" -lt 1 ] && multiplier=1
  echo $(( buckets * multiplier ))
}

# --- 新增的 UDP 动态页计算引擎 ---
calc_udp_mem_pages() {
  local mem_gb page_size pages min pressure max
  mem_gb=$(mem_total_gb)
  page_size=$(getconf PAGE_SIZE 2>/dev/null || echo 4096)
  pages=$(awk -v ps="$page_size" '/MemTotal:/ {print int(($2 * 1024) / ps); exit}' /proc/meminfo)

  if [ "$mem_gb" -ge 128 ]; then
    min=$(( pages / 256 ))
    pressure=$(( pages / 128 ))
    max=$(( pages / 64 ))
  elif [ "$mem_gb" -ge 32 ]; then
    min=$(( pages / 512 ))
    pressure=$(( pages / 256 ))
    max=$(( pages / 128 ))
  else
    min=$(( pages / 1024 ))
    pressure=$(( pages / 512 ))
    max=$(( pages / 256 ))
  fi

  [ "$min" -lt 4096 ] && min=4096
  [ "$pressure" -le "$min" ] && pressure=$(( min * 2 ))
  [ "$max" -le "$pressure" ] && max=$(( pressure * 2 ))

  echo "$min $pressure $max"
}

append_common_sysctls() {
  local cc="$1"
  append_if_supported net.core.default_qdisc fq
  append_if_supported net.ipv4.tcp_congestion_control "$cc"

  append_if_supported net.ipv4.tcp_mtu_probing 1
  append_if_supported net.ipv4.tcp_slow_start_after_idle 0
  append_if_supported net.ipv4.tcp_limit_output_bytes 1048576
  append_if_supported net.ipv4.tcp_notsent_lowat 131072
  append_if_supported net.ipv4.ip_local_port_range "10000 65535"

  append_if_supported net.ipv4.tcp_fin_timeout 10
  append_if_supported net.ipv4.tcp_keepalive_time 300
  append_if_supported net.ipv4.tcp_keepalive_intvl 30
  append_if_supported net.ipv4.tcp_keepalive_probes 5

  append_if_supported vm.swappiness 1
  append_if_supported vm.overcommit_memory 1
  append_if_supported vm.dirty_background_bytes 67108864
  append_if_supported vm.dirty_bytes 268435456
}

append_stable_sysctls() {
  local udp_mem
  udp_mem=$(calc_udp_mem_pages)

  append_if_supported net.core.somaxconn 32768
  append_if_supported net.ipv4.tcp_max_syn_backlog 32768
  append_if_supported net.core.netdev_max_backlog 32768
  append_if_supported net.core.netdev_budget 300
  append_if_supported net.core.netdev_budget_usecs 4000
  append_if_supported net.core.dev_weight 128

  append_if_supported fs.file-max 2097152

  append_if_supported net.core.rmem_max 67108864
  append_if_supported net.core.wmem_max 67108864
  append_if_supported net.core.rmem_default 1048576
  append_if_supported net.core.wmem_default 262144
  append_if_supported net.core.optmem_max 262144

  append_if_supported net.ipv4.tcp_rmem "4096 262144 67108864"
  append_if_supported net.ipv4.tcp_wmem "4096 65536 67108864"
  
  # 注入安全的 UDP 内存页大小
  append_if_supported net.ipv4.udp_mem "$udp_mem"
  append_if_supported net.ipv4.udp_rmem_min 131072
}

append_hyper_sysctls() {
  local udp_mem
  udp_mem=$(calc_udp_mem_pages)

  append_if_supported net.core.somaxconn 65535
  append_if_supported net.ipv4.tcp_max_syn_backlog 65535
  append_if_supported net.core.netdev_max_backlog 131072
  append_if_supported net.core.netdev_budget 600
  append_if_supported net.core.netdev_budget_usecs 8000
  append_if_supported net.core.dev_weight 256
  append_if_supported net.core.dev_weight_rx_bias 2
  append_if_supported net.core.dev_weight_tx_bias 2

  append_if_supported fs.file-max 4194304

  append_if_supported net.core.rmem_max 134217728
  append_if_supported net.core.wmem_max 134217728
  append_if_supported net.core.rmem_default 2097152
  append_if_supported net.core.wmem_default 524288
  append_if_supported net.core.optmem_max 262144

  append_if_supported net.ipv4.tcp_rmem "4096 262144 134217728"
  append_if_supported net.ipv4.tcp_wmem "4096 131072 134217728"
  
  # 注入极限 UDP 内存页大小
  append_if_supported net.ipv4.udp_mem "$udp_mem"
  append_if_supported net.ipv4.udp_rmem_min 524288

  append_if_supported net.ipv4.tcp_limit_output_bytes 2097152
  append_if_supported net.ipv4.tcp_notsent_lowat 131072

  append_if_supported vm.dirty_background_bytes 134217728
  append_if_supported vm.dirty_bytes 536870912

  if [ "${ENABLE_BUSY_POLL:-0}" = "1" ]; then
    append_if_supported net.core.busy_read 50
    append_if_supported net.core.busy_poll 50
  fi
}

append_conntrack_sysctls() {
  local profile="$1" buckets max_est ct_max
  modprobe nf_conntrack >/dev/null 2>&1 || true

  if [ ! -e /proc/sys/net/netfilter/nf_conntrack_max ]; then
    warn "未检测到 nf_conntrack，跳过连接跟踪调优。"
    return 0
  fi

  buckets=$(calc_conntrack_buckets)
  ct_max=$(calc_conntrack_max)

  append_if_supported net.netfilter.nf_conntrack_buckets "$buckets"
  append_if_supported net.netfilter.nf_conntrack_max "$ct_max"

  if [ "$profile" = "2" ]; then
    max_est=1800
  else
    max_est=7200
  fi

  append_if_supported net.netfilter.nf_conntrack_tcp_timeout_established "$max_est"
  append_if_supported net.netfilter.nf_conntrack_tcp_timeout_syn_recv 20
  append_if_supported net.netfilter.nf_conntrack_tcp_timeout_syn_sent 20
  append_if_supported net.netfilter.nf_conntrack_tcp_timeout_unacknowledged 60
  append_if_supported net.netfilter.nf_conntrack_tcp_timeout_fin_wait 20
  append_if_supported net.netfilter.nf_conntrack_tcp_timeout_time_wait 30
  append_if_supported net.netfilter.nf_conntrack_tcp_timeout_close_wait 30
  append_if_supported net.netfilter.nf_conntrack_tcp_timeout_close 10
  append_if_supported net.netfilter.nf_conntrack_udp_timeout 15
  append_if_supported net.netfilter.nf_conntrack_udp_timeout_stream 120
}

write_profile_1() {
  local cc="$1"
  begin_sysctl_file "稳定高容量配置 (UDP感知)"
  append_common_sysctls "$cc"
  append_stable_sysctls
  append_conntrack_sysctls 1
}

write_profile_2() {
  local cc="$1"
  begin_sysctl_file "极限低延迟直播配置 (UDP感知)"
  append_common_sysctls "$cc"
  append_hyper_sysctls
  append_conntrack_sysctls 2
}

apply_sysctl_file() {
  if sysctl -p "$SYSCTL_FILE" >"$SYSCTL_LOG" 2>&1; then
    log "sysctl 参数应用成功。"
    return 0
  fi
  err "sysctl 应用失败，请检查 $SYSCTL_LOG"
  return 1
}

persist_state() {
  mkdir -p "$WORKDIR"
  cat > "$STATE_FILE" <<EOF_STATE
PROFILE=$1
NIC=${2:-}
UPDATED_AT=$(date +%F_%T)
EOF_STATE
}

remove_mode2_service() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now live-relay-nic-tuning.service >/dev/null 2>&1 || true
  fi
  rm -f "$NIC_SERVICE" "$NIC_HELPER" "$NIC_ENV_FILE"
}

build_nic_helper() {
  cat > "$NIC_HELPER" <<'EOF_HELPER'
#!/usr/bin/env bash
set -euo pipefail

NIC_ENV_FILE="/etc/live-relay-nic.env"
[ -f "$NIC_ENV_FILE" ] || { echo "缺少 $NIC_ENV_FILE"; exit 1; }
# shellcheck disable=SC1090
source "$NIC_ENV_FILE"

DEV="${DEV:-}"
[ -n "$DEV" ] || { echo "DEV 为空"; exit 1; }
command -v ethtool >/dev/null 2>&1 || { echo "未找到 ethtool"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "未找到 python3"; exit 1; }

_expand_cpulist() {
  python3 - "$1" <<'PY'
import sys
s = sys.argv[1].strip()
out = []
if s:
    for part in s.split(','):
        if '-' in part:
            a, b = map(int, part.split('-', 1))
            out.extend(range(a, b + 1))
        else:
            out.append(int(part))
print("\n".join(map(str, out)))
PY
}

_cpulist_to_mask() {
  python3 - "$1" <<'PY'
import sys
mask = 0
s = sys.argv[1].strip()
if s:
    for part in s.split(','):
        if '-' in part:
            a, b = map(int, part.split('-', 1))
            for i in range(a, b + 1):
                mask |= 1 << i
        else:
            mask |= 1 << int(part)
h = f"{mask:x}"
if not h:
    print("0")
else:
    groups = []
    while h:
        groups.append(h[-8:].rjust(8, "0"))
        h = h[:-8]
    print(",".join(reversed(groups)))
PY
}

_get_default_cpus() {
  if [ "${USE_HT:-0}" = "1" ]; then
    _expand_cpulist "$(cat /sys/devices/system/cpu/online)"
  elif command -v lscpu >/dev/null 2>&1; then
    lscpu -p=CPU,CORE,SOCKET,ONLINE | awk -F, '!/^#/ && $4=="Y" { key=$3":"$2; if (!(key in seen)) { seen[key]=1; print $1 } }'
  else
    _expand_cpulist "$(cat /sys/devices/system/cpu/online)"
  fi
}

if ! ip link show "$DEV" >/dev/null 2>&1; then
  echo "网卡接口 $DEV 不存在"
  exit 1
fi

if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet irqbalance 2>/dev/null; then
  if [ "${DISABLE_IRQBALANCE:-1}" = "1" ]; then
    systemctl stop irqbalance >/dev/null 2>&1 || true
    systemctl disable irqbalance >/dev/null 2>&1 || true
  fi
fi

mapfile -t BASE_CPUS < <(_get_default_cpus | sort -n)
[ "${#BASE_CPUS[@]}" -gt 0 ] || { echo "未找到在线 CPU"; exit 1; }

TARGET_CPUS="${TARGET_CPUS:-0}"
if [ "$TARGET_CPUS" -le 0 ] || [ "$TARGET_CPUS" -gt "${#BASE_CPUS[@]}" ]; then
  TARGET_CPUS="${#BASE_CPUS[@]}"
fi

CPUS=()
for ((i=0; i<TARGET_CPUS; i++)); do
  CPUS+=("${BASE_CPUS[$i]}")
done
CPU_CSV=$(IFS=,; echo "${CPUS[*]}")

echo "网卡: $DEV"
echo "目标 CPU: $CPU_CSV"

if ethtool -l "$DEV" >/dev/null 2>&1; then
  MAX_COMBINED=$(ethtool -l "$DEV" 2>/dev/null | awk '
    /Pre-set maximums:/ {sec=1; next}
    /Current hardware settings:/ {sec=0}
    sec && /Combined:/ {print $2; exit}
  ')
  if [ -n "$MAX_COMBINED" ] && [ "$MAX_COMBINED" -gt 0 ]; then
    NEW_COMBINED="$TARGET_CPUS"
    [ "$NEW_COMBINED" -gt "$MAX_COMBINED" ] && NEW_COMBINED="$MAX_COMBINED"
    ethtool -L "$DEV" combined "$NEW_COMBINED" >/dev/null 2>&1 || true
  fi
fi

if [ "${MAX_RINGS:-0}" = "1" ] && ethtool -g "$DEV" >/dev/null 2>&1; then
  RXMAX=$(ethtool -g "$DEV" 2>/dev/null | awk '
    /Pre-set maximums:/ {sec=1; next}
    /Current hardware settings:/ {sec=0}
    sec && $1=="RX:" {print $2; exit}
  ')
  TXMAX=$(ethtool -g "$DEV" 2>/dev/null | awk '
    /Pre-set maximums:/ {sec=1; next}
    /Current hardware settings:/ {sec=0}
    sec && $1=="TX:" {print $2; exit}
  ')
  if [ -n "$RXMAX" ] && [ -n "$TXMAX" ] && [ "$RXMAX" -gt 0 ] && [ "$TXMAX" -gt 0 ]; then
    ethtool -G "$DEV" rx "$RXMAX" tx "$TXMAX" >/dev/null 2>&1 || true
  fi
fi

mapfile -t RXQS < <(find "/sys/class/net/$DEV/queues" -maxdepth 1 -type d -name 'rx-*' | sort -V)
mapfile -t TXQS < <(find "/sys/class/net/$DEV/queues" -maxdepth 1 -type d -name 'tx-*' | sort -V)
mapfile -t IRQS < <(awk -v dev="$DEV" '$0 ~ dev {gsub(":","",$1); print $1}' /proc/interrupts)

if [ "${#IRQS[@]}" -gt 0 ]; then
  for ((i=0; i<${#IRQS[@]}; i++)); do
    IRQ="${IRQS[$i]}"
    CPU="${CPUS[$(( i % ${#CPUS[@]} ))]}"
    if [ -w "/proc/irq/$IRQ/smp_affinity_list" ]; then
      echo "$CPU" > "/proc/irq/$IRQ/smp_affinity_list" || true
    fi
  done
fi

if [ "${#TXQS[@]}" -gt 1 ]; then
  for ((i=0; i<${#TXQS[@]}; i++)); do
    CPU="${CPUS[$(( i % ${#CPUS[@]} ))]}"
    MASK=$(_cpulist_to_mask "$CPU")
    if [ -w "${TXQS[$i]}/xps_cpus" ]; then
      echo "$MASK" > "${TXQS[$i]}/xps_cpus" || true
    fi
  done
fi

if [ "${#RXQS[@]}" -gt 0 ]; then
  if [ "${#RXQS[@]}" -lt "${#CPUS[@]}" ]; then
    TOTAL_FLOWS="${RFS_FLOW_ENTRIES:-65536}"
    echo "$TOTAL_FLOWS" > /proc/sys/net/core/rps_sock_flow_entries || true
    PERQ=$(( TOTAL_FLOWS / ${#RXQS[@]} ))
    [ "$PERQ" -lt 1024 ] && PERQ=1024
    for ((i=0; i<${#RXQS[@]}; i++)); do
      IRQCPU="${CPUS[$(( i % ${#CPUS[@]} ))]}"
      OTHERS=()
      for CPU in "${CPUS[@]}"; do
        [ "$CPU" -ne "$IRQCPU" ] && OTHERS+=("$CPU")
      done
      [ "${#OTHERS[@]}" -eq 0 ] && OTHERS=("$IRQCPU")
      LIST=$(IFS=,; echo "${OTHERS[*]}")
      MASK=$(_cpulist_to_mask "$LIST")
      [ -w "${RXQS[$i]}/rps_cpus" ] && echo "$MASK" > "${RXQS[$i]}/rps_cpus" || true
      [ -w "${RXQS[$i]}/rps_flow_cnt" ] && echo "$PERQ" > "${RXQS[$i]}/rps_flow_cnt" || true
    done
  else
    for Q in "${RXQS[@]}"; do
      [ -w "$Q/rps_cpus" ] && echo 0 > "$Q/rps_cpus" || true
    done
    echo 0 > /proc/sys/net/core/rps_sock_flow_entries || true
  fi
fi

echo "网卡调优已应用到 $DEV"
EOF_HELPER
  chmod +x "$NIC_HELPER"
}

build_nic_service() {
  cat > "$NIC_SERVICE" <<'EOF_SERVICE'
[Unit]
Description=Live Relay 网卡调优
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/live-relay-nic-apply.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_SERVICE
}

default_nic() {
  ip -o route show to default 2>/dev/null | awk '{print $5; exit}' || true
}

select_nic_noninteractive() {
  local nic="${NIC:-$(default_nic)}"
  if [ -n "$nic" ] && ip link show "$nic" >/dev/null 2>&1; then
    echo "$nic"
    return 0
  fi

  nic=$(ip -o link show | awk -F': ' '$2 !~ /lo/ {print $2; exit}')
  if [ -n "$nic" ]; then
    echo "$nic"
    return 0
  fi
  return 1
}

setup_mode2_persistence() {
  local nic="$1"
  ensure_cmd ethtool
  ensure_cmd python3
  ensure_cmd ip
  ensure_cmd lscpu || true

  build_nic_helper
  build_nic_service

  cat > "$NIC_ENV_FILE" <<EOF_NICENV
DEV=$nic
USE_HT=0
MAX_RINGS=1
TARGET_CPUS=0
RFS_FLOW_ENTRIES=65536
DISABLE_IRQBALANCE=1
EOF_NICENV

  "$NIC_HELPER"

  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload
    systemctl enable --now live-relay-nic-tuning.service >/dev/null 2>&1 || true
    log "模式 2 的网卡调优服务已安装并启用。"
  else
    warn "未找到 systemd，网卡调优已立即生效，但重启后不会持久保留。"
  fi
}

apply_profile() {
  local mode="$1" cc nic
  cc=$(pick_cc_algo)
  log "选择拥塞控制算法：$cc"
  write_limits

  case "$mode" in
    1)
      write_profile_1 "$cc"
      remove_mode2_service
      ;;
    2)
      write_profile_2 "$cc"
      ;;
    *)
      err "未知模式：$mode"
      return 1
      ;;
  esac

  apply_sysctl_file

  if [ "$mode" = "2" ]; then
    if is_container; then
      warn "检测到容器环境，跳过网卡队列 / IRQ 调优及持久化。"
      nic=""
    else
      nic=$(select_nic_noninteractive || true)
      if [ -z "$nic" ]; then
        warn "无法自动检测网卡，跳过网卡队列调优。如有需要请设置 NIC=eth0 后重新执行模式 2。"
      else
        log "使用网卡：$nic"
        setup_mode2_persistence "$nic"
      fi
    fi
    persist_state "2" "${nic:-}"
  else
    persist_state "1" ""
  fi

  show_status
}

show_status() {
  local nic cc qdisc avail profile saved_nic
  local driver speed numa
  profile="unknown"
  saved_nic=""

  if [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE" || true
    profile="${PROFILE:-unknown}"
    saved_nic="${NIC:-}"
  fi

  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
  qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)
  avail=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
  nic="${saved_nic:-$(default_nic)}"

  echo
  echo "================ 状态信息 ================"
  printf '%-22s %s\n' "当前配置:" "$profile"
  printf '%-22s %s\n' "拥塞控制算法:" "$cc"
  printf '%-22s %s\n' "可用拥塞控制:" "$avail"
  printf '%-22s %s\n' "默认 qdisc:" "$qdisc"
  printf '%-22s %s\n' "somaxconn:" "$(sysctl -n net.core.somaxconn 2>/dev/null || true)"
  printf '%-22s %s\n' "tcp_max_syn_backlog:" "$(sysctl -n net.ipv4.tcp_max_syn_backlog 2>/dev/null || true)"
  printf '%-22s %s\n' "netdev_max_backlog:" "$(sysctl -n net.core.netdev_max_backlog 2>/dev/null || true)"
  printf '%-22s %s\n' "netdev_budget:" "$(sysctl -n net.core.netdev_budget 2>/dev/null || true)"
  printf '%-22s %s\n' "budget_usecs:" "$(sysctl -n net.core.netdev_budget_usecs 2>/dev/null || true)"
  printf '%-22s %s\n' "fs.file-max:" "$(sysctl -n fs.file-max 2>/dev/null || true)"
  printf '%-22s %s\n' "tcp_rmem:" "$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null || true)"
  printf '%-22s %s\n' "tcp_wmem:" "$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null || true)"
  printf '%-22s %s\n' "udp_mem:" "$(sysctl -n net.ipv4.udp_mem 2>/dev/null || echo n/a)"
  printf '%-22s %s\n' "udp_rmem_min:" "$(sysctl -n net.ipv4.udp_rmem_min 2>/dev/null || true)"
  printf '%-22s %s\n' "tcp_limit_output:" "$(sysctl -n net.ipv4.tcp_limit_output_bytes 2>/dev/null || true)"
  printf '%-22s %s\n' "tcp_notsent_lowat:" "$(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null || true)"
  printf '%-22s %s\n' "conntrack_count:" "$(sysctl -n net.netfilter.nf_conntrack_count 2>/dev/null || echo n/a)"
  printf '%-22s %s\n' "conntrack_max:" "$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo n/a)"
  printf '%-22s %s\n' "检测到的网卡:" "${nic:-none}"

  if [ -n "$nic" ] && command -v ethtool >/dev/null 2>&1 && ip link show "$nic" >/dev/null 2>&1; then
    driver="$(ethtool -i "$nic" 2>/dev/null | awk -F': ' '/driver:/ {print $2; exit}')"
    speed="$(ethtool "$nic" 2>/dev/null | awk -F': ' '/Speed:/ {print $2; exit}')"
    if [ -r "/sys/class/net/$nic/device/numa_node" ]; then
      numa="$(cat "/sys/class/net/$nic/device/numa_node" 2>/dev/null || echo -1)"
    else
      numa="-1"
    fi

    printf '%-22s %s\n' "驱动:" "${driver:-unknown}"
    printf '%-22s %s\n' "链路速率:" "${speed:-unknown}"
    printf '%-22s %s\n' "NUMA 节点:" "$numa"

    if ethtool -l "$nic" >/dev/null 2>&1; then
      local max_combined cur_combined
      max_combined="$(ethtool -l "$nic" 2>/dev/null | awk '
        /Pre-set maximums:/ {sec=1; next}
        /Current hardware settings:/ {sec=0}
        sec && /Combined:/ {print $2; exit}
      ')"
      cur_combined="$(ethtool -l "$nic" 2>/dev/null | awk '
        /Current hardware settings:/ {sec=1; next}
        sec && /Combined:/ {print $2; exit}
      ')"
      printf '%-22s %s\n' "网卡通道信息:" "combined ${cur_combined:-unknown}/${max_combined:-unknown}"
    fi

    if ethtool -c "$nic" >/dev/null 2>&1; then
      echo "coalesce:"
      ethtool -c "$nic" 2>/dev/null | awk -F': ' '
        /adaptive-rx:/ || /adaptive-tx:/ || /rx-usecs:/ || /tx-usecs:/ {
          gsub(/^[ \t]+/, "", $1)
          printf "  %-18s %s\n", $1 ":", $2
        }
      ' || true
    fi

    echo "网卡错误信息:"
    ethtool -S "$nic" 2>/dev/null | awk -F': ' '
      /rx_(missed|over|dropped)/ || /tx_.*errors/ {
        gsub(/^[ \t]+/, "", $1)
        printf "  %-26s %s\n", $1 ":", $2
        found=1
      }
      END {
        if (!found) print "  无明显错误计数"
      }
    ' || true

    echo "IRQ 分布:"
    awk -v dev="$nic" '
      $0 ~ dev {
        irq=$1
        sub(":", "", irq)

        sum=0
        for (i=2; i<=NF; i++) {
          if ($i ~ /^[0-9]+$/) sum += $i
          else break
        }

        name=$NF
        printf "  IRQ %-4s 总中断=%-12s 设备=%s\n", irq, sum, name
        found=1
      }
      END {
        if (!found) print "  未找到相关 IRQ"
      }
    ' /proc/interrupts || true

    echo "IRQ 亲和性:"
    {
      found_irq=0
      while read -r irq; do
        [ -n "$irq" ] || continue
        found_irq=1
        if [ -r "/proc/irq/$irq/smp_affinity_list" ]; then
          printf '  IRQ %-4s CPU=%s\n' "$irq" "$(cat "/proc/irq/$irq/smp_affinity_list" 2>/dev/null)"
        else
          printf '  IRQ %-4s CPU=%s\n' "$irq" "unknown"
        fi
      done < <(awk -v dev="$nic" '$0 ~ dev {gsub(":", "", $1); print $1}' /proc/interrupts)

      [ "$found_irq" -eq 1 ] || echo "  未找到相关 IRQ"
    } || true

    if command -v tc >/dev/null 2>&1; then
      echo "qdisc:"
      tc qdisc show dev "$nic" 2>/dev/null | sed 's/^/  /' || true
      printf '%-22s %s\n' "leaf fq 统计:" "$(
        tc qdisc show dev "$nic" 2>/dev/null | awk '
          / parent / {total++}
          / parent / && / fq / {fq++}
          END {printf "%d/%d", fq+0, total+0}
        '
      )"
    fi
  fi

  if command -v systemctl >/dev/null 2>&1; then
    if systemctl cat live-relay-nic-tuning.service >/dev/null 2>&1; then
      printf '%-22s %s\n' "网卡调优服务:" "$(systemctl is-enabled live-relay-nic-tuning.service 2>/dev/null || echo disabled)"
    else
      printf '%-22s %s\n' "网卡调优服务:" "disabled"
    fi
  fi

  printf '%-22s %s\n' "sysctl 文件:" "$SYSCTL_FILE"
  printf '%-22s %s\n' "网卡环境文件:" "$NIC_ENV_FILE"
  echo "========================================="
  echo
}

cleanup_live_relay() {
  echo -e "${BLUE}[处理中] 正在清理历史调优配置文件...${RESET}"
  remove_mode2_service
  rm -f "$LIMITS_FILE" "$SYSTEMD_LIMIT_FILE" "$SYSCTL_FILE" "$STATE_FILE"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  if grep -qaE 'lxc|container' /proc/1/environ 2>/dev/null || grep -qaE 'lxc|container' /proc/1/cgroup 2>/dev/null; then
    echo -e "${YELLOW}⚠️ 检测到当前环境为 LXC 容器，已完成基础清理，但跳过 HIA BBR 优化。${RESET}"
    return
  fi

  echo -e "${GREEN}[信息] 正在注入 HIA 极限基线参数...${RESET}"
  cp -n /etc/sysctl.conf /etc/sysctl.conf.bak || true

  cat > /etc/sysctl.conf <<EOF
# ===== HIA BBR + TCP 优化参数 =====
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 50331648
net.core.wmem_max = 50331648
net.core.rmem_default = 6291456
net.core.wmem_default = 6291456
net.ipv4.tcp_rmem = 4096 87380 50331648
net.ipv4.tcp_wmem = 4096 65536 50331648
net.ipv4.udp_rmem_min = 131072
net.ipv4.udp_wmem_min = 131072
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_ecn = 0
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_early_retrans = 3
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_retries1 = 3
net.ipv4.tcp_retries2 = 8
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.core.netdev_max_backlog = 150000
net.core.netdev_budget = 700
net.core.netdev_budget_usecs = 1200
net.core.dev_weight = 768
net.core.dev_weight_tx_bias = 2
net.core.optmem_max = 81920
net.core.busy_poll = 50
net.core.busy_read = 50
net.ipv4.ip_local_port_range = 1024 65535
fs.file-max = 16777216
vm.swappiness = 10
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
# ===== End HIA =====
EOF

  sysctl -p >/dev/null 2>&1 || true
  
  echo -e "${GREEN}清理完成！系统已强制回退并锁定至 HIA 全局高并发基线。${RESET}"
  sleep 2
}

show_menu() {
  clear || true
  cat <<'EOF_MENU'
=====================================================
 Live Relay 调优工具
=====================================================
 1) 稳定高容量模式
 2) 极限低延迟模式
 3) 查看当前状态
 4) 清理配置回退HIA
 0) 退出
=====================================================
EOF_MENU
}

main() {
  need_root
  ensure_cmd modprobe || true

  local choice="${1:-}"
  case "$choice" in
    1|stable)
      apply_profile 1
      return 0
      ;;
    2|hyper)
      apply_profile 2
      return 0
      ;;
    3|status)
      show_status
      return 0
      ;;
    4|cleanup|remove)
      cleanup_live_relay
      return 0
      ;;
    "")
      ;;
    *)
      warn "未知参数：$choice"
      ;;
  esac

  while true; do
    show_menu
    read -r -p "请选择 [0-4]：" choice
    case "$choice" in
      1)
        apply_profile 1
        break
        ;;
      2)
        apply_profile 2
        break
        ;;
      3)
        show_status
        read -r -p "按回车键继续..." _tmp
        ;;
      4)
        cleanup_live_relay
        break
        ;;
      0)
        exit 0
        ;;
      *)
        warn "无效选项。"
        sleep 1
        ;;
    esac
  done
}

main "$@"
