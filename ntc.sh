#!/usr/bin/env bash
set -euo pipefail

VERSION="4.0.0-autonomous-relay"
WORKDIR="/opt/live-relay-tuner"
NIC_ENV_FILE="/etc/live-relay-nic.env"
NIC_HELPER="/usr/local/sbin/live-relay-nic-apply.sh"
NIC_SERVICE="/etc/systemd/system/live-relay-nic-tuning.service"
AUTO_ENV_FILE="/etc/live-relay-auto.env"
AUTO_HELPER="/usr/local/sbin/live-relay-auto-controller.sh"
AUTO_SERVICE="/etc/systemd/system/live-relay-auto-controller.service"
LIMITS_FILE="/etc/security/limits.d/99-live-relay.conf"
SYSTEMD_LIMIT_DIR="/etc/systemd/system.conf.d"
SYSTEMD_LIMIT_FILE="$SYSTEMD_LIMIT_DIR/99-live-relay.conf"
SYSCTL_DIR="/etc/sysctl.d"
SYSCTL_FILE="$SYSCTL_DIR/99-live-relay.conf"
SYSCTL_HELPER="/usr/local/sbin/live-relay-sysctl-apply.sh"
SYSCTL_SERVICE="/etc/systemd/system/live-relay-sysctl.service"
HIA_SYSCTL_FILE="$SYSCTL_DIR/99-hia-baseline.conf"
HIA_HELPER="/usr/local/sbin/hia-baseline-apply.sh"
HIA_SERVICE="/etc/systemd/system/hia-baseline.service"
STATE_FILE="$WORKDIR/state.env"
AUTO_STATE_FILE="$WORKDIR/auto-state.env"
STABLE_STATE_FILE="$WORKDIR/stable-state.env"
SYSCTL_STATE_FILE="$WORKDIR/sysctl-state.env"
PAUSE_FILE="$WORKDIR/paused"
SNAPSHOT_DIR="$WORKDIR/original"
METRICS_LOG="$WORKDIR/metrics.log"
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

ensure_base_dirs() {
  mkdir -p "$WORKDIR" "$SNAPSHOT_DIR" "$SYSCTL_DIR"
}

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
      LC_ALL=C LANG=C DEBIAN_FRONTEND=noninteractive apt-get update -y && \
      LC_ALL=C LANG=C DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
      ;;
    dnf)
      LC_ALL=C LANG=C dnf install -y "$@"
      ;;
    yum)
      LC_ALL=C LANG=C yum install -y "$@"
      ;;
    zypper)
      LC_ALL=C LANG=C zypper --non-interactive install "$@"
      ;;
    pacman)
      LC_ALL=C LANG=C pacman -Sy --noconfirm "$@"
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
    lscpu) pkg_apt="util-linux"; pkg_rpm="util-linux"; pkg_pac="util-linux"; pkg_zypper="util-linux" ;;
    ip|tc) pkg_apt="iproute2"; pkg_rpm="iproute"; pkg_pac="iproute2"; pkg_zypper="iproute2" ;;
    modprobe) pkg_apt="kmod"; pkg_rpm="kmod"; pkg_pac="kmod"; pkg_zypper="kmod" ;;
    awk|sed|grep|find|sort|cat|tr|cut|head|tail|getconf) return 0 ;;
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
    *) err "未找到受支持的包管理器，请手动安装 ${cmd}。"; return 1 ;;
  esac
  command -v "$cmd" >/dev/null 2>&1
}

sysctl_proc_path() {
  echo "/proc/sys/${1//.//}"
}

append_if_supported() {
  local key="$1" value="$2" path
  path=$(sysctl_proc_path "$key")
  if [ -e "$path" ] && [ -w "$path" ]; then
    printf '%s = %s\n' "$key" "$value" >> "$SYSCTL_FILE"
  fi
}

mem_total_kb() {
  local value
  value=$(awk '/MemTotal:/ {print $2; exit}' /proc/meminfo 2>/dev/null || true)
  case "$value" in ''|*[!0-9]*) value=1048576 ;; esac
  echo "$value"
}

mem_total_gb() {
  local value
  value=$(awk '/MemTotal:/ {printf "%d\n", int(($2 + 1048575) / 1048576); exit}' /proc/meminfo 2>/dev/null || true)
  case "$value" in ''|*[!0-9]*) value=1 ;; esac
  echo "$value"
}

online_cpu_count() {
  local n
  n=$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 1)
  case "$n" in ''|*[!0-9]*) n=1 ;; esac
  [ "$n" -lt 1 ] && n=1
  echo "$n"
}

physical_core_count() {
  ensure_cmd lscpu >/dev/null 2>&1 || true
  if command -v lscpu >/dev/null 2>&1 && lscpu -p=CORE,SOCKET,ONLINE >/dev/null 2>&1; then
    lscpu -p=CORE,SOCKET,ONLINE | awk -F, '!/^#/ && ($3 == "Y" || $3 == "1") { seen[$1 ":" $2] = 1 } END { print length(seen) + 0 }'
    return 0
  fi
  echo 0
}

numa_node_count() {
  local count
  count=$(find /sys/devices/system/node -maxdepth 1 -type d -name 'node[0-9]*' 2>/dev/null | awk 'END {print NR + 0}')
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  [ "$count" -gt 0 ] || count=1
  echo "$count"
}

nic_driver_name() {
  local nic="$1"
  ethtool -i "$nic" 2>/dev/null | awk -F': ' '/driver:/ {print $2; exit}'
}

nic_speed_mbps() {
  local nic="$1"
  ethtool "$nic" 2>/dev/null | awk -F': ' '/Speed:/ {
    gsub(/Mb\/s/, "", $2)
    if ($2 ~ /^[0-9]+$/) print $2
    exit
  }'
}

nic_rx_queue_count() {
  local nic="$1" count
  count=$(find "/sys/class/net/$nic/queues" -maxdepth 1 -type d -name 'rx-*' 2>/dev/null | awk 'END {print NR + 0}')
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  [ "$count" -gt 0 ] || count=1
  echo "$count"
}

collect_nic_irqs() {
  local nic="$1" path device_tag=""
  if [ -e "/sys/class/net/$nic/device" ]; then
    device_tag=$(basename "$(readlink -f "/sys/class/net/$nic/device" 2>/dev/null || true)")
  fi
  for path in /sys/class/net/"$nic"/device/msi_irqs/*; do
    [ -e "$path" ] && basename "$path"
  done
  awk -v dev="$nic" -v tag="$device_tag" '
    $0 ~ dev || (tag != "" && $0 ~ tag) {gsub(":", "", $1); print $1}
  ' /proc/interrupts 2>/dev/null
}

calc_socket_buffer_max() {
  local mem_gb
  mem_gb=$(mem_total_gb)
  if [ "$mem_gb" -ge 128 ]; then
    echo 268435456
  elif [ "$mem_gb" -ge 8 ]; then
    echo 134217728
  elif [ "$mem_gb" -ge 2 ]; then
    echo 67108864
  else
    echo 33554432
  fi
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

begin_sysctl_file() {
  local title="$1"
  cat > "$SYSCTL_FILE" <<EOF_HEADER
# =====================================================
# Live Relay Tuner $VERSION
# $title
# 自动生成，请勿手工编辑
# =====================================================
EOF_HEADER
}

calc_conntrack_buckets() {
  local mem_kb buckets page_size word_bits word_bytes buckets_per_page
  mem_kb=$(mem_total_kb)
  buckets=$(( mem_kb / 16 ))
  [ "$buckets" -lt 1024 ] && buckets=1024
  [ "$buckets" -gt 262144 ] && buckets=262144
  page_size=$(getconf PAGE_SIZE 2>/dev/null || echo 4096)
  word_bits=$(getconf LONG_BIT 2>/dev/null || echo 64)
  case "$page_size" in ''|*[!0-9]*) page_size=4096 ;; esac
  case "$word_bits" in ''|*[!0-9]*) word_bits=64 ;; esac
  word_bytes=$(( word_bits / 8 ))
  [ "$word_bytes" -gt 0 ] || word_bytes=8
  buckets_per_page=$(( page_size / word_bytes ))
  [ "$buckets_per_page" -gt 0 ] || buckets_per_page=512
  buckets=$(( ((buckets + buckets_per_page - 1) / buckets_per_page) * buckets_per_page ))
  [ "$buckets" -gt 262144 ] && buckets=262144
  echo "$buckets"
}

calc_conntrack_max() {
  local buckets mem_gb multiplier mode="${1:-auto}"
  buckets=$(calc_conntrack_buckets)
  mem_gb=$(mem_total_gb)

  if [ -n "${CONNTRACK_MULTIPLIER:-}" ]; then
    multiplier="${CONNTRACK_MULTIPLIER}"
  else
    case "$mode" in
      stable)
        if [ "$mem_gb" -ge 64 ]; then multiplier=3; else multiplier=2; fi
        ;;
      hyper|auto|*)
        if [ "$mem_gb" -ge 256 ]; then multiplier=4
        elif [ "$mem_gb" -ge 64 ]; then multiplier=3
        else multiplier=2
        fi
        ;;
    esac
  fi

  case "$multiplier" in ''|*[!0-9]*) multiplier=2 ;; esac
  [ "$multiplier" -lt 1 ] && multiplier=1
  echo $(( buckets * multiplier ))
}

calc_file_max() {
  local mem_gb
  mem_gb=$(mem_total_gb)
  if [ "$mem_gb" -ge 256 ]; then
    echo 8388608
  elif [ "$mem_gb" -ge 64 ]; then
    echo 4194304
  else
    echo 2097152
  fi
}

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

calc_flow_limit_enabled() {
  case "${ENABLE_FLOW_LIMIT:-auto}" in
    0|off|no|false) echo 0 ;;
    *) echo 1 ;;
  esac
}

calc_netdev_backlog() {
  local speed="$1" cpus="$2" base cap
  case "$speed" in
    ''|*[!0-9]*) base=32768 ;;
    *)
      if [ "$speed" -ge 100000 ]; then
        base=65536
      elif [ "$speed" -ge 50000 ]; then
        base=49152
      elif [ "$speed" -ge 25000 ]; then
        base=49152
      elif [ "$speed" -ge 10000 ]; then
        base=32768
      elif [ "$speed" -ge 5000 ]; then
        base=32768
      elif [ "$speed" -ge 1000 ]; then
        base=16384
      else
        base=8192
      fi
      ;;
  esac

  case "$cpus" in ''|*[!0-9]*) cpus=1 ;; esac
  if [ "$cpus" -ge 64 ]; then
    base=$(( base + (base / 2) )); cap=131072
  elif [ "$cpus" -ge 32 ]; then
    base=$(( base + (base / 4) )); cap=98304
  elif [ "$cpus" -ge 8 ]; then
    base=$(( base + (base / 8) )); cap=65536
  elif [ "$cpus" -ge 4 ]; then
    cap=49152
  else
    cap=32768
  fi

  [ "$base" -gt "$cap" ] && base="$cap"
  [ "$base" -lt 8192 ] && base=8192
  echo "$base"
}

calc_netdev_budget() {
  local speed="$1" cpus="$2" base
  case "$speed" in
    ''|*[!0-9]*) base=800 ;;
    *)
      if [ "$speed" -ge 100000 ]; then
        base=1200
      elif [ "$speed" -ge 50000 ]; then
        base=1100
      elif [ "$speed" -ge 25000 ]; then
        base=1000
      elif [ "$speed" -ge 10000 ]; then
        base=900
      elif [ "$speed" -ge 5000 ]; then
        base=800
      elif [ "$speed" -ge 1000 ]; then
        base=700
      else
        base=500
      fi
      ;;
  esac

  case "$cpus" in ''|*[!0-9]*) cpus=1 ;; esac
  if [ "$cpus" -ge 64 ]; then
    base=$(( base + 400 ))
  elif [ "$cpus" -ge 32 ]; then
    base=$(( base + 250 ))
  elif [ "$cpus" -ge 16 ]; then
    base=$(( base + 100 ))
  elif [ "$cpus" -le 2 ] && [ "$base" -gt 800 ]; then
    base=800
  fi
  [ "$base" -gt 1800 ] && base=1800
  echo "$base"
}

calc_netdev_budget_usecs() {
  local speed="$1" cpus="$2" base
  case "$speed" in
    ''|*[!0-9]*) base=4000 ;;
    *)
      if [ "$speed" -ge 100000 ]; then
        base=5000
      elif [ "$speed" -ge 50000 ]; then
        base=4500
      elif [ "$speed" -ge 25000 ]; then
        base=4000
      elif [ "$speed" -ge 10000 ]; then
        base=3500
      elif [ "$speed" -ge 5000 ]; then
        base=3000
      elif [ "$speed" -ge 1000 ]; then
        base=2500
      else
        base=2000
      fi
      ;;
  esac

  case "$cpus" in ''|*[!0-9]*) cpus=1 ;; esac
  if [ "$cpus" -ge 64 ]; then
    base=$(( base + 1500 ))
  elif [ "$cpus" -ge 32 ]; then
    base=$(( base + 750 ))
  elif [ "$cpus" -le 2 ] && [ "$base" -gt 4000 ]; then
    base=4000
  fi
  [ "$base" -gt 8000 ] && base=8000

  echo "$base"
}

calc_somaxconn() {
  local mem_gb cpus
  mem_gb=$(mem_total_gb)
  cpus=$(online_cpu_count)
  case "$cpus" in ''|*[!0-9]*) cpus=1 ;; esac
  if [ "$mem_gb" -ge 128 ] || [ "$cpus" -ge 32 ]; then
    echo 262144
  elif [ "$mem_gb" -ge 64 ] || [ "$cpus" -ge 16 ]; then
    echo 131072
  else
    echo 65535
  fi
}

calc_flow_limit_table_len() {
  local cpus
  cpus=$(online_cpu_count)
  case "$cpus" in ''|*[!0-9]*) cpus=1 ;; esac
  if [ "$cpus" -ge 32 ]; then
    echo 32768
  elif [ "$cpus" -ge 16 ]; then
    echo 16384
  else
    echo 8192
  fi
}

detect_primary_speed() {
  local nic speed
  nic="${NIC:-}"
  if [ -z "$nic" ]; then
    nic=$(ip -o route show to default 2>/dev/null | awk '{print $5; exit}' || true)
  fi
  if [ -n "$nic" ] && command -v ethtool >/dev/null 2>&1; then
    speed=$(ethtool "$nic" 2>/dev/null | awk -F': ' '/Speed:/ {gsub(/Mb\/s/,"",$2); if($2 ~ /^[0-9]+$/) print $2; exit}')
    if [ -n "$speed" ]; then
      echo "$speed"
      return 0
    fi
  fi
  echo ""
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

  if [ "${ENABLE_BUSY_POLL:-0}" = "1" ]; then
    append_if_supported net.core.busy_read 50
    append_if_supported net.core.busy_poll 50
  else
    append_if_supported net.core.busy_read 0
    append_if_supported net.core.busy_poll 0
  fi

  append_if_supported vm.swappiness 1
  append_if_supported vm.overcommit_memory 1
}

append_stable_sysctls() {
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
  append_if_supported net.ipv4.udp_rmem_min 131072

  append_if_supported vm.dirty_background_bytes 67108864
  append_if_supported vm.dirty_bytes 268435456
}

append_hyper_sysctls() {
  local speed cpus somax backlog budget budget_usecs filemax flow_table_len udp_mem mem_gb socket_max
  speed=$(detect_primary_speed)
  cpus=$(online_cpu_count)
  somax=$(calc_somaxconn)
  backlog=$(calc_netdev_backlog "$speed" "$cpus")
  budget=$(calc_netdev_budget "$speed" "$cpus")
  budget_usecs=$(calc_netdev_budget_usecs "$speed" "$cpus")
  filemax=$(calc_file_max)
  flow_table_len=$(calc_flow_limit_table_len)
  udp_mem=$(calc_udp_mem_pages)
  mem_gb=$(mem_total_gb)
  socket_max=$(calc_socket_buffer_max)

  append_if_supported net.core.somaxconn "$somax"
  append_if_supported net.ipv4.tcp_max_syn_backlog "$somax"
  append_if_supported net.core.netdev_max_backlog "$backlog"
  append_if_supported net.core.netdev_budget "$budget"
  append_if_supported net.core.netdev_budget_usecs "$budget_usecs"
  append_if_supported net.core.dev_weight 128
  append_if_supported net.core.dev_weight_rx_bias 1
  append_if_supported net.core.dev_weight_tx_bias 1
  append_if_supported net.core.flow_limit_table_len "$flow_table_len"

  append_if_supported fs.file-max "$filemax"

  append_if_supported net.core.rmem_max "$socket_max"
  append_if_supported net.core.wmem_max "$socket_max"
  append_if_supported net.core.rmem_default 262144
  append_if_supported net.core.wmem_default 262144
  append_if_supported net.core.optmem_max 262144

  append_if_supported net.ipv4.tcp_rmem "4096 262144 $socket_max"
  append_if_supported net.ipv4.tcp_wmem "4096 131072 $socket_max"
  append_if_supported net.ipv4.udp_mem "$udp_mem"
  append_if_supported net.ipv4.udp_rmem_min 262144

  append_if_supported net.ipv4.tcp_limit_output_bytes 524288
  append_if_supported net.ipv4.tcp_notsent_lowat 65536

  if [ "$mem_gb" -ge 128 ]; then
    append_if_supported vm.dirty_background_bytes 268435456
    append_if_supported vm.dirty_bytes 1073741824
  else
    append_if_supported vm.dirty_background_bytes 134217728
    append_if_supported vm.dirty_bytes 536870912
  fi

}

append_conntrack_sysctls() {
  local mode="${1:-auto}" buckets ct_max est
  case "${ENABLE_CONNTRACK_TUNING:-auto}" in
    0|off|no|false) return 0 ;;
    1|on|yes|true) modprobe nf_conntrack >/dev/null 2>&1 || true ;;
    auto|'') : ;;
  esac
  if [ ! -e /proc/sys/net/netfilter/nf_conntrack_max ]; then
    log "未使用 conntrack，跳过连接跟踪调优。"
    return 0
  fi

  buckets=$(calc_conntrack_buckets)
  ct_max=$(calc_conntrack_max "$mode")

  append_if_supported net.netfilter.nf_conntrack_buckets "$buckets"
  append_if_supported net.netfilter.nf_conntrack_max "$ct_max"

  if [ "$mode" = "stable" ]; then
    est=7200
  else
    est=1800
  fi

  append_if_supported net.netfilter.nf_conntrack_tcp_timeout_established "$est"
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
  begin_sysctl_file "稳定高容量模式"
  append_common_sysctls "$cc"
  append_stable_sysctls
  append_conntrack_sysctls stable
}

write_profile_2() {
  local cc="$1"
  begin_sysctl_file "VPS / 云服务器极限低延迟模式"
  append_common_sysctls "$cc"
  append_hyper_sysctls
  append_conntrack_sysctls hyper
}

apply_sysctl_file() {
  : > "$SYSCTL_LOG"
  local line key value expected actual path
  local applied=0 normalized=0 skipped=0 failed=0 stack_failed=0
  if ! sysctl --system >>"$SYSCTL_LOG" 2>&1; then
    stack_failed=1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    key="${line%%=*}"
    value="${line#*=}"
    key=$(printf '%s' "$key" | tr -d '[:space:]')
    value=$(printf '%s' "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    path=$(sysctl_proc_path "$key")
    if [ ! -e "$path" ] || [ ! -w "$path" ]; then
      printf 'SKIPPED %s reason=unsupported-or-read-only\n' "$key" >> "$SYSCTL_LOG"
      skipped=$(( skipped + 1 ))
      continue
    fi
    if ! sysctl -w "$key=$value" >>"$SYSCTL_LOG" 2>&1; then
      printf 'FAILED %s requested=%s reason=write-error\n' "$key" "$value" >> "$SYSCTL_LOG"
      failed=$(( failed + 1 ))
      continue
    fi
    expected=$(printf '%s\n' "$value" | awk '{$1=$1; print}')
    actual=$(sysctl -n "$key" 2>/dev/null | awk '{$1=$1; print}' || true)
    if [ "$actual" = "$expected" ]; then
      applied=$(( applied + 1 ))
    elif [ "$key" = "net.netfilter.nf_conntrack_buckets" ] && \
         [[ "$expected" =~ ^[0-9]+$ ]] && [[ "$actual" =~ ^[0-9]+$ ]] && [ "$actual" -gt 0 ]; then
      printf 'NORMALIZED %s requested=%s actual=%s reason=kernel-hash-alignment\n' "$key" "$expected" "$actual" >> "$SYSCTL_LOG"
      normalized=$(( normalized + 1 ))
    else
      printf 'FAILED %s requested=%s actual=%s reason=verify-mismatch\n' "$key" "$expected" "${actual:-unknown}" >> "$SYSCTL_LOG"
      failed=$(( failed + 1 ))
    fi
  done < "$SYSCTL_FILE"

  if [ "$stack_failed" -ne 0 ]; then
    printf 'SYSTEM_STACK status=nonzero scope=external-and-system-files\n' >> "$SYSCTL_LOG"
  fi
  local state_tmp="$SYSCTL_STATE_FILE.tmp.$$"
  {
    printf 'SYSCTL_APPLIED=%q\n' "$applied"
    printf 'SYSCTL_NORMALIZED=%q\n' "$normalized"
    printf 'SYSCTL_SKIPPED=%q\n' "$skipped"
    printf 'SYSCTL_FAILED=%q\n' "$failed"
    printf 'SYSCTL_EXTERNAL_NONZERO=%q\n' "$stack_failed"
    printf 'SYSCTL_UPDATED_AT=%q\n' "$(date +%F_%T)"
  } > "$state_tmp"
  mv -f "$state_tmp" "$SYSCTL_STATE_FILE"
  if [ "$failed" -eq 0 ]; then
    log "sysctl：应用 ${applied}，规范化 ${normalized}，跳过 ${skipped}，失败 0。"
    [ "$normalized" -eq 0 ] || log "内核自动调整了 ${normalized} 个参数，属于正常行为。"
    [ "$stack_failed" -eq 0 ] || log "系统配置栈存在外部非零项；Live Relay 参数已独立重放并校验。"
    return 0
  fi
  err "sysctl：应用 ${applied}，规范化 ${normalized}，跳过 ${skipped}，失败 ${failed}；详情：$SYSCTL_LOG"
  return 1
}

build_sysctl_persistence() {
  cat > "$SYSCTL_HELPER" <<EOF_SYSCTL_HELPER
#!/usr/bin/env bash
set -u

SYSCTL_FILE="$SYSCTL_FILE"
[ -r "\$SYSCTL_FILE" ] || exit 0

failed=0
while IFS= read -r line || [ -n "\$line" ]; do
  case "\$line" in
    ''|'#'*) continue ;;
  esac
  key="\${line%%=*}"
  value="\${line#*=}"
  key="\$(printf '%s' "\$key" | tr -d '[:space:]')"
  value="\$(printf '%s' "\$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*\$//')"
  path="/proc/sys/\${key//.//}"
  [ -e "\$path" ] && [ -w "\$path" ] || continue
  sysctl -q -w "\$key=\$value" >/dev/null 2>&1 || failed=1
done < "\$SYSCTL_FILE"
exit "\$failed"
EOF_SYSCTL_HELPER
  chmod +x "$SYSCTL_HELPER"

  cat > "$SYSCTL_SERVICE" <<EOF_SYSCTL_SERVICE
[Unit]
Description=Reapply Live Relay sysctl profile after system defaults
After=systemd-sysctl.service procps.service local-fs.target
Before=network-pre.target

[Service]
Type=oneshot
ExecStart=$SYSCTL_HELPER
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_SYSCTL_SERVICE
}

enable_sysctl_persistence() {
  build_sysctl_persistence
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload
    systemctl enable live-relay-sysctl.service >/dev/null 2>&1 || true
  fi
}

remove_sysctl_persistence() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now live-relay-sysctl.service >/dev/null 2>&1 || true
  fi
  rm -f "$SYSCTL_SERVICE" "$SYSCTL_HELPER"
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
TUNER_STATE_DIR="${TUNER_STATE_DIR:-/opt/live-relay-tuner}"
FLOW_LIMIT_BEFORE="$TUNER_STATE_DIR/flow-limit.before"
FLOW_LIMIT_OWNED="$TUNER_STATE_DIR/flow-limit.owned"
mkdir -p "$TUNER_STATE_DIR"

for cmd in ethtool ip tc awk find sort; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "未找到 $cmd"; exit 1; }
done

_expand_cpulist() {
  local spec="$1" part start end cpu
  local -a parts
  IFS=',' read -ra parts <<< "$spec"
  for part in "${parts[@]}"; do
    part="${part//[[:space:]]/}"
    [ -n "$part" ] || continue
    if [[ "$part" == *-* ]]; then
      start="${part%%-*}"
      end="${part##*-}"
    else
      start="$part"
      end="$part"
    fi
    case "$start" in ''|*[!0-9]*) continue ;; esac
    case "$end" in ''|*[!0-9]*) continue ;; esac
    [ "$start" -le "$end" ] || continue
    for ((cpu = start; cpu <= end; cpu++)); do
      printf '%s\n' "$cpu"
    done
  done
}

_cpulist_to_mask() {
  local spec="$1" part start end cpu word bit current i max_word=-1
  local -a parts words
  IFS=',' read -ra parts <<< "$spec"
  for part in "${parts[@]}"; do
    part="${part//[[:space:]]/}"
    [ -n "$part" ] || continue
    if [[ "$part" == *-* ]]; then
      start="${part%%-*}"
      end="${part##*-}"
    else
      start="$part"
      end="$part"
    fi
    case "$start" in ''|*[!0-9]*) continue ;; esac
    case "$end" in ''|*[!0-9]*) continue ;; esac
    [ "$start" -le "$end" ] || continue
    for ((cpu = start; cpu <= end; cpu++)); do
      word=$(( cpu / 32 ))
      bit=$(( cpu % 32 ))
      current="${words[$word]:-0}"
      words[$word]=$(( current | (1 << bit) ))
      [ "$word" -gt "$max_word" ] && max_word="$word"
    done
  done

  [ "$max_word" -ge 0 ] || { printf '0\n'; return 0; }
  for ((i = max_word; i >= 0; i--)); do
    printf '%08x' "${words[$i]:-0}"
    [ "$i" -gt 0 ] && printf ','
  done
  printf '\n'
}

_get_driver() {
  ethtool -i "$DEV" 2>/dev/null | awk -F': ' '/driver:/ {print $2; exit}'
}

_get_link_speed() {
  ethtool "$DEV" 2>/dev/null | awk -F': ' '/Speed:/ {
    gsub(/Mb\/s/, "", $2)
    if ($2 ~ /^[0-9]+$/) print $2
    exit
  }'
}

_get_nic_numa_node() {
  if [ -r "/sys/class/net/$DEV/device/numa_node" ]; then
    cat "/sys/class/net/$DEV/device/numa_node"
  else
    echo -1
  fi
}

_get_nic_local_cpulist() {
  if [ -r "/sys/class/net/$DEV/device/local_cpulist" ]; then
    cat "/sys/class/net/$DEV/device/local_cpulist"
  else
    echo ""
  fi
}

_get_nic_irq_cpu_hint() {
  local path irq affinity first_cpu device_tag=""
  if [ -e "/sys/class/net/$DEV/device" ]; then
    device_tag=$(basename "$(readlink -f "/sys/class/net/$DEV/device" 2>/dev/null || true)")
  fi
  while read -r irq; do
    case "$irq" in ''|*[!0-9]*) continue ;; esac
    affinity=$(cat "/proc/irq/$irq/effective_affinity_list" 2>/dev/null || cat "/proc/irq/$irq/smp_affinity_list" 2>/dev/null || true)
    [ -n "$affinity" ] || continue
    first_cpu=""
    read -r first_cpu < <(_expand_cpulist "$affinity") || true
    [ -n "$first_cpu" ] || continue
    printf '%s\n' "$first_cpu"
    return 0
  done < <(
    for path in /sys/class/net/"$DEV"/device/msi_irqs/*; do
      [ -e "$path" ] && basename "$path"
    done
    awk -v dev="$DEV" -v tag="$device_tag" '
      $0 ~ dev || (tag != "" && $0 ~ tag) {gsub(":", "", $1); print $1}
    ' /proc/interrupts 2>/dev/null
  )
  return 1
}

_resolve_nic_numa_node() {
  local node hint local_cpus
  node=$(_get_nic_numa_node)
  case "$node" in
    ''|*[!0-9-]*) node=-1 ;;
  esac
  if [ "$node" -ge 0 ]; then
    echo "$node"
    return 0
  fi

  if command -v lscpu >/dev/null 2>&1; then
    hint=$(_get_nic_irq_cpu_hint || true)
    case "$hint" in
      ''|*[!0-9]*) : ;;
      *)
        node=$(lscpu -p=CPU,NODE,ONLINE 2>/dev/null | awk -F, -v cpu="$hint" '
          !/^#/ && $1 == cpu && ($3 == "Y" || $3 == "1") && $2 ~ /^[0-9]+$/ {print $2; exit}
        ')
        if [ -n "$node" ]; then echo "$node"; return 0; fi
        ;;
    esac

    local_cpus=$(_get_nic_local_cpulist)
    node=$(lscpu -p=CPU,NODE,ONLINE 2>/dev/null | awk -F, -v spec="$local_cpus" '
      function cpu_in_list(cpu, value,    n, i, part, bounds) {
        if (value == "") return 0
        n=split(value, part, ",")
        for (i=1; i<=n; i++) {
          if (part[i] ~ /-/) {
            split(part[i], bounds, "-")
            if (cpu >= bounds[1] && cpu <= bounds[2]) return 1
          } else if (cpu == part[i]) return 1
        }
        return 0
      }
      !/^#/ && ($3 == "Y" || $3 == "1") && $2 ~ /^[0-9]+$/ && (spec == "" || cpu_in_list($1, spec)) {print $2; exit}
    ')
    if [ -n "$node" ]; then echo "$node"; return 0; fi
  fi
  echo -1
}

_get_max_combined() {
  ethtool -l "$DEV" 2>/dev/null | awk '
    /Pre-set maximums:/ {sec=1; next}
    /Current hardware settings:/ {sec=0}
    sec && /Combined:/ {print $2; exit}
  '
}

_get_current_combined() {
  ethtool -l "$DEV" 2>/dev/null | awk '
    /Current hardware settings:/ {sec=1; next}
    sec && /Combined:/ {print $2; exit}
  '
}

_get_current_rings() {
  ethtool -g "$DEV" 2>/dev/null | awk '
    /Current hardware settings:/ {sec=1; next}
    sec && $1 == "RX:" {rx=$2}
    sec && $1 == "TX:" {tx=$2}
    END {
      if (rx == "") rx="unknown"
      if (tx == "") tx="unknown"
      printf "%s/%s\n", rx, tx
    }
  '
}

_get_topology_lists() {
  local nic_node local_cpus use_ht
  nic_node=$(_resolve_nic_numa_node)
  local_cpus=$(_get_nic_local_cpulist)
  use_ht="${USE_HT:-0}"

  if command -v lscpu >/dev/null 2>&1 && lscpu -p=CPU,CORE,SOCKET,NODE,ONLINE >/dev/null 2>&1; then
    lscpu -p=CPU,CORE,SOCKET,NODE,ONLINE | awk -F, -v want_node="$nic_node" -v local_cpus="$local_cpus" -v use_ht="$use_ht" '
      function cpu_in_list(cpu, spec,    n, i, range, bounds) {
        if (spec == "") return 1
        n = split(spec, range, ",")
        for (i = 1; i <= n; i++) {
          if (range[i] ~ /-/) {
            split(range[i], bounds, "-")
            if (cpu >= bounds[1] && cpu <= bounds[2]) return 1
          } else if (cpu == range[i]) {
            return 1
          }
        }
        return 0
      }
      !/^#/ && ($5 == "Y" || $5 == "1") {
        cpu = $1 + 0
        core = $2
        socket = $3
        node = $4
        key = socket ":" core
        if (want_node >= 0) {
          is_local = (node == want_node) ? 1 : 0
          if (is_local && local_cpus != "") is_local = cpu_in_list(cpu, local_cpus)
        }
        else if (local_cpus != "") is_local = cpu_in_list(cpu, local_cpus)
        else if (node !~ /^[0-9]+$/) is_local = 1
        else {
          if (fallback_node == "") fallback_node = node
          is_local = (node == fallback_node) ? 1 : 0
        }

        if (!(key in first_cpu)) {
          first_cpu[key] = cpu
          if (is_local) local_primary[++lp] = cpu
          else remote_primary[++rp] = cpu
        } else if (use_ht != "0") {
          if (is_local) local_sibling[++ls] = cpu
          else remote_sibling[++rs] = cpu
        }
      }
      END {
        for (i = 1; i <= lp; i++) print "LOCAL_PRIMARY " local_primary[i]
        for (i = 1; i <= ls; i++) print "LOCAL_SIBLING " local_sibling[i]
        for (i = 1; i <= rp; i++) print "REMOTE_PRIMARY " remote_primary[i]
        for (i = 1; i <= rs; i++) print "REMOTE_SIBLING " remote_sibling[i]
      }
    '
    return 0
  fi

  local fallback_cpus
  fallback_cpus="$local_cpus"
  [ -n "$fallback_cpus" ] || fallback_cpus="$(cat /sys/devices/system/cpu/online)"
  _expand_cpulist "$fallback_cpus" | awk '{print "LOCAL_PRIMARY " $1}'
}

_load_topology() {
  mapfile -t TOPOLOGY_LINES < <(_get_topology_lists)
  LOCAL_PRIMARY=()
  LOCAL_SIBLING=()
  REMOTE_PRIMARY=()
  REMOTE_SIBLING=()

  local line kind cpu
  for line in "${TOPOLOGY_LINES[@]}"; do
    kind="${line%% *}"
    cpu="${line#* }"
    case "$kind" in
      LOCAL_PRIMARY) LOCAL_PRIMARY+=("$cpu") ;;
      LOCAL_SIBLING) LOCAL_SIBLING+=("$cpu") ;;
      REMOTE_PRIMARY) REMOTE_PRIMARY+=("$cpu") ;;
      REMOTE_SIBLING) REMOTE_SIBLING+=("$cpu") ;;
    esac
  done
}

_build_worker_cpu_list() {
  _load_topology
  WORKER_CPUS=()
  WORKER_PRIMARY_CPUS=()

  local target use_ht cpu
  target="${WORKER_CPUS_TARGET:-local}"
  use_ht="${USE_HT:-0}"

  if [ "${#LOCAL_PRIMARY[@]}" -eq 0 ] && [ "${#REMOTE_PRIMARY[@]}" -gt 0 ]; then
    LOCAL_PRIMARY=("${REMOTE_PRIMARY[@]}")
    REMOTE_PRIMARY=()
    LOCAL_SIBLING=("${REMOTE_SIBLING[@]}")
    REMOTE_SIBLING=()
  fi

  case "$target" in
    all|max|auto|'')
      for cpu in "${LOCAL_PRIMARY[@]}"; do WORKER_PRIMARY_CPUS+=("$cpu"); done
      for cpu in "${REMOTE_PRIMARY[@]}"; do WORKER_PRIMARY_CPUS+=("$cpu"); done
      ;;
    local)
      for cpu in "${LOCAL_PRIMARY[@]}"; do WORKER_PRIMARY_CPUS+=("$cpu"); done
      ;;
    *[!0-9]*)
      for cpu in "${LOCAL_PRIMARY[@]}"; do WORKER_PRIMARY_CPUS+=("$cpu"); done
      for cpu in "${REMOTE_PRIMARY[@]}"; do WORKER_PRIMARY_CPUS+=("$cpu"); done
      ;;
    *)
      for cpu in "${LOCAL_PRIMARY[@]}"; do
        [ "${#WORKER_PRIMARY_CPUS[@]}" -ge "$target" ] && break
        WORKER_PRIMARY_CPUS+=("$cpu")
      done
      if [ "${#WORKER_PRIMARY_CPUS[@]}" -lt "$target" ]; then
        for cpu in "${REMOTE_PRIMARY[@]}"; do
          [ "${#WORKER_PRIMARY_CPUS[@]}" -ge "$target" ] && break
          WORKER_PRIMARY_CPUS+=("$cpu")
        done
      fi
      ;;
  esac

  WORKER_CPUS=("${WORKER_PRIMARY_CPUS[@]}")
  if [ "$use_ht" != "0" ]; then
    case "$target" in
      all|max|auto|'')
        for cpu in "${LOCAL_SIBLING[@]}"; do WORKER_CPUS+=("$cpu"); done
        for cpu in "${REMOTE_SIBLING[@]}"; do WORKER_CPUS+=("$cpu"); done
        ;;
      local)
        for cpu in "${LOCAL_SIBLING[@]}"; do WORKER_CPUS+=("$cpu"); done
        ;;
      *[!0-9]*)
        for cpu in "${LOCAL_SIBLING[@]}"; do WORKER_CPUS+=("$cpu"); done
        for cpu in "${REMOTE_SIBLING[@]}"; do WORKER_CPUS+=("$cpu"); done
        ;;
      *)
        local sibling_limit="${target:-0}"
        for cpu in "${LOCAL_SIBLING[@]}"; do
          [ "${#WORKER_CPUS[@]}" -ge $(( target + sibling_limit )) ] && break
          WORKER_CPUS+=("$cpu")
        done
        if [ "${#WORKER_CPUS[@]}" -lt $(( target + sibling_limit )) ]; then
          for cpu in "${REMOTE_SIBLING[@]}"; do
            [ "${#WORKER_CPUS[@]}" -ge $(( target + sibling_limit )) ] && break
            WORKER_CPUS+=("$cpu")
          done
        fi
        ;;
    esac
  fi

  if [ "${#WORKER_CPUS[@]}" -eq 0 ]; then
    mapfile -t WORKER_CPUS < <(_expand_cpulist "$(cat /sys/devices/system/cpu/online)")
    WORKER_PRIMARY_CPUS=("${WORKER_CPUS[@]}")
  fi
}

_is_virtual_driver() {
  case "$1" in
    virtio_net|vmxnet3|ena|gve|hv_netvsc) return 0 ;;
    *) return 1 ;;
  esac
}

_calc_auto_queue_base() {
  local max_combined driver speed worker_primary target_q
  max_combined=$(_get_max_combined)
  driver=$(_get_driver)
  speed=$(_get_link_speed)
  worker_primary="${#WORKER_PRIMARY_CPUS[@]}"
  [ "$worker_primary" -gt 0 ] || worker_primary="${#WORKER_CPUS[@]}"

  if _is_virtual_driver "$driver"; then
    if [ "$worker_primary" -ge 8 ]; then
      target_q=$(( worker_primary / 2 ))
    else
      target_q="$worker_primary"
    fi
    [ "$target_q" -gt 32 ] && target_q=32
  else
    case "$speed" in
      ''|*[!0-9]*)
        target_q="$worker_primary"
        [ "$target_q" -gt 32 ] && target_q=32
        ;;
      *)
        if [ "$speed" -ge 100000 ]; then
          target_q=32
        elif [ "$speed" -ge 50000 ]; then
          target_q=24
        elif [ "$speed" -ge 25000 ]; then
          target_q=16
        elif [ "$speed" -ge 10000 ]; then
          target_q=12
        elif [ "$speed" -ge 2500 ]; then
          target_q=8
        elif [ "$speed" -ge 1000 ]; then
          target_q=4
        else
          target_q=2
        fi
        ;;
    esac
  fi

  [ "$worker_primary" -gt 0 ] && [ "$target_q" -gt "$worker_primary" ] && target_q="$worker_primary"

  if [ -n "$max_combined" ] && [ "$max_combined" != "n/a" ] && [ "$max_combined" -gt 0 ] && [ "$target_q" -gt "$max_combined" ]; then
    target_q="$max_combined"
  fi

  [ "$target_q" -lt 1 ] && target_q=1
  echo "$target_q"
}

_pick_target_queues() {
  local target auto max_combined workers
  auto=$(_calc_auto_queue_base)
  workers="${#WORKER_CPUS[@]}"
  target="${TARGET_QUEUES:-auto}"

  case "$target" in
    auto|'') target="$auto" ;;
    max)
      max_combined=$(_get_max_combined)
      if [ -n "$max_combined" ] && [ "$max_combined" != "n/a" ] && [ "$max_combined" -gt 0 ]; then
        target="$max_combined"
      else
        target="$auto"
      fi
      ;;
    all|full) target="$workers" ;;
    *[!0-9]*) target="$auto" ;;
    *) : ;;
  esac

  max_combined=$(_get_max_combined)
  if [ -n "$max_combined" ] && [ "$max_combined" != "n/a" ] && [ "$max_combined" -gt 0 ] && [ "$target" -gt "$max_combined" ]; then
    target="$max_combined"
  fi

  [ "$target" -lt 1 ] && target=1
  echo "$target"
}

_build_irq_cpu_list() {
  local target="$1" cpu
  IRQ_CPUS=()

  for cpu in "${WORKER_CPUS[@]}"; do
    [ "${#IRQ_CPUS[@]}" -ge "$target" ] && break
    IRQ_CPUS+=("$cpu")
  done

  if [ "${#IRQ_CPUS[@]}" -eq 0 ]; then
    IRQ_CPUS=("${WORKER_CPUS[@]}")
  fi
}

_apply_queue_count() {
  local target="$1" max_combined cur

  case "$target" in ''|*[!0-9]*|0) target=1 ;; esac

  if ethtool -l "$DEV" >/dev/null 2>&1; then
    max_combined=$(_get_max_combined)
    if [ -n "$max_combined" ] && [ "$max_combined" != "n/a" ] && [ "$max_combined" -gt 0 ] && [ "$target" -gt "$max_combined" ]; then
      target="$max_combined"
    fi
    ethtool -L "$DEV" combined "$target" >/dev/null 2>&1 || true
  fi

  if ethtool -x "$DEV" >/dev/null 2>&1; then
    ethtool -X "$DEV" equal "$target" >/dev/null 2>&1 || true
  fi

  cur=$(_get_current_combined || true)
  case "$cur" in
    ''|*[!0-9]*|0)
      cur=$(find "/sys/class/net/$DEV/queues" -maxdepth 1 -type d -name 'rx-*' 2>/dev/null | awk 'END {print NR + 0}')
      ;;
  esac
  case "$cur" in ''|*[!0-9]*|0) cur="$target" ;; esac
  echo "$cur"
}

_apply_max_rings() {
  local rxmax txmax cur target_rx target_tx mode
  mode="${RING_MODE:-balanced}"
  if [ "${MAX_RINGS:-0}" = "1" ]; then
    mode="throughput"
  fi
  [ "$mode" != "keep" ] || {
    _get_current_rings
    return 0
  }

  ethtool -g "$DEV" >/dev/null 2>&1 || {
    echo "unsupported"
    return 0
  }

  rxmax=$(ethtool -g "$DEV" 2>/dev/null | awk '
    /Pre-set maximums:/ {sec=1; next}
    /Current hardware settings:/ {sec=0}
    sec && $1 == "RX:" {print $2; exit}
  ')
  txmax=$(ethtool -g "$DEV" 2>/dev/null | awk '
    /Pre-set maximums:/ {sec=1; next}
    /Current hardware settings:/ {sec=0}
    sec && $1 == "TX:" {print $2; exit}
  ')

  if [ -n "$rxmax" ] && [ -n "$txmax" ] && [ "$rxmax" != "n/a" ] && [ "$txmax" != "n/a" ] && [ "$rxmax" -gt 0 ] && [ "$txmax" -gt 0 ]; then
    case "$mode" in
      latency) target_rx=512; target_tx=512 ;;
      throughput|max) target_rx="$rxmax"; target_tx="$txmax" ;;
      *) target_rx=1024; target_tx=1024 ;;
    esac
    [ "$target_rx" -gt "$rxmax" ] && target_rx="$rxmax"
    [ "$target_tx" -gt "$txmax" ] && target_tx="$txmax"
    ethtool -G "$DEV" rx "$target_rx" tx "$target_tx" >/dev/null 2>&1 || true
  fi

  cur=$(_get_current_rings || true)
  echo "${cur:-unknown}"
}

_apply_flow_control() {
  local mode rx tx
  mode="${FLOW_CONTROL_MODE:-keep}"

  ethtool -a "$DEV" >/dev/null 2>&1 || {
    echo "unsupported"
    return 0
  }

  case "$mode" in
    on) ethtool -A "$DEV" rx on tx on >/dev/null 2>&1 || true ;;
    off) ethtool -A "$DEV" rx off tx off >/dev/null 2>&1 || true ;;
    keep|auto|'') : ;;
    *) : ;;
  esac

  rx=$(ethtool -a "$DEV" 2>/dev/null | awk -F': ' '/RX:/ {print $2; exit}')
  tx=$(ethtool -a "$DEV" 2>/dev/null | awk -F': ' '/TX:/ {print $2; exit}')
  printf 'rx=%s tx=%s' "${rx:-unknown}" "${tx:-unknown}"
}

_apply_coalesce() {
  local speed driver rx tx actual_rx actual_tx
  speed=$(_get_link_speed)
  driver=$(_get_driver)

  ethtool -c "$DEV" >/dev/null 2>&1 || {
    echo "unsupported"
    return 0
  }

  if [ "${COALESCE_MODE:-balanced}" = "adaptive" ]; then
    ethtool -C "$DEV" adaptive-rx on adaptive-tx on >/dev/null 2>&1 || true
  else
    ethtool -C "$DEV" adaptive-rx off adaptive-tx off >/dev/null 2>&1 || true
  fi

  case "$driver" in
    virtio_net|vmxnet3|ena|gve|hv_netvsc)
      rx=6; tx=6
      ;;
    *)
      case "$speed" in
        ''|*[!0-9]*) rx=6; tx=6 ;;
        *)
          if [ "$speed" -ge 100000 ]; then
            rx=6; tx=6
          elif [ "$speed" -ge 40000 ]; then
            rx=5; tx=5
          elif [ "$speed" -ge 25000 ]; then
            rx=5; tx=5
          elif [ "$speed" -ge 10000 ]; then
            rx=4; tx=4
          elif [ "$speed" -ge 1000 ]; then
            rx=8; tx=8
          else
            rx=10; tx=10
          fi
          ;;
      esac
      ;;
  esac

  case "${COALESCE_MODE:-balanced}" in
    latency) rx=2; tx=2 ;;
    throughput) rx=12; tx=12 ;;
  esac
  ethtool -C "$DEV" rx-usecs "$rx" tx-usecs "$tx" >/dev/null 2>&1 || true
  actual_rx=$(ethtool -c "$DEV" 2>/dev/null | awk -F': ' '/rx-usecs:/ {print $2; exit}')
  actual_tx=$(ethtool -c "$DEV" 2>/dev/null | awk -F': ' '/tx-usecs:/ {print $2; exit}')
  echo "actual:${actual_rx:-unknown}/${actual_tx:-unknown}"
}

_force_fq_qdisc() {
  [ "${FORCE_FQ:-1}" = "1" ] || return 0
  modprobe sch_fq >/dev/null 2>&1 || true

  local txq_count
  txq_count=$(find "/sys/class/net/$DEV/queues" -maxdepth 1 -type d -name 'tx-*' 2>/dev/null | awk 'END {print NR + 0}')

  if [ "$txq_count" -gt 1 ]; then
    tc qdisc replace dev "$DEV" root handle 1: mq >/dev/null 2>&1 || {
      tc qdisc replace dev "$DEV" root fq >/dev/null 2>&1 || true
      return 0
    }
    local i
    for ((i = 1; i <= txq_count; i++)); do
      tc qdisc replace dev "$DEV" parent "1:$i" fq >/dev/null 2>&1 || true
    done
  else
    tc qdisc replace dev "$DEV" root fq >/dev/null 2>&1 || true
  fi
}

_apply_offloads() {
  [ "${TUNE_OFFLOADS:-1}" = "1" ] || return 0
  ethtool -K "$DEV" rx on tx on sg on gso on tso on gro on lro off >/dev/null 2>&1 || true
}

_calc_rfs_total_flows() {
  local rxqs workers mem_gb total cap
  rxqs="$1"
  workers="$2"
  mem_gb=$(awk '/MemTotal:/ {printf "%d\n", int(($2 + 1048575) / 1048576)}' /proc/meminfo)

  case "$workers" in ''|*[!0-9]*) workers=1 ;; esac
  total=$(( workers * 4096 ))
  [ "$total" -lt 32768 ] && total=32768
  if [ "$rxqs" -ge 16 ] && [ "$total" -lt 131072 ]; then
    total=131072
  fi

  if [ "$mem_gb" -lt 16 ]; then
    cap=65536
  elif [ "$mem_gb" -lt 64 ]; then
    cap=262144
  else
    cap=524288
  fi

  [ "$total" -gt "$cap" ] && total="$cap"
  echo "$total"
}

_build_group_for_queue() {
  local idx="$1" total="$2" out=() i
  for ((i = 0; i < ${#WORKER_CPUS[@]}; i++)); do
    if [ $(( i % total )) -eq "$idx" ]; then
      out+=("${WORKER_CPUS[$i]}")
    fi
  done

  if [ "${#out[@]}" -eq 0 ] && [ "${#WORKER_CPUS[@]}" -gt 0 ]; then
    out+=("${WORKER_CPUS[$(( idx % ${#WORKER_CPUS[@]} ))]}")
  fi

  printf '%s\n' "${out[@]}"
}

_bitmap_for_all_workers() {
  local csv
  csv=$(IFS=,; echo "${WORKER_CPUS[*]}")
  _cpulist_to_mask "$csv"
}

_sync_flow_limit() {
  local mode current mask before owned
  mode="${ENABLE_FLOW_LIMIT:-0}"
  if [ "$mode" = "1" ] || [ "$mode" = "on" ] || [ "$mode" = "yes" ]; then
    [ -e /proc/sys/net/core/flow_limit_cpu_bitmap ] || return 0
    current=$(cat /proc/sys/net/core/flow_limit_cpu_bitmap 2>/dev/null || true)
    if [ ! -f "$FLOW_LIMIT_BEFORE" ]; then
      printf '%s\n' "$current" > "$FLOW_LIMIT_BEFORE"
    fi
    mask=$(_bitmap_for_all_workers)
    printf '%s\n' "$mask" > /proc/sys/net/core/flow_limit_cpu_bitmap 2>/dev/null || return 0
    if [ "$(cat /proc/sys/net/core/flow_limit_cpu_bitmap 2>/dev/null || true)" = "$mask" ]; then
      printf '%s\n' "$mask" > "$FLOW_LIMIT_OWNED"
    fi
    return 0
  fi

  [ -f "$FLOW_LIMIT_BEFORE" ] && [ -f "$FLOW_LIMIT_OWNED" ] || return 0
  before=$(cat "$FLOW_LIMIT_BEFORE" 2>/dev/null || true)
  owned=$(cat "$FLOW_LIMIT_OWNED" 2>/dev/null || true)
  current=$(cat /proc/sys/net/core/flow_limit_cpu_bitmap 2>/dev/null || true)
  if [ -n "$before" ] && [ "$current" = "$owned" ] && [ -w /proc/sys/net/core/flow_limit_cpu_bitmap ]; then
    printf '%s\n' "$before" > /proc/sys/net/core/flow_limit_cpu_bitmap 2>/dev/null || true
  fi
  rm -f "$FLOW_LIMIT_BEFORE" "$FLOW_LIMIT_OWNED"
}

_apply_irq_affinity() {
  local i irq cpu effective queue
  IRQ_AFFINITY_OK=0
  [ "${IRQ_MAPPING_COMPLETE:-0}" = "1" ] || return 0
  [ "${#IRQS[@]}" -gt 0 ] || return 0
  [ "${#IRQ_CPUS[@]}" -gt 0 ] || return 0
  IRQ_AFFINITY_OK=1
  for ((i = 0; i < ${#IRQS[@]}; i++)); do
    irq="${IRQS[$i]}"
    queue="${IRQ_QUEUE_IDS[$i]:-}"
    case "$queue" in ''|*[!0-9]*) IRQ_AFFINITY_OK=0; continue ;; esac
    cpu="${IRQ_CPUS[$(( queue % ${#IRQ_CPUS[@]} ))]}"
    if [ -w "/proc/irq/$irq/smp_affinity_list" ]; then
      echo "$cpu" > "/proc/irq/$irq/smp_affinity_list" 2>/dev/null || true
      effective=$(cat "/proc/irq/$irq/effective_affinity_list" 2>/dev/null || cat "/proc/irq/$irq/smp_affinity_list" 2>/dev/null || true)
      [ "$effective" = "$cpu" ] || IRQ_AFFINITY_OK=0
    else
      IRQ_AFFINITY_OK=0
    fi
  done
}

_apply_xps() {
  local i csv mask
  local -a cpu_list
  if [ "${#TXQS[@]}" -gt 0 ]; then
    for ((i = 0; i < ${#TXQS[@]}; i++)); do
      mapfile -t cpu_list < <(_build_group_for_queue "$i" "${#TXQS[@]}")
      [ "${#cpu_list[@]}" -gt 0 ] || continue
      csv=$(IFS=,; echo "${cpu_list[*]}")
      mask=$(_cpulist_to_mask "$csv")
      [ -w "${TXQS[$i]}/xps_cpus" ] && echo "$mask" > "${TXQS[$i]}/xps_cpus" 2>/dev/null || true
    done
  fi
}

_apply_rps_rfs() {
  local enable total_flows current_flows minimum_flows perq i irqcpu csv mask worker_cnt cpu
  local -a cpu_list filtered_cpus
  worker_cnt="${#WORKER_CPUS[@]}"
  enable="${ENABLE_RPS:-auto}"

  if [ "${#RXQS[@]}" -eq 0 ]; then
    return 0
  fi

  if [ "$enable" = "0" ] || [ "$enable" = "off" ] || [ "$enable" = "no" ]; then
    enable="no"
  elif [ "$enable" = "1" ] || [ "$enable" = "on" ] || [ "$enable" = "yes" ]; then
    enable="yes"
  else
    # Topology CPUs are not application worker threads.  Keep RPS off for a
    # user-space relay by default; enable it automatically for kernel
    # forwarding, where it can actually move work between NAPI CPUs.
    if [ "${RPS_FORWARD_ONLY:-1}" = "1" ] && [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)" != "1" ]; then
      enable="no"
    elif [ "${IRQ_MAPPING_COMPLETE:-0}" = "1" ] && [ "${#RXQS[@]}" -lt "$worker_cnt" ] && [ "$worker_cnt" -gt 1 ]; then
      enable="yes"
    else
      enable="no"
    fi
  fi

  if [ "$enable" = "yes" ]; then
    total_flows="${RFS_FLOW_ENTRIES:-auto}"
    case "$total_flows" in
      auto|''|*[!0-9]*) total_flows=$(_calc_rfs_total_flows "${#RXQS[@]}" "$worker_cnt") ;;
      *) : ;;
    esac

    minimum_flows=$(( ${#RXQS[@]} * 1024 ))
    [ "$total_flows" -lt "$minimum_flows" ] && total_flows="$minimum_flows"
    current_flows=$(cat /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || echo 0)
    case "$current_flows" in ''|*[!0-9]*) current_flows=0 ;; esac
    [ "$current_flows" -gt "$total_flows" ] && total_flows="$current_flows"
    echo "$total_flows" > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true
    perq=$(( total_flows / ${#RXQS[@]} ))
    [ "$perq" -lt 1 ] && perq=1

    for ((i = 0; i < ${#RXQS[@]}; i++)); do
      irqcpu="${IRQ_CPUS[$(( i % ${#IRQ_CPUS[@]} ))]}"
      cpu_list=()
      filtered_cpus=()

      mapfile -t cpu_list < <(_build_group_for_queue "$i" "${#RXQS[@]}")
      for cpu in "${cpu_list[@]}"; do
        [ "$cpu" = "$irqcpu" ] || filtered_cpus+=("$cpu")
      done
      [ "${#filtered_cpus[@]}" -eq 0 ] || cpu_list=("${filtered_cpus[@]}")
      if [ "${#cpu_list[@]}" -gt "${RPS_CPUS_PER_QUEUE:-2}" ]; then
        cpu_list=("${cpu_list[@]:0:${RPS_CPUS_PER_QUEUE:-2}}")
      fi
      [ "${#cpu_list[@]}" -eq 0 ] && cpu_list=("$irqcpu")

      csv=$(IFS=,; echo "${cpu_list[*]}")
      mask=$(_cpulist_to_mask "$csv")
      [ -w "${RXQS[$i]}/rps_cpus" ] && echo "$mask" > "${RXQS[$i]}/rps_cpus" 2>/dev/null || true
      [ -w "${RXQS[$i]}/rps_flow_cnt" ] && echo "$perq" > "${RXQS[$i]}/rps_flow_cnt" 2>/dev/null || true
    done

  else
    for Q in "${RXQS[@]}"; do
      [ -w "$Q/rps_cpus" ] && echo 0 > "$Q/rps_cpus" 2>/dev/null || true
      [ -w "$Q/rps_flow_cnt" ] && echo 0 > "$Q/rps_flow_cnt" 2>/dev/null || true
    done
  fi
  _sync_flow_limit
}

_maybe_disable_irqbalance() {
  local policy="${IRQBALANCE_POLICY:-auto}"

  if ! command -v systemctl >/dev/null 2>&1; then
    return 0
  fi
  if ! systemctl is-active --quiet irqbalance 2>/dev/null; then
    return 0
  fi

  case "$policy" in
    keep) return 0 ;;
    disable)
      if [ "${DISABLE_IRQBALANCE:-1}" = "1" ]; then
        systemctl stop irqbalance >/dev/null 2>&1 || true
        systemctl disable irqbalance >/dev/null 2>&1 || true
      fi
      ;;
    auto|'')
      if [ "${IRQ_AFFINITY_OK:-0}" = "1" ] && [ "${DISABLE_IRQBALANCE:-1}" = "1" ]; then
        systemctl stop irqbalance >/dev/null 2>&1 || true
        systemctl disable irqbalance >/dev/null 2>&1 || true
      fi
      ;;
  esac
}

_collect_irqs() {
  local path device_tag=""
  if [ -e "/sys/class/net/$DEV/device" ]; then
    device_tag=$(basename "$(readlink -f "/sys/class/net/$DEV/device" 2>/dev/null || true)")
  fi
  for path in /sys/class/net/"$DEV"/device/msi_irqs/*; do
    [ -e "$path" ] && basename "$path"
  done
  awk -v dev="$DEV" -v tag="$device_tag" '
    $0 ~ dev || (tag != "" && $0 ~ tag) {gsub(":", "", $1); print $1}
  ' /proc/interrupts
}

_collect_irq_map() {
  local path device_tag=""
  if [ -e "/sys/class/net/$DEV/device" ]; then
    device_tag=$(basename "$(readlink -f "/sys/class/net/$DEV/device" 2>/dev/null || true)")
  fi
  awk -v dev="$DEV" -v tag="$device_tag" '
    $0 ~ dev || (tag != "" && $0 ~ tag) {
      irq=$1
      gsub(":", "", irq)
      action=tolower($0)
      if (action ~ /(admin|config|mgmt|management|async|command)/) next
      candidate=action
      queue=""
      if (candidate ~ /(txrx|tx-rx|rx|tx)[-_.]?[0-9]+/) {
        sub(/^.*(txrx|tx-rx|rx|tx)[-_.]?/, "", candidate)
        sub(/[^0-9].*$/, "", candidate)
        queue=candidate
      } else if (candidate ~ /(input|output)\.[0-9]+/) {
        sub(/^.*(input|output)\./, "", candidate)
        sub(/[^0-9].*$/, "", candidate)
        queue=candidate
      } else if (candidate ~ /comp[0-9]+/) {
        sub(/^.*comp/, "", candidate)
        sub(/[^0-9].*$/, "", candidate)
        queue=candidate
      } else if (candidate ~ /(queue|block)[-_.]?[0-9]+/) {
        sub(/^.*(queue|block)[-_.]?/, "", candidate)
        sub(/[^0-9].*$/, "", candidate)
        queue=candidate
      }
      if (queue ~ /^[0-9]+$/ && irq ~ /^[0-9]+$/) print queue, irq
    }
  ' /proc/interrupts 2>/dev/null
}

if ! ip link show "$DEV" >/dev/null 2>&1; then
  echo "网卡接口 $DEV 不存在"
  exit 1
fi

_build_worker_cpu_list
[ "${#WORKER_CPUS[@]}" -gt 0 ] || { echo "未选出工作 CPU"; exit 1; }

TARGET_QUEUES=$(_pick_target_queues)
case "$TARGET_QUEUES" in ''|*[!0-9]*|0) TARGET_QUEUES=1 ;; esac

TARGET_QUEUES=$(_apply_queue_count "$TARGET_QUEUES")
case "$TARGET_QUEUES" in ''|*[!0-9]*|0) TARGET_QUEUES=1 ;; esac

_build_irq_cpu_list "$TARGET_QUEUES"
[ "${#IRQ_CPUS[@]}" -gt 0 ] || { echo "未选出 IRQ CPU"; exit 1; }

RING_RESULT=$(_apply_max_rings)
FLOW_RESULT=$(_apply_flow_control)
COALESCE_RESULT=$(_apply_coalesce)
_apply_offloads

mapfile -t RXQS < <(find "/sys/class/net/$DEV/queues" -maxdepth 1 -type d -name 'rx-*' | sort -V)
mapfile -t TXQS < <(find "/sys/class/net/$DEV/queues" -maxdepth 1 -type d -name 'tx-*' | sort -V)
# ethtool may accept a requested queue count but leave a different count
# active.  Drive affinity and RPS from the queues that really exist.
if [ "${#RXQS[@]}" -gt 0 ]; then
  TARGET_QUEUES="${#RXQS[@]}"
  _build_irq_cpu_list "$TARGET_QUEUES"
fi
IRQS=()
IRQ_QUEUE_IDS=()
IRQ_MAPPING_COMPLETE=0
local_line=""
mapfile -t IRQ_MAP < <(_collect_irq_map | awk '!seen[$2]++' | sort -k1,1n -k2,2n)
for local_line in "${IRQ_MAP[@]}"; do
  queue="${local_line%% *}"
  irq="${local_line#* }"
  case "$queue:$irq" in
    *[!0-9:]*|:*) continue ;;
  esac
  [ "$queue" -lt "${#RXQS[@]}" ] || continue
  IRQ_QUEUE_IDS+=("$queue")
  IRQS+=("$irq")
done
if [ "${#RXQS[@]}" -gt 0 ] && [ "${#IRQS[@]}" -gt 0 ]; then
  IRQ_MAPPING_COMPLETE=1
  for ((i = 0; i < ${#RXQS[@]}; i++)); do
    queue_found=0
    for queue in "${IRQ_QUEUE_IDS[@]}"; do
      [ "$queue" = "$i" ] && queue_found=1
    done
    [ "$queue_found" -eq 1 ] || IRQ_MAPPING_COMPLETE=0
  done
fi

_apply_irq_affinity
_maybe_disable_irqbalance
_apply_xps
_apply_rps_rfs
_force_fq_qdisc

WORKER_CSV=$(IFS=,; echo "${WORKER_CPUS[*]}")
IRQ_CSV=$(IFS=,; echo "${IRQ_CPUS[*]}")
LINK_SPEED=$(_get_link_speed || true)

printf '网卡: %s\n' "$DEV"
printf '驱动: %s\n' "$(_get_driver || echo unknown)"
printf '链路速率: %s\n' "$([ -n "$LINK_SPEED" ] && printf '%s Mb/s' "$LINK_SPEED" || printf 'unknown')"
printf 'NUMA 节点: %s\n' "$(_resolve_nic_numa_node || echo -1)"
printf '工作 CPU: %s\n' "$WORKER_CSV"
printf 'IRQ CPU: %s\n' "$IRQ_CSV"
printf 'IRQ 映射: %s\n' "${IRQ_MAPPING_COMPLETE:-0}" | sed 's/^IRQ 映射: 1$/IRQ 映射: queue-aware/;s/^IRQ 映射: 0$/IRQ 映射: unknown (保留 irqbalance)/'
printf '工作 CPU 数: %s\n' "${#WORKER_CPUS[@]}"
printf '目标队列: %s\n' "$TARGET_QUEUES"
printf 'ring: %s\n' "$RING_RESULT"
printf 'flow control: %s\n' "$FLOW_RESULT"
printf 'coalesce: %s\n' "$COALESCE_RESULT"
printf 'rps_sock_flow_entries: %s\n' "$(cat /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || echo 0)"
if [ -e /proc/sys/net/core/flow_limit_cpu_bitmap ]; then
  printf 'flow_limit_cpu_bitmap: %s\n' "$(cat /proc/sys/net/core/flow_limit_cpu_bitmap 2>/dev/null || echo 0)"
fi
printf '网卡调优已应用到 %s\n' "$DEV"
EOF_HELPER
  chmod +x "$NIC_HELPER"
}

build_nic_service() {
  cat > "$NIC_SERVICE" <<'EOF_SERVICE'
[Unit]
Description=Live Relay VPS NIC Tuning
Wants=network-online.target
After=network-online.target irqbalance.service

[Service]
Type=oneshot
EnvironmentFile=-/etc/live-relay-nic.env
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
  ensure_cmd ip
  ensure_cmd tc
  ensure_cmd lscpu || true
  ensure_cmd modprobe || true

  build_nic_helper
  build_nic_service

  cat > "$NIC_ENV_FILE" <<EOF_NICENV
DEV=$nic
USE_HT=${USE_HT:-0}
WORKER_CPUS_TARGET=${WORKER_CPUS_TARGET:-local}
TARGET_QUEUES=${TARGET_QUEUES:-auto}
MAX_RINGS=${MAX_RINGS:-0}
RING_MODE=${RING_MODE:-balanced}
COALESCE_MODE=${COALESCE_MODE:-balanced}
RFS_FLOW_ENTRIES=${RFS_FLOW_ENTRIES:-auto}
ENABLE_RPS=${ENABLE_RPS:-auto}
RPS_FORWARD_ONLY=${RPS_FORWARD_ONLY:-1}
RPS_CPUS_PER_QUEUE=${RPS_CPUS_PER_QUEUE:-2}
ENABLE_FLOW_LIMIT=${ENABLE_FLOW_LIMIT:-0}
DISABLE_IRQBALANCE=${DISABLE_IRQBALANCE:-1}
IRQBALANCE_POLICY=${IRQBALANCE_POLICY:-auto}
FLOW_CONTROL_MODE=${FLOW_CONTROL_MODE:-keep}
FORCE_FQ=${FORCE_FQ:-1}
TUNE_OFFLOADS=${TUNE_OFFLOADS:-1}
EOF_NICENV

  "$NIC_HELPER"

  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload
    systemctl enable --now live-relay-nic-tuning.service >/dev/null 2>&1 || true
    log "模式 2 的 VPS/云网卡调优服务已安装并启用。"
  else
    warn "未找到 systemd，网卡调优已立即生效，但重启后不会持久保留。"
  fi
}

detect_data_plane() {
  local tcp=0 udp=0 forward=0 wg=0 parts=()
  if command -v ss >/dev/null 2>&1; then
    tcp=$(ss -H -ltn 2>/dev/null | awk 'END {print NR + 0}')
    udp=$(ss -H -lun 2>/dev/null | awk 'END {print NR + 0}')
  fi
  [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)" = "1" ] && forward=1
  command -v wg >/dev/null 2>&1 && wg show interfaces 2>/dev/null | grep -q . && wg=1
  [ "$tcp" -gt 0 ] && parts+=(TCP)
  [ "$udp" -gt 0 ] && parts+=(UDP)
  [ "$wg" -eq 1 ] && parts+=(WireGuard)
  [ "$forward" -eq 1 ] && parts+=(Forward)
  [ "${#parts[@]}" -gt 0 ] || parts+=(Unknown)
  local IFS=+
  echo "${parts[*]}"
}

capture_original_runtime() {
  local nic="$1" snapshot="$SNAPSHOT_DIR/runtime.env" irq path value
  [ -f "$snapshot" ] && return 0
  mkdir -p "$SNAPSHOT_DIR"

  {
    printf 'ORIGINAL_NIC=%q\n' "$nic"
    printf 'IRQBALANCE_ENABLED=%q\n' "$(systemctl is-enabled irqbalance 2>/dev/null || echo unknown)"
    printf 'IRQBALANCE_ACTIVE=%q\n' "$(systemctl is-active irqbalance 2>/dev/null || echo unknown)"
    printf 'ORIGINAL_COMBINED=%q\n' "$(ethtool -l "$nic" 2>/dev/null | awk '/Current hardware settings:/ {s=1; next} s && /Combined:/ {print $2; exit}')"
    printf 'ORIGINAL_RX_RING=%q\n' "$(ethtool -g "$nic" 2>/dev/null | awk '/Current hardware settings:/ {s=1; next} s && $1 == "RX:" {print $2; exit}')"
    printf 'ORIGINAL_TX_RING=%q\n' "$(ethtool -g "$nic" 2>/dev/null | awk '/Current hardware settings:/ {s=1; next} s && $1 == "TX:" {print $2; exit}')"
    printf 'ORIGINAL_RX_USECS=%q\n' "$(ethtool -c "$nic" 2>/dev/null | awk -F': ' '/rx-usecs:/ {print $2; exit}')"
    printf 'ORIGINAL_TX_USECS=%q\n' "$(ethtool -c "$nic" 2>/dev/null | awk -F': ' '/tx-usecs:/ {print $2; exit}')"
    printf 'ORIGINAL_PAUSE_RX=%q\n' "$(ethtool -a "$nic" 2>/dev/null | awk -F': ' '/RX:/ {print $2; exit}')"
    printf 'ORIGINAL_PAUSE_TX=%q\n' "$(ethtool -a "$nic" 2>/dev/null | awk -F': ' '/TX:/ {print $2; exit}')"
    printf 'ORIGINAL_RPS_SOCK_FLOW_ENTRIES=%q\n' "$(cat /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true)"
    printf 'ORIGINAL_FLOW_LIMIT_CPU_BITMAP=%q\n' "$(cat /proc/sys/net/core/flow_limit_cpu_bitmap 2>/dev/null || true)"
  } > "$snapshot"

  ethtool -k "$nic" 2>/dev/null | awk -F': ' '
    /^(rx-checksumming|tx-checksumming|scatter-gather|tcp-segmentation-offload|generic-segmentation-offload|generic-receive-offload|large-receive-offload):/ {
      split($2, value, " ")
      if (value[1] == "on" || value[1] == "off") print $1 "\t" value[1]
    }
  ' > "$SNAPSHOT_DIR/offloads.tsv"

  : > "$SNAPSHOT_DIR/irq-affinity.tsv"
  while read -r irq; do
    [ -r "/proc/irq/$irq/smp_affinity_list" ] || continue
    printf '%s\t%s\n' "$irq" "$(cat "/proc/irq/$irq/smp_affinity_list")" >> "$SNAPSHOT_DIR/irq-affinity.tsv"
  done < <(collect_nic_irqs "$nic" | awk '!seen[$0]++')

  : > "$SNAPSHOT_DIR/queue-state.tsv"
  for path in /sys/class/net/"$nic"/queues/{rx,tx}-*/{rps_cpus,rps_flow_cnt,xps_cpus,xps_rxqs}; do
    [ -r "$path" ] || continue
    value=$(cat "$path" 2>/dev/null || true)
    printf '%s\t%s\n' "$path" "$value" >> "$SNAPSHOT_DIR/queue-state.tsv"
  done

  : > "$SNAPSHOT_DIR/cpu-power.tsv"
  for path in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
    [ -r "$path" ] || continue
    printf '%s\t%s\n' "$path" "$(cat "$path" 2>/dev/null || true)" >> "$SNAPSHOT_DIR/cpu-power.tsv"
  done
}

apply_performance_power_policy() {
  local path
  [ "${TUNE_CPU_POWER:-1}" = "1" ] || return 0
  for path in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -w "$path" ] && echo performance > "$path" 2>/dev/null || true
  done
  for path in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
    [ -w "$path" ] && echo performance > "$path" 2>/dev/null || true
  done
}

restore_original_runtime() {
  local snapshot="$SNAPSHOT_DIR/runtime.env" path value irq nic
  [ -f "$snapshot" ] || return 0
  # shellcheck disable=SC1090
  source "$snapshot"
  nic="${ORIGINAL_NIC:-}"

  if [ -n "$nic" ] && ip link show "$nic" >/dev/null 2>&1; then
    [ -n "${ORIGINAL_COMBINED:-}" ] && ethtool -L "$nic" combined "$ORIGINAL_COMBINED" >/dev/null 2>&1 || true
    if [ -n "${ORIGINAL_RX_RING:-}" ] && [ -n "${ORIGINAL_TX_RING:-}" ]; then
      ethtool -G "$nic" rx "$ORIGINAL_RX_RING" tx "$ORIGINAL_TX_RING" >/dev/null 2>&1 || true
    fi
    if [ -n "${ORIGINAL_RX_USECS:-}" ] && [ -n "${ORIGINAL_TX_USECS:-}" ]; then
      ethtool -C "$nic" rx-usecs "$ORIGINAL_RX_USECS" tx-usecs "$ORIGINAL_TX_USECS" >/dev/null 2>&1 || true
    fi
    if [ -n "${ORIGINAL_PAUSE_RX:-}" ] && [ -n "${ORIGINAL_PAUSE_TX:-}" ]; then
      ethtool -A "$nic" rx "$ORIGINAL_PAUSE_RX" tx "$ORIGINAL_PAUSE_TX" >/dev/null 2>&1 || true
    fi
    if [ -f "$SNAPSHOT_DIR/offloads.tsv" ]; then
      while IFS=$'\t' read -r path value; do
        ethtool -K "$nic" "$path" "$value" >/dev/null 2>&1 || true
      done < "$SNAPSHOT_DIR/offloads.tsv"
    fi
  fi

  if [ -f "$SNAPSHOT_DIR/irq-affinity.tsv" ]; then
    while IFS=$'\t' read -r irq value; do
      [ -w "/proc/irq/$irq/smp_affinity_list" ] && echo "$value" > "/proc/irq/$irq/smp_affinity_list" 2>/dev/null || true
    done < "$SNAPSHOT_DIR/irq-affinity.tsv"
  fi
  if [ -f "$SNAPSHOT_DIR/queue-state.tsv" ]; then
    while IFS=$'\t' read -r path value; do
      [ -w "$path" ] && echo "$value" > "$path" 2>/dev/null || true
    done < "$SNAPSHOT_DIR/queue-state.tsv"
  fi
  if [ -f "$SNAPSHOT_DIR/cpu-power.tsv" ]; then
    while IFS=$'\t' read -r path value; do
      [ -w "$path" ] && echo "$value" > "$path" 2>/dev/null || true
    done < "$SNAPSHOT_DIR/cpu-power.tsv"
  fi

  if [ -n "${ORIGINAL_RPS_SOCK_FLOW_ENTRIES:-}" ] && [ -w /proc/sys/net/core/rps_sock_flow_entries ]; then
    printf '%s\n' "$ORIGINAL_RPS_SOCK_FLOW_ENTRIES" > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true
  fi
  if [ -n "${ORIGINAL_FLOW_LIMIT_CPU_BITMAP:-}" ] && [ -w /proc/sys/net/core/flow_limit_cpu_bitmap ]; then
    printf '%s\n' "$ORIGINAL_FLOW_LIMIT_CPU_BITMAP" > /proc/sys/net/core/flow_limit_cpu_bitmap 2>/dev/null || true
  fi

  if command -v systemctl >/dev/null 2>&1; then
    [ "${IRQBALANCE_ENABLED:-unknown}" = "enabled" ] && systemctl enable irqbalance >/dev/null 2>&1 || true
    [ "${IRQBALANCE_ACTIVE:-unknown}" = "active" ] && systemctl start irqbalance >/dev/null 2>&1 || true
  fi
}

build_auto_controller() {
  cat > "$AUTO_HELPER" <<'EOF_AUTO'
#!/usr/bin/env bash
set -u

NIC_ENV_FILE="/etc/live-relay-nic.env"
AUTO_ENV_FILE="/etc/live-relay-auto.env"
[ -f "$NIC_ENV_FILE" ] && source "$NIC_ENV_FILE"
[ -f "$AUTO_ENV_FILE" ] && source "$AUTO_ENV_FILE"

DEV="${DEV:-}"
WORKDIR="${WORKDIR:-/opt/live-relay-tuner}"
PROC_ROOT="${PROC_ROOT:-/proc}"
SYS_ROOT="${SYS_ROOT:-/sys}"
STATE_FILE="$WORKDIR/auto-state.env"
STABLE_FILE="$WORKDIR/stable-state.env"
PAUSE_FILE="$WORKDIR/paused"
METRICS_LOG="$WORKDIR/metrics.log"
LOCK_DIR="$WORKDIR/controller.lock"
CPU_PREV_FILE="$WORKDIR/cpu-window.prev"
CPU_NOW_FILE="$WORKDIR/cpu-window.now"
INTERVAL="${AUTO_INTERVAL:-10}"
UP_WINDOWS="${AUTO_UP_WINDOWS:-3}"
DOWN_WINDOWS="${AUTO_DOWN_WINDOWS:-12}"
COOLDOWN_WINDOWS="${AUTO_COOLDOWN_WINDOWS:-6}"
WARMUP_WINDOWS="${AUTO_WARMUP_WINDOWS:-3}"
SOFTIRQ_HIGH="${SOFTIRQ_HIGH:-70}"
SOFTIRQ_LOW="${SOFTIRQ_LOW:-35}"
STEAL_HIGH="${STEAL_HIGH:-5}"
CPU_COUNT="${ONLINE_CPUS:-1}"
PHYSICAL_COUNT="${PHYSICAL_CORES:-$CPU_COUNT}"
MEM_GB="${MEMORY_GB:-1}"
NUMA_COUNT="${NUMA_NODES:-1}"
RX_QUEUES="${RX_QUEUE_COUNT:-1}"
NIC_DRIVER_NAME="${NIC_DRIVER:-unknown}"
NIC_HELPER="/usr/local/sbin/live-relay-nic-apply.sh"
case "$INTERVAL" in ''|*[!0-9]*|0) INTERVAL=10 ;; esac
case "$UP_WINDOWS" in ''|*[!0-9]*|0) UP_WINDOWS=3 ;; esac
case "$DOWN_WINDOWS" in ''|*[!0-9]*|0) DOWN_WINDOWS=12 ;; esac
case "$COOLDOWN_WINDOWS" in ''|*[!0-9]*) COOLDOWN_WINDOWS=6 ;; esac
case "$WARMUP_WINDOWS" in ''|*[!0-9]*) WARMUP_WINDOWS=3 ;; esac
case "$SOFTIRQ_HIGH" in ''|*[!0-9]*) SOFTIRQ_HIGH=70 ;; esac
case "$SOFTIRQ_LOW" in ''|*[!0-9]*) SOFTIRQ_LOW=35 ;; esac
case "$STEAL_HIGH" in ''|*[!0-9]*) STEAL_HIGH=5 ;; esac
case "$CPU_COUNT" in ''|*[!0-9]*|0) CPU_COUNT=1 ;; esac
case "$PHYSICAL_COUNT" in ''|*[!0-9]*|0) PHYSICAL_COUNT="$CPU_COUNT" ;; esac
case "$MEM_GB" in ''|*[!0-9]*|0) MEM_GB=1 ;; esac
case "$NUMA_COUNT" in ''|*[!0-9]*|0) NUMA_COUNT=1 ;; esac
case "$RX_QUEUES" in ''|*[!0-9]*|0) RX_QUEUES=1 ;; esac
mkdir -p "$WORKDIR"

release_lock() {
  [ -f "$LOCK_DIR/pid" ] && [ "$(cat "$LOCK_DIR/pid" 2>/dev/null)" = "$$" ] || return 0
  rm -f "$CPU_PREV_FILE" "$CPU_NOW_FILE"
  rm -rf "$LOCK_DIR"
}

acquire_lock() {
  local owner=""
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" > "$LOCK_DIR/pid"
  else
    [ -r "$LOCK_DIR/pid" ] && owner=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
    case "$owner" in ''|*[!0-9]*) owner="" ;; esac
    if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
      echo "控制器正在运行（PID ${owner}），请先停止服务后再执行写操作。" >&2
      return 1
    fi
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR" 2>/dev/null || return 1
    printf '%s\n' "$$" > "$LOCK_DIR/pid"
  fi
  trap release_lock EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

read_counter() {
  local value
  value=$(cat "$1" 2>/dev/null || true)
  case "$value" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$value" ;;
  esac
}

softnet_totals() {
  local line c1 c2 c3 rest dropped=0 squeezed=0
  while read -r line; do
    read -r c1 c2 c3 rest <<< "$line"
    case "${c2:-}" in ''|*[!0-9A-Fa-f]*) c2=0 ;; esac
    case "${c3:-}" in ''|*[!0-9A-Fa-f]*) c3=0 ;; esac
    dropped=$(( dropped + 16#$c2 ))
    squeezed=$(( squeezed + 16#$c3 ))
  done < "$PROC_ROOT/net/softnet_stat" 2>/dev/null
  printf '%s %s\n' "$dropped" "$squeezed"
}

cpu_totals() {
  awk '
    /^cpu / {
      total=0
      last=(NF < 9 ? NF : 9)
      for (i=2; i<=last; i++) total += $i
      print total, $8+0, $9+0
      printed=1
      exit
    }
    END {if (!printed) print "0 0 0"}
  ' "$PROC_ROOT/stat" 2>/dev/null
}

cpu_snapshot() {
  awk '
    /^cpu[0-9]+ / {
      total=0
      last=(NF < 9 ? NF : 9)
      for (i=2; i<=last; i++) total += $i
      print $1, total, $8+0, $9+0
    }
  ' "$PROC_ROOT/stat" 2>/dev/null
}

cpu_window_pressure() {
  awk '
    NR == FNR {
      previous_total[$1]=$2
      previous_soft[$1]=$3
      previous_steal[$1]=$4
      previous_count++
      next
    }
    {
      if (!($1 in previous_total)) {invalid=1; next}
      current_count++
      delta_total=$2-previous_total[$1]
      delta_soft=$3-previous_soft[$1]
      delta_steal=$4-previous_steal[$1]
      if (delta_total <= 0 || delta_soft < 0 || delta_steal < 0) {invalid=1; next}
      soft=int(delta_soft*100/delta_total)
      steal=int(delta_steal*100/delta_total)
      if (soft > max_soft) max_soft=soft
      if (steal > max_steal) max_steal=steal
      valid_count++
    }
    END {
      if (valid_count == 0 || current_count != previous_count || invalid) print "0 0 0"
      else print max_soft+0, max_steal+0, 1
    }
  ' "$1" "$2" 2>/dev/null
}

monotonic_millis() {
  local value
  value=$(awk '{printf "%.0f\n", $1*1000; exit}' "$PROC_ROOT/uptime" 2>/dev/null || true)
  case "$value" in
    ''|*[!0-9]*) echo $(( $(date +%s) * 1000 )) ;;
    *) echo "$value" ;;
  esac
}

driver_drops() {
  ethtool -S "$DEV" 2>/dev/null | awk -F':' '
    {
      name=tolower($1)
      value=$2
      gsub(/^[ \t]+|[ \t]+$/, "", value)
      if (value !~ /^[0-9]+$/) next
      if (name ~ /(rx|tx)/ && name ~ /(drop|discard|miss|no.buffer)/) {
        if (name ~ /(queue|rxq|txq|q[0-9]|_[0-9]+_)/) {
          queue_total += value
          queue_seen=1
        } else {
          aggregate_total += value
        }
      }
    }
    END {if (queue_seen) print queue_total + 0; else print aggregate_total + 0}'
}

udp_counters() {
  awk '
    $1 == "Udp:" && !seen {
      for (i=2; i<=NF; i++) header[i]=$i
      seen=1
      next
    }
    $1 == "Udp:" && seen {
      for (i=2; i<=NF; i++) {
        if (header[i] == "InErrors") in_errors=$i
        else if (header[i] == "RcvbufErrors") rcvbuf=$i
        else if (header[i] == "SndbufErrors") sndbuf=$i
      }
      print in_errors + 0, rcvbuf + 0, sndbuf + 0
      printed=1
      exit
    }
    END {if (!printed) print "0 0 0"}
  ' "$PROC_ROOT/net/snmp" 2>/dev/null
}

tcp_counters() {
  awk '
    $1 == "Tcp:" && !seen {
      for (i=2; i<=NF; i++) header[i]=$i
      seen=1
      next
    }
    $1 == "Tcp:" && seen {
      for (i=2; i<=NF; i++) {
        if (header[i] == "RetransSegs") retrans=$i
        else if (header[i] == "OutSegs") outsegs=$i
      }
      print retrans + 0, outsegs + 0
      printed=1
      exit
    }
    END {if (!printed) print "0 0"}
  ' "$PROC_ROOT/net/snmp" 2>/dev/null
}

tcp_listen_drops() {
  awk '
    $1 == "TcpExt:" && !seen {
      for (i=2; i<=NF; i++) header[i]=$i
      seen=1
      next
    }
    $1 == "TcpExt:" && seen {
      for (i=2; i<=NF; i++) {
        # ListenOverflows/TCPReqQFullDrop are often included in
        # ListenDrops.  Use the kernel aggregate ListenDrops counter once
        # instead of taking a max or adding overlapping counters.
        if (header[i] == "ListenDrops") total=$i
      }
      print total + 0
      printed=1
      exit
    }
    END {if (!printed) print 0}
  ' "$PROC_ROOT/net/netstat" 2>/dev/null
}

qdisc_drops() {
  tc -s qdisc show dev "$DEV" 2>/dev/null | awk '
    /^qdisc / {
      qdisc_type=$2
      is_leaf = ($0 ~ / parent /) ? 1 : 0
      is_data = (qdisc_type != "mq" && qdisc_type != "ingress" && qdisc_type != "clsact") ? 1 : 0
      if (is_data && is_leaf) leaf_seen=1
      next
    }
    {
      for (i=1; i<=NF; i++) {
        key=$i
        gsub(/[()]/, "", key)
        if (key == "dropped" && i < NF) {
          value=$(i+1)
          gsub(/[^0-9]/, "", value)
          if (value ~ /^[0-9]+$/) {
            if (is_data && is_leaf) leaf_total += value
            else if (is_data) root_total += value
          }
        }
      }
    }
    END {if (leaf_seen) print leaf_total + 0; else print root_total + 0}'
}

apply_parameter_group() {
  local keys=(net.core.netdev_max_backlog net.core.netdev_budget net.core.netdev_budget_usecs net.core.dev_weight)
  local values=("$ACTIVE_BACKLOG" "$ACTIVE_BUDGET" "$ACTIVE_BUDGET_USECS" "$ACTIVE_WEIGHT")
  local old_values=() applied_indices=() i key value old actual path j
  for ((i = 0; i < ${#keys[@]}; i++)); do
    key="${keys[$i]}"; value="${values[$i]}"
    path="$PROC_ROOT/sys/${key//.//}"
    [ -e "$path" ] && [ -w "$path" ] || continue
    old=$(sysctl -n "$key" 2>/dev/null | awk '{$1=$1; print}' || true)
    [ -n "$old" ] || continue
    old_values[$i]="$old"
    if ! sysctl -q -w "$key=$value" >/dev/null 2>&1; then
      for ((j = ${#applied_indices[@]} - 1; j >= 0; j--)); do
        i="${applied_indices[$j]}"
        sysctl -q -w "${keys[$i]}=${old_values[$i]}" >/dev/null 2>&1 || true
      done
      return 1
    fi
    actual=$(sysctl -n "$key" 2>/dev/null | awk '{$1=$1; print}' || true)
    if [ "$actual" != "$value" ]; then
      sysctl -q -w "$key=$old" >/dev/null 2>&1 || true
      for ((j = ${#applied_indices[@]} - 1; j >= 0; j--)); do
        i="${applied_indices[$j]}"
        sysctl -q -w "${keys[$i]}=${old_values[$i]}" >/dev/null 2>&1 || true
      done
      return 1
    fi
    applied_indices+=("$i")
  done
  return 0
}

write_state() {
  local level="$1" reason="$2" status="${3:-running}" tmp="$STATE_FILE.tmp.$$"
  {
    printf 'STATUS=%q\n' "$status"
    printf 'LEVEL=%q\n' "$level"
    printf 'REASON=%q\n' "$reason"
    printf 'PPS=%q\n' "${CURRENT_PPS:-0}"
    printf 'RX_BPS=%q\n' "${CURRENT_RX_BPS:-0}"
    printf 'TX_BPS=%q\n' "${CURRENT_TX_BPS:-0}"
    printf 'SOFTIRQ_PCT=%q\n' "${CURRENT_SOFTIRQ:-0}"
    printf 'STEAL_PCT=%q\n' "${CURRENT_STEAL:-0}"
    printf 'DROP_DELTA=%q\n' "${CURRENT_DROPS:-0}"
    printf 'SQUEEZE_DELTA=%q\n' "${CURRENT_SQUEEZE:-0}"
    printf 'UDP_RCVBUF_DELTA=%q\n' "${CURRENT_UDP_RCVBUF:-0}"
    printf 'UDP_SNDBUF_DELTA=%q\n' "${CURRENT_UDP_SNDBUF:-0}"
    printf 'TCP_RETRANS_DELTA=%q\n' "${CURRENT_RETRANS:-0}"
    printf 'TCP_RETRANS_BP=%q\n' "${CURRENT_RETRANS_BP:-0}"
    printf 'LISTEN_DROP_DELTA=%q\n' "${CURRENT_LISTEN_DROPS:-0}"
    printf 'QDISC_DROP_DELTA=%q\n' "${CURRENT_QDISC_DROPS:-0}"
    printf 'PRESSURE_SCORE=%q\n' "${CURRENT_PRESSURE_SCORE:-0}"
    printf 'MACHINE=%q\n' "${CPU_COUNT}c/${PHYSICAL_COUNT}p/${MEM_GB}G/${NUMA_COUNT}n/${RX_QUEUES}q/${NIC_DRIVER_NAME}"
    printf 'ACTIVE_BACKLOG=%q\n' "${ACTIVE_BACKLOG:-0}"
    printf 'ACTIVE_BUDGET=%q\n' "${ACTIVE_BUDGET:-0}"
    printf 'ACTIVE_BUDGET_USECS=%q\n' "${ACTIVE_BUDGET_USECS:-0}"
    printf 'COOLDOWN_REMAINING=%q\n' "${cooldown:-0}"
    printf 'UPDATED_AT=%q\n' "$(date +%F_%T)"
  } > "$tmp"
  mv -f "$tmp" "$STATE_FILE"
}

write_stable() {
  local level="$1" tmp="$STABLE_FILE.tmp.$$"
  {
    printf 'LEVEL=%q\n' "$level"
    printf 'STABLE_BACKLOG=%q\n' "${ACTIVE_BACKLOG:-0}"
    printf 'STABLE_BUDGET=%q\n' "${ACTIVE_BUDGET:-0}"
    printf 'STABLE_BUDGET_USECS=%q\n' "${ACTIVE_BUDGET_USECS:-0}"
    printf 'STABLE_WEIGHT=%q\n' "${ACTIVE_WEIGHT:-0}"
    printf 'STABLE_MACHINE=%q\n' "${CPU_COUNT}c/${PHYSICAL_COUNT}p/${MEM_GB}G/${NUMA_COUNT}n/${RX_QUEUES}q/${NIC_DRIVER_NAME}"
    printf 'SAVED_AT=%q\n' "$(date +%F_%T)"
  } > "$tmp"
  mv -f "$tmp" "$STABLE_FILE"
}

append_metric() {
  local reason="$1" tmp="$METRICS_LOG.tmp.$$"
  printf '%s level=%s pps=%s rx_bps=%s tx_bps=%s softirq=%s steal=%s drops=%s squeeze=%s udp_rx=%s udp_tx=%s retrans=%s retrans_bp=%s listen=%s qdisc=%s score=%s reason=%s\n' \
    "$(date +%F_%T)" "$CURRENT_LEVEL" "${CURRENT_PPS:-0}" "${CURRENT_RX_BPS:-0}" "${CURRENT_TX_BPS:-0}" "${CURRENT_SOFTIRQ:-0}" \
    "${CURRENT_STEAL:-0}" "${CURRENT_DROPS:-0}" "${CURRENT_SQUEEZE:-0}" \
    "${CURRENT_UDP_RCVBUF:-0}" "${CURRENT_UDP_SNDBUF:-0}" "${CURRENT_RETRANS:-0}" \
    "${CURRENT_RETRANS_BP:-0}" "${CURRENT_LISTEN_DROPS:-0}" "${CURRENT_QDISC_DROPS:-0}" \
    "${CURRENT_PRESSURE_SCORE:-0}" "$reason" >> "$METRICS_LOG"
  if [ "$(wc -l < "$METRICS_LOG" 2>/dev/null || echo 0)" -gt 2000 ]; then
    tail -n 2000 "$METRICS_LOG" > "$tmp" 2>/dev/null && mv -f "$tmp" "$METRICS_LOG"
  fi
  rm -f "$tmp"
}

clamp_value() {
  local value="$1" minimum="$2" maximum="$3"
  [ "$value" -lt "$minimum" ] && value="$minimum"
  [ "$value" -gt "$maximum" ] && value="$maximum"
  echo "$value"
}

calculate_level_parameters() {
  local level="$1" data_cpus memory_cap pps pps_per horizon slice candidate
  pps="${CURRENT_PPS:-0}"
  case "$pps" in ''|*[!0-9]*) pps=0 ;; esac
  data_cpus="$PHYSICAL_COUNT"
  [ "$RX_QUEUES" -lt "$data_cpus" ] && data_cpus="$RX_QUEUES"
  [ "$data_cpus" -gt 0 ] || data_cpus=1
  pps_per=$(( pps / data_cpus ))
  memory_cap=$(( MEM_GB * 1073741824 / 50 / data_cpus / 2048 ))
  memory_cap=$(clamp_value "$memory_cap" 32768 131072)

  case "$level" in
    0)
      horizon=4000; slice=250
      candidate=$(( pps_per * horizon / 1000000 ))
      ACTIVE_BACKLOG=$(clamp_value "$candidate" 8192 "$memory_cap")
      candidate=$(( pps_per * slice / 1000000 ))
      ACTIVE_BUDGET=$(clamp_value "$candidate" 300 600)
      ACTIVE_BUDGET_USECS=1500
      [ "$pps_per" -ge 150000 ] && ACTIVE_BUDGET_USECS=2000
      [ "$pps_per" -ge 400000 ] && ACTIVE_BUDGET_USECS=2500
      ACTIVE_WEIGHT=64; ACTIVE_COALESCE=2
      ACTIVE_BUDGET=$(clamp_value "$ACTIVE_BUDGET" 300 600)
      ACTIVE_BUDGET_USECS=$(clamp_value "$ACTIVE_BUDGET_USECS" 1500 3000)
      ;;
    2)
      horizon=32000; slice=1000
      candidate=$(( pps_per * horizon / 1000000 ))
      ACTIVE_BACKLOG=$(clamp_value "$candidate" 32768 "$memory_cap")
      candidate=$(( pps_per * slice / 1000000 ))
      ACTIVE_BUDGET=$(clamp_value "$candidate" 900 1800)
      ACTIVE_BUDGET_USECS=4000
      [ "$pps_per" -ge 150000 ] && ACTIVE_BUDGET_USECS=5000
      [ "$pps_per" -ge 400000 ] && ACTIVE_BUDGET_USECS=6000
      [ "$pps_per" -ge 800000 ] && ACTIVE_BUDGET_USECS=7000
      ACTIVE_WEIGHT=256
      if [ "$pps" -ge 200000 ]; then ACTIVE_COALESCE=12; else ACTIVE_COALESCE=8; fi
      ACTIVE_BUDGET_USECS=$(clamp_value "$ACTIVE_BUDGET_USECS" 4000 8000)
      ;;
    *)
      horizon=12000; slice=500
      candidate=$(( pps_per * horizon / 1000000 ))
      ACTIVE_BACKLOG=$(clamp_value "$candidate" 16384 "$memory_cap")
      candidate=$(( pps_per * slice / 1000000 ))
      ACTIVE_BUDGET=$(clamp_value "$candidate" 600 1100)
      ACTIVE_BUDGET_USECS=2500
      [ "$pps_per" -ge 150000 ] && ACTIVE_BUDGET_USECS=3000
      [ "$pps_per" -ge 400000 ] && ACTIVE_BUDGET_USECS=3500
      ACTIVE_WEIGHT=128; ACTIVE_COALESCE=6
      ACTIVE_BUDGET=$(clamp_value "$ACTIVE_BUDGET" 600 1100)
      ACTIVE_BUDGET_USECS=$(clamp_value "$ACTIVE_BUDGET_USECS" 2500 4500)
      ;;
  esac
}

apply_level() {
  local level="$1" reason="${2:-automatic}"
  case "$level" in 0|1|2) : ;; *) level=1 ;; esac
  calculate_level_parameters "$level"

  if ! apply_parameter_group; then
    write_state "${CURRENT_LEVEL:-$level}" actuator_rollback
    return 1
  fi
  # Coalescing is set once by the NIC calibration helper.  Keep it out of the
  # short control loop: a driver may silently clamp or reject ethtool writes,
  # and changing it without read-back would break the actuator transaction.
  write_state "$level" "$reason"
  CURRENT_LEVEL="$level"
}

apply_stable() {
  local level=1 machine="${CPU_COUNT}c/${PHYSICAL_COUNT}p/${MEM_GB}G/${NUMA_COUNT}n/${RX_QUEUES}q/${NIC_DRIVER_NAME}"
  if [ -f "$STABLE_FILE" ]; then
    source "$STABLE_FILE"
    level="${LEVEL:-1}"
  fi
  if [ "${STABLE_MACHINE:-}" = "$machine" ] && \
     [[ "${STABLE_BACKLOG:-}" =~ ^[0-9]+$ ]] && [[ "${STABLE_BUDGET:-}" =~ ^[0-9]+$ ]] && \
     [[ "${STABLE_BUDGET_USECS:-}" =~ ^[0-9]+$ ]] && [[ "${STABLE_WEIGHT:-}" =~ ^[0-9]+$ ]]; then
    ACTIVE_BACKLOG="$STABLE_BACKLOG"; ACTIVE_BUDGET="$STABLE_BUDGET"
    ACTIVE_BUDGET_USECS="$STABLE_BUDGET_USECS"; ACTIVE_WEIGHT="$STABLE_WEIGHT"
    if apply_parameter_group; then
      CURRENT_LEVEL="$level"
      write_state "$level" stable_rollback
      return 0
    fi
  fi
  apply_level "$level" stable_rollback
}

calibrate() {
  [ -x "$NIC_HELPER" ] && "$NIC_HELPER" >/dev/null 2>&1 || true
  apply_level 1 calibrated_balanced || return 1
  write_stable 1
}

controller_loop() {
  local prev_rx prev_tx prev_rx_bytes prev_tx_bytes prev_soft_drop prev_squeeze prev_driver prev_total prev_soft prev_steal prev_ts
  local prev_udp_in prev_udp_rcv prev_udp_snd prev_retrans prev_outsegs prev_listen prev_qdisc
  local now_rx now_tx now_rx_bytes now_tx_bytes now_soft_drop now_squeeze now_driver now_total now_soft now_steal now_ts
  local now_udp_in now_udp_rcv now_udp_snd now_retrans now_outsegs now_listen now_qdisc
  local elapsed d_total d_soft d_steal d_rx d_tx d_rx_bytes d_tx_bytes d_soft_drop d_squeeze d_driver
  local d_udp_in d_udp_rcv d_udp_snd d_udp_effective d_retrans d_outsegs d_listen d_qdisc
  local pressure=0 calm=0 stable=0 cooldown=0 warmup="$WARMUP_WINDOWS" reason
  local counter_reset=0 metric_invalid=0 cpu_sample_valid=0 path
  prev_rx=0; prev_tx=0; prev_rx_bytes=0; prev_tx_bytes=0
  prev_soft_drop=0; prev_squeeze=0; prev_driver=0; prev_total=0; prev_soft=0; prev_steal=0
  prev_udp_in=0; prev_udp_rcv=0; prev_udp_snd=0; prev_retrans=0; prev_outsegs=0
  prev_listen=0; prev_qdisc=0; prev_ts=0
  now_rx=0; now_tx=0; now_rx_bytes=0; now_tx_bytes=0
  now_soft_drop=0; now_squeeze=0; now_driver=0; now_total=0; now_soft=0; now_steal=0; now_ts=0
  now_udp_in=0; now_udp_rcv=0; now_udp_snd=0; now_retrans=0; now_outsegs=0; now_listen=0; now_qdisc=0
  CURRENT_LEVEL=1
  [ -f "$STATE_FILE" ] && source "$STATE_FILE" 2>/dev/null || true
  CURRENT_LEVEL="${LEVEL:-1}"
  cooldown="${COOLDOWN_REMAINING:-0}"
  case "$cooldown" in ''|*[!0-9]*) cooldown=0 ;; esac
  [ "$cooldown" -gt "$COOLDOWN_WINDOWS" ] && cooldown="$COOLDOWN_WINDOWS"

  read -r prev_soft_drop prev_squeeze < <(softnet_totals)
  read -r prev_total prev_soft prev_steal < <(cpu_totals)
  cpu_snapshot > "$CPU_PREV_FILE"
  prev_rx=$(read_counter "$SYS_ROOT/class/net/$DEV/statistics/rx_packets")
  prev_tx=$(read_counter "$SYS_ROOT/class/net/$DEV/statistics/tx_packets")
  prev_rx_bytes=$(read_counter "$SYS_ROOT/class/net/$DEV/statistics/rx_bytes")
  prev_tx_bytes=$(read_counter "$SYS_ROOT/class/net/$DEV/statistics/tx_bytes")
  prev_driver=$(driver_drops)
  read -r prev_udp_in prev_udp_rcv prev_udp_snd < <(udp_counters)
  read -r prev_retrans prev_outsegs < <(tcp_counters)
  prev_listen=$(tcp_listen_drops)
  prev_qdisc=$(qdisc_drops)
  prev_ts=$(monotonic_millis)
  apply_level "$CURRENT_LEVEL" controller_started || return 1

  while sleep "$INTERVAL"; do
    metric_invalid=0
    for path in \
      "$PROC_ROOT/stat" \
      "$PROC_ROOT/net/softnet_stat" \
      "$SYS_ROOT/class/net/$DEV/statistics/rx_packets" \
      "$SYS_ROOT/class/net/$DEV/statistics/tx_packets" \
      "$SYS_ROOT/class/net/$DEV/statistics/rx_bytes" \
      "$SYS_ROOT/class/net/$DEV/statistics/tx_bytes"; do
      [ -r "$path" ] || metric_invalid=1
    done
    read -r now_soft_drop now_squeeze < <(softnet_totals)
    read -r now_total now_soft now_steal < <(cpu_totals)
    cpu_snapshot > "$CPU_NOW_FILE"
    now_rx=$(read_counter "$SYS_ROOT/class/net/$DEV/statistics/rx_packets")
    now_tx=$(read_counter "$SYS_ROOT/class/net/$DEV/statistics/tx_packets")
    now_rx_bytes=$(read_counter "$SYS_ROOT/class/net/$DEV/statistics/rx_bytes")
    now_tx_bytes=$(read_counter "$SYS_ROOT/class/net/$DEV/statistics/tx_bytes")
    now_driver=$(driver_drops)
    read -r now_udp_in now_udp_rcv now_udp_snd < <(udp_counters)
    read -r now_retrans now_outsegs < <(tcp_counters)
    now_listen=$(tcp_listen_drops)
    now_qdisc=$(qdisc_drops)
    now_ts=$(monotonic_millis)
    elapsed=$(( now_ts - prev_ts )); [ "$elapsed" -gt 0 ] || elapsed=$(( INTERVAL * 1000 ))

    d_total=$(( now_total - prev_total ))
    d_soft=$(( now_soft - prev_soft ))
    d_steal=$(( now_steal - prev_steal ))
    counter_reset=0
    [ "$d_total" -lt 0 ] && counter_reset=1
    [ "$d_soft" -lt 0 ] && counter_reset=1
    [ "$d_steal" -lt 0 ] && counter_reset=1
    if [ "$d_total" -gt 0 ] && [ "$d_soft" -ge 0 ]; then
      CURRENT_SOFTIRQ=$(( d_soft * 100 / d_total ))
    else
      CURRENT_SOFTIRQ=0
    fi
    if [ "$d_total" -gt 0 ] && [ "$d_steal" -ge 0 ]; then
      CURRENT_STEAL=$(( d_steal * 100 / d_total ))
    else
      CURRENT_STEAL=0
    fi
    cpu_sample_valid=0
    read -r CURRENT_SOFTIRQ CURRENT_STEAL cpu_sample_valid < <(cpu_window_pressure "$CPU_PREV_FILE" "$CPU_NOW_FILE")
    mv -f "$CPU_NOW_FILE" "$CPU_PREV_FILE"
    [ "$cpu_sample_valid" = "1" ] || metric_invalid=1
    d_rx=$(( now_rx - prev_rx )); [ "$d_rx" -ge 0 ] || { d_rx=0; counter_reset=1; }
    d_tx=$(( now_tx - prev_tx )); [ "$d_tx" -ge 0 ] || { d_tx=0; counter_reset=1; }
    d_rx_bytes=$(( now_rx_bytes - prev_rx_bytes )); [ "$d_rx_bytes" -ge 0 ] || { d_rx_bytes=0; counter_reset=1; }
    d_tx_bytes=$(( now_tx_bytes - prev_tx_bytes )); [ "$d_tx_bytes" -ge 0 ] || { d_tx_bytes=0; counter_reset=1; }
    d_soft_drop=$(( now_soft_drop - prev_soft_drop )); [ "$d_soft_drop" -ge 0 ] || { d_soft_drop=0; counter_reset=1; }
    d_squeeze=$(( now_squeeze - prev_squeeze )); [ "$d_squeeze" -ge 0 ] || { d_squeeze=0; counter_reset=1; }
    d_driver=$(( now_driver - prev_driver )); [ "$d_driver" -ge 0 ] || { d_driver=0; counter_reset=1; }
    d_udp_in=$(( now_udp_in - prev_udp_in )); [ "$d_udp_in" -ge 0 ] || { d_udp_in=0; counter_reset=1; }
    d_udp_rcv=$(( now_udp_rcv - prev_udp_rcv )); [ "$d_udp_rcv" -ge 0 ] || { d_udp_rcv=0; counter_reset=1; }
    d_udp_snd=$(( now_udp_snd - prev_udp_snd )); [ "$d_udp_snd" -ge 0 ] || { d_udp_snd=0; counter_reset=1; }
    d_retrans=$(( now_retrans - prev_retrans )); [ "$d_retrans" -ge 0 ] || { d_retrans=0; counter_reset=1; }
    d_outsegs=$(( now_outsegs - prev_outsegs )); [ "$d_outsegs" -ge 0 ] || { d_outsegs=0; counter_reset=1; }
    d_listen=$(( now_listen - prev_listen )); [ "$d_listen" -ge 0 ] || { d_listen=0; counter_reset=1; }
    d_qdisc=$(( now_qdisc - prev_qdisc )); [ "$d_qdisc" -ge 0 ] || { d_qdisc=0; counter_reset=1; }
    d_udp_effective="$d_udp_in"
    [ "$d_udp_rcv" -gt "$d_udp_effective" ] && d_udp_effective="$d_udp_rcv"
    d_udp_effective=$(( d_udp_effective + d_udp_snd ))
    CURRENT_PPS=$(( (d_rx + d_tx) * 1000 / elapsed ))
    CURRENT_RX_BPS=$(( d_rx_bytes * 8000 / elapsed ))
    CURRENT_TX_BPS=$(( d_tx_bytes * 8000 / elapsed ))
    CURRENT_UDP_RCVBUF="$d_udp_rcv"
    CURRENT_UDP_SNDBUF="$d_udp_snd"
    CURRENT_RETRANS="$d_retrans"
    if [ "$d_outsegs" -gt 0 ]; then
      CURRENT_RETRANS_BP=$(( d_retrans * 10000 / d_outsegs ))
    elif [ "$d_retrans" -gt 0 ]; then
      # Retransmissions without a matching OutSegs sample are still a loss
      # signal; treating them as 0 would incorrectly permit a downshift.
      CURRENT_RETRANS_BP=10000
    else
      CURRENT_RETRANS_BP=0
    fi
    CURRENT_LISTEN_DROPS="$d_listen"
    CURRENT_QDISC_DROPS="$d_qdisc"
    CURRENT_DROPS=$(( d_soft_drop + d_driver + d_udp_effective + d_listen + d_qdisc ))
    CURRENT_SQUEEZE="$d_squeeze"
    CURRENT_PRESSURE_SCORE=0
    [ $(( d_soft_drop + d_driver )) -gt 0 ] && CURRENT_PRESSURE_SCORE=$(( CURRENT_PRESSURE_SCORE + 4 ))
    [ "$d_squeeze" -gt 0 ] && CURRENT_PRESSURE_SCORE=$(( CURRENT_PRESSURE_SCORE + 3 ))
    [ "$CURRENT_SOFTIRQ" -ge "$SOFTIRQ_HIGH" ] && CURRENT_PRESSURE_SCORE=$(( CURRENT_PRESSURE_SCORE + 3 ))

    prev_soft_drop="$now_soft_drop"; prev_squeeze="$now_squeeze"
    prev_total="$now_total"; prev_soft="$now_soft"; prev_steal="$now_steal"
    prev_rx="$now_rx"; prev_tx="$now_tx"; prev_driver="$now_driver"
    prev_rx_bytes="$now_rx_bytes"; prev_tx_bytes="$now_tx_bytes"; prev_ts="$now_ts"
    prev_udp_in="$now_udp_in"; prev_udp_rcv="$now_udp_rcv"; prev_udp_snd="$now_udp_snd"
    prev_retrans="$now_retrans"; prev_outsegs="$now_outsegs"
    prev_listen="$now_listen"; prev_qdisc="$now_qdisc"
    [ "$cooldown" -gt 0 ] && cooldown=$(( cooldown - 1 ))

    if [ -e "$PAUSE_FILE" ]; then
      write_state "$CURRENT_LEVEL" user_paused paused
      pressure=0; calm=0; stable=0
      continue
    fi

    if [ "$metric_invalid" -ne 0 ]; then
      pressure=0; calm=0; stable=0; warmup="$WARMUP_WINDOWS"
      write_state "$CURRENT_LEVEL" metrics_unavailable
      append_metric metrics_unavailable
      continue
    fi

    if [ "$counter_reset" -ne 0 ]; then
      pressure=0; calm=0; stable=0; warmup="$WARMUP_WINDOWS"
      write_state "$CURRENT_LEVEL" counter_reset
      append_metric counter_reset
      continue
    fi

    if [ "$warmup" -gt 0 ]; then
      warmup=$(( warmup - 1 ))
      pressure=0; calm=0; stable=0
      write_state "$CURRENT_LEVEL" learning_baseline
      append_metric learning_baseline
      continue
    fi

    if [ "$cooldown" -gt 0 ]; then
      pressure=0; calm=0; stable=0
      write_state "$CURRENT_LEVEL" cooldown_hold
      append_metric cooldown_hold
      continue
    fi

    reason=steady
    if [ "$CURRENT_STEAL" -ge "$STEAL_HIGH" ]; then
      pressure=0; calm=0; stable=0
      reason=host_steal_pressure
    elif [ "$CURRENT_PRESSURE_SCORE" -ge 3 ]; then
      pressure=$(( pressure + 1 )); calm=0; stable=0
      reason=pressure_detected
    elif [ "$d_udp_effective" -gt 0 ] || [ "$d_listen" -gt 0 ]; then
      pressure=0; calm=0; stable=0
      reason=application_socket_pressure
    elif [ "$d_qdisc" -gt 0 ]; then
      pressure=0; calm=0; stable=0
      reason=egress_queue_pressure
    elif [ "$CURRENT_RETRANS_BP" -ge 50 ]; then
      pressure=0; calm=0; stable=0
      reason=external_path_loss
    elif [ "$CURRENT_SOFTIRQ" -le "$SOFTIRQ_LOW" ]; then
      calm=$(( calm + 1 )); pressure=0; stable=$(( stable + 1 ))
      reason=latency_headroom
    else
      pressure=0; calm=0; stable=$(( stable + 1 ))
    fi

    if [ "$cooldown" -eq 0 ] && [ "$pressure" -ge "$UP_WINDOWS" ] && [ "$CURRENT_LEVEL" -lt 2 ]; then
      cooldown="$COOLDOWN_WINDOWS"
      if apply_level $(( CURRENT_LEVEL + 1 )) drop_or_softirq_pressure; then
        pressure=0; stable=0
      else
        reason=actuator_rollback; pressure=0; stable=0
      fi
    elif [ "$cooldown" -eq 0 ] && [ "$calm" -ge "$DOWN_WINDOWS" ] && [ "$CURRENT_LEVEL" -gt 0 ]; then
      cooldown="$COOLDOWN_WINDOWS"
      if apply_level $(( CURRENT_LEVEL - 1 )) lower_queue_latency; then
        calm=0; stable=0
      else
        reason=actuator_rollback; calm=0; stable=0
      fi
    else
      write_state "$CURRENT_LEVEL" "$reason"
    fi

    if [ "$stable" -ge "$DOWN_WINDOWS" ]; then
      write_stable "$CURRENT_LEVEL"
      stable=0
    fi
    append_metric "$reason"
  done
}

case "${1:-loop}" in
  loop) acquire_lock && controller_loop ;;
  calibrate) acquire_lock && calibrate ;;
  apply-stable) acquire_lock && apply_stable ;;
  level-0|level-1|level-2) acquire_lock && apply_level "${1#level-}" manual ;;
  status) [ -f "$STATE_FILE" ] && cat "$STATE_FILE" ;;
  *) echo "usage: $0 {loop|calibrate|apply-stable|level-0|level-1|level-2|status}"; exit 2 ;;
esac
EOF_AUTO
  chmod +x "$AUTO_HELPER"
}

build_auto_service() {
  cat > "$AUTO_SERVICE" <<EOF_AUTOSERVICE
[Unit]
Description=Live Relay Adaptive Network Controller
Wants=network-online.target
After=network-online.target live-relay-sysctl.service live-relay-nic-tuning.service

[Service]
Type=simple
EnvironmentFile=-$AUTO_ENV_FILE
ExecStart=$AUTO_HELPER loop
Restart=always
RestartSec=2
Nice=10
LimitNOFILE=1048576
TasksMax=infinity

[Install]
WantedBy=multi-user.target
EOF_AUTOSERVICE
}

write_auto_env() {
  local nic="$1" data_plane cpus physical mem_gb numa rxqs driver speed softirq_high softirq_low
  data_plane=$(detect_data_plane)
  cpus=$(online_cpu_count)
  physical=$(physical_core_count)
  case "$physical" in ''|*[!0-9]*|0) physical="$cpus" ;; esac
  mem_gb=$(mem_total_gb)
  numa=$(numa_node_count)
  rxqs=$(nic_rx_queue_count "$nic")
  driver=$(nic_driver_name "$nic")
  speed=$(nic_speed_mbps "$nic")
  # The controller compares these thresholds with the busiest CPU share.  Do
  # not divide them by CPU count; that would classify idle multicore hosts as
  # permanently saturated.
  softirq_high=70
  softirq_low=35
  cat > "$AUTO_ENV_FILE" <<EOF_AUTOENV
DEV=$nic
WORKDIR=$WORKDIR
DATA_PLANE=$data_plane
ONLINE_CPUS=$cpus
PHYSICAL_CORES=$physical
MEMORY_GB=$mem_gb
NUMA_NODES=$numa
RX_QUEUE_COUNT=$rxqs
NIC_DRIVER=${driver:-unknown}
NIC_SPEED_MBPS=${speed:-0}
AUTO_INTERVAL=${AUTO_INTERVAL:-10}
AUTO_UP_WINDOWS=${AUTO_UP_WINDOWS:-3}
AUTO_DOWN_WINDOWS=${AUTO_DOWN_WINDOWS:-12}
AUTO_COOLDOWN_WINDOWS=${AUTO_COOLDOWN_WINDOWS:-6}
AUTO_WARMUP_WINDOWS=${AUTO_WARMUP_WINDOWS:-3}
SOFTIRQ_HIGH=${SOFTIRQ_HIGH:-$softirq_high}
SOFTIRQ_LOW=${SOFTIRQ_LOW:-$softirq_low}
STEAL_HIGH=${STEAL_HIGH:-5}
EOF_AUTOENV
}

remove_hia_baseline() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now hia-baseline.service >/dev/null 2>&1 || true
  fi
  rm -f "$HIA_SERVICE" "$HIA_HELPER" "$HIA_SYSCTL_FILE"
}

install_auto_tuning() {
  local nic
  ensure_cmd ethtool
  ensure_cmd ip
  ensure_cmd tc
  ensure_cmd lscpu || true
  nic=$(select_nic_noninteractive || true)
  [ -n "$nic" ] || { err "未检测到可用网卡。"; return 1; }
  remove_hia_baseline
  capture_original_runtime "$nic"
  apply_performance_power_policy
  apply_profile 2
  write_auto_env "$nic"
  build_auto_controller
  build_auto_service
  rm -f "$PAUSE_FILE"
  "$AUTO_HELPER" calibrate
  persist_state auto "$nic"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload
    systemctl enable --now live-relay-auto-controller.service >/dev/null 2>&1
  else
    warn "未找到 systemd，已完成校准，但自动控制器不会常驻。"
  fi
  log "全自动调优已启动。"
}

apply_profile() {
  local mode="$1" cc nic
  remove_hia_baseline
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

  enable_sysctl_persistence
  apply_sysctl_file

  if [ "$mode" = "2" ]; then
    if is_container; then
      warn "检测到容器环境，模式 2 仅应用 sysctl / limits，跳过 NIC / IRQ / RPS / XPS / qdisc 调优。"
      nic=""
    else
      nic=$(select_nic_noninteractive || true)
      if [ -z "$nic" ]; then
        warn "无法自动检测网卡，跳过网卡调优。可通过 NIC=eth0 bash $0 2 指定。"
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
  local driver speed numa worker_target target_queues use_ht irq_policy busy_poll

  profile="unknown"
  saved_nic=""
  if [ -f "$STATE_FILE" ]; then
    # shellcheck disable=SC1090
    source "$STATE_FILE" || true
    profile="${PROFILE:-unknown}"
    saved_nic="${NIC:-}"
  fi

  if [ -f "$NIC_ENV_FILE" ]; then
    # shellcheck disable=SC1090
    source "$NIC_ENV_FILE" || true
    worker_target="${WORKER_CPUS_TARGET:-local}"
    target_queues="${TARGET_QUEUES:-auto}"
    use_ht="${USE_HT:-0}"
    irq_policy="${IRQBALANCE_POLICY:-auto}"
  else
    worker_target="n/a"
    target_queues="n/a"
    use_ht="n/a"
    irq_policy="n/a"
  fi

  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)
  qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || true)
  avail=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
  busy_poll=$(sysctl -n net.core.busy_poll 2>/dev/null || echo 0)
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
  printf '%-22s %s\n' "flow_limit_table_len:" "$(sysctl -n net.core.flow_limit_table_len 2>/dev/null || echo n/a)"
  printf '%-22s %s\n' "fs.file-max:" "$(sysctl -n fs.file-max 2>/dev/null || true)"
  printf '%-22s %s\n' "tcp_rmem:" "$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null || true)"
  printf '%-22s %s\n' "tcp_wmem:" "$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null || true)"
  printf '%-22s %s\n' "udp_mem:" "$(sysctl -n net.ipv4.udp_mem 2>/dev/null || echo n/a)"
  printf '%-22s %s\n' "udp_rmem_min:" "$(sysctl -n net.ipv4.udp_rmem_min 2>/dev/null || true)"
  printf '%-22s %s\n' "rps_sock_flow_entries:" "$(cat /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || echo 0)"
  printf '%-22s %s\n' "tcp_limit_output:" "$(sysctl -n net.ipv4.tcp_limit_output_bytes 2>/dev/null || true)"
  printf '%-22s %s\n' "tcp_notsent_lowat:" "$(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null || true)"
  printf '%-22s %s\n' "conntrack_count:" "$(sysctl -n net.netfilter.nf_conntrack_count 2>/dev/null || echo n/a)"
  printf '%-22s %s\n' "conntrack_max:" "$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo n/a)"
  printf '%-22s %s\n' "模式2 CPU策略:" "$worker_target"
  printf '%-22s %s\n' "模式2 队列策略:" "$target_queues"
  printf '%-22s %s\n' "模式2 使用HT:" "$use_ht"
  printf '%-22s %s\n' "IRQBalance策略:" "$irq_policy"
  if [ "${busy_poll:-0}" -gt 0 ] 2>/dev/null; then
    printf '%-22s %s\n' "Busy Poll:" "开启（${busy_poll} us）"
  else
    printf '%-22s %s\n' "Busy Poll:" "关闭（默认）"
  fi
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

    if ethtool -g "$nic" >/dev/null 2>&1; then
      local cur_rx cur_tx max_rx max_tx
      max_rx="$(ethtool -g "$nic" 2>/dev/null | awk '
        /Pre-set maximums:/ {sec=1; next}
        /Current hardware settings:/ {sec=0}
        sec && $1 == "RX:" {print $2; exit}
      ')"
      max_tx="$(ethtool -g "$nic" 2>/dev/null | awk '
        /Pre-set maximums:/ {sec=1; next}
        /Current hardware settings:/ {sec=0}
        sec && $1 == "TX:" {print $2; exit}
      ')"
      cur_rx="$(ethtool -g "$nic" 2>/dev/null | awk '
        /Current hardware settings:/ {sec=1; next}
        sec && $1 == "RX:" {print $2; exit}
      ')"
      cur_tx="$(ethtool -g "$nic" 2>/dev/null | awk '
        /Current hardware settings:/ {sec=1; next}
        sec && $1 == "TX:" {print $2; exit}
      ')"
      printf '%-22s %s\n' "ring 信息:" "rx ${cur_rx:-unknown}/${max_rx:-unknown}, tx ${cur_tx:-unknown}/${max_tx:-unknown}"
    fi

    if ethtool -c "$nic" >/dev/null 2>&1; then
      echo "coalesce:"
      ethtool -c "$nic" 2>/dev/null | awk -F': ' '
        /Adaptive RX:/ || /Adaptive TX:/ || /adaptive-rx:/ || /adaptive-tx:/ || /rx-usecs:/ || /tx-usecs:/ {
          gsub(/^[ \t]+/, "", $1)
          printf "  %-18s %s\n", $1 ":", $2
        }
      ' || true
    fi

    echo "网卡错误信息:"
    ethtool -S "$nic" 2>/dev/null | awk -F': ' '
      NF >= 2 {
        key=$1
        val=$2
        gsub(/^[ \t]+/, "", key)
        gsub(/^[ \t]+/, "", val)
        if (key ~ /rx_dropped$/ ||
            key ~ /rx_missed_errors$/ ||
            key ~ /rx_over_errors$/ ||
            key ~ /rx_no_buffer_count$/ ||
            key ~ /tx_errors$/) {
          printf "  %-26s %s\n", key ":", val
          found=1
        }
      }
      END {
        if (!found) print "  无明显错误计数"
      }
    ' || true

    echo "IRQ 分布:"
    {
      found_irq=0
      while read -r irq; do
        [ -n "$irq" ] || continue
        found_irq=1
        awk -v wanted="${irq}:" '$1 == wanted {
          sum=0
          for (i=2; i<=NF; i++) {if ($i ~ /^[0-9]+$/) sum += $i; else break}
          printf "  IRQ %-4s 总中断=%-12s 设备=%s\n", wanted, sum, $NF
        }' /proc/interrupts
      done < <(collect_nic_irqs "$nic" | awk '!seen[$0]++' | sort -n)
      [ "$found_irq" -eq 1 ] || echo "  未找到相关 IRQ"
    } || true

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
      done < <(collect_nic_irqs "$nic" | awk '!seen[$0]++' | sort -n)
      [ "$found_irq" -eq 1 ] || echo "  未找到相关 IRQ"
    } || true

    if command -v tc >/dev/null 2>&1; then
      echo "qdisc:"
      tc qdisc show dev "$nic" 2>/dev/null | sed 's/^/  /' || true
      printf '%-22s %s\n' "qdisc 拓扑:" "$(
        tc qdisc show dev "$nic" 2>/dev/null | awk '
          / root / {root=$2}
          / parent / {leaf++}
          / parent / && $2 == "fq" {fq++}
          END {
            if (leaf > 0) printf "mq leaves fq=%d/%d", fq+0, leaf+0
            else printf "root %s / single-queue", (root == "" ? "unknown" : root)
          }
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

show_auto_status() {
  local service_status="未安装" level="-" reason="-" pps="0" rx_bps="0" tx_bps="0"
  local softirq="0" steal="0" drops="0" updated="-" udp_rx="0" udp_tx="0"
  local retrans="0" retrans_bp="0" listen_drops="0" qdisc_drops="0" score="0"
  local machine="-" active_backlog="0" active_budget="0" active_usecs="0"
  local sys_applied="-" sys_normalized="-" sys_skipped="-" sys_failed="-"
  local data_plane="$(detect_data_plane)" nic="$(default_nic)" pause_status="运行中"
  if [ -f "$AUTO_ENV_FILE" ]; then
    # shellcheck disable=SC1090
    source "$AUTO_ENV_FILE" || true
    data_plane="${DATA_PLANE:-$data_plane}"
    nic="${DEV:-$nic}"
  fi
  if [ -f "$AUTO_STATE_FILE" ]; then
    # shellcheck disable=SC1090
    source "$AUTO_STATE_FILE" || true
    level="${LEVEL:-$level}"; reason="${REASON:-$reason}"; pps="${PPS:-$pps}"
    rx_bps="${RX_BPS:-$rx_bps}"; tx_bps="${TX_BPS:-$tx_bps}"
    softirq="${SOFTIRQ_PCT:-$softirq}"; steal="${STEAL_PCT:-$steal}"
    drops="${DROP_DELTA:-$drops}"; udp_rx="${UDP_RCVBUF_DELTA:-$udp_rx}"; udp_tx="${UDP_SNDBUF_DELTA:-$udp_tx}"
    retrans="${TCP_RETRANS_DELTA:-$retrans}"; retrans_bp="${TCP_RETRANS_BP:-$retrans_bp}"
    listen_drops="${LISTEN_DROP_DELTA:-$listen_drops}"; qdisc_drops="${QDISC_DROP_DELTA:-$qdisc_drops}"
    score="${PRESSURE_SCORE:-$score}"; machine="${MACHINE:-$machine}"
    active_backlog="${ACTIVE_BACKLOG:-$active_backlog}"; active_budget="${ACTIVE_BUDGET:-$active_budget}"
    active_usecs="${ACTIVE_BUDGET_USECS:-$active_usecs}"; updated="${UPDATED_AT:-$updated}"
  fi
  if [ -f "$SYSCTL_STATE_FILE" ]; then
    # shellcheck disable=SC1090
    source "$SYSCTL_STATE_FILE" || true
    sys_applied="${SYSCTL_APPLIED:-$sys_applied}"; sys_normalized="${SYSCTL_NORMALIZED:-$sys_normalized}"
    sys_skipped="${SYSCTL_SKIPPED:-$sys_skipped}"; sys_failed="${SYSCTL_FAILED:-$sys_failed}"
  fi
  [ -e "$PAUSE_FILE" ] && pause_status="已暂停"
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet live-relay-auto-controller.service 2>/dev/null; then
    service_status="active"
  elif [ -x "$AUTO_HELPER" ]; then
    service_status="inactive"
  fi

  case "$level" in
    0) level="0 / 低延迟" ;;
    1) level="1 / 平衡" ;;
    2) level="2 / 抗压" ;;
  esac
  case "$reason" in
    controller_started) reason="控制器启动" ;;
    calibrated_balanced) reason="校准完成" ;;
    pressure_detected) reason="检测到本机数据面压力" ;;
    drop_or_softirq_pressure) reason="本机压力持续，自动升档" ;;
    lower_queue_latency) reason="余量充足，自动降低排队" ;;
    latency_headroom) reason="延迟余量充足" ;;
    learning_baseline) reason="正在学习流量基线" ;;
    cooldown_hold) reason="冷却观察中，暂不重复调参" ;;
    host_steal_pressure) reason="宿主机 Steal 偏高，冻结调参" ;;
    application_socket_pressure) reason="应用 Socket 缓冲或监听压力" ;;
    egress_queue_pressure) reason="本机出口队列出现丢包" ;;
    external_path_loss) reason="检测到外部路径重传" ;;
    actuator_rollback) reason="参数校验失败，已自动回滚" ;;
    actuator_unsupported) reason="内核不支持动态参数，保持当前配置" ;;
    metrics_unavailable) reason="监控指标暂不可用，暂停调参" ;;
    counter_reset) reason="检测到计数器重置，跳过本窗口" ;;
    user_paused) reason="用户暂停" ;;
    stable_rollback) reason="已回退稳定版" ;;
    steady) reason="运行稳定" ;;
  esac

  echo
  echo "================ V4 自适应状态 ================"
  printf '%-20s %s\n' "控制器:" "$service_status / $pause_status"
  printf '%-20s %s\n' "数据面:" "$data_plane"
  printf '%-20s %s\n' "网卡:" "${nic:-unknown}"
  printf '%-20s %s\n' "硬件模型:" "$machine"
  printf '%-20s %s\n' "当前档位:" "$level"
  printf '%-20s %s\n' "调优原因:" "$reason"
  printf '%-20s %s\n' "当前 PPS:" "$pps"
  printf '%-20s %s / %s\n' "RX/TX bps:" "$rx_bps" "$tx_bps"
  printf '%-20s %s%% / %s%%\n' "最忙核 SoftIRQ/Steal:" "$softirq" "$steal"
  printf '%-20s %s\n' "窗口丢包增量:" "$drops"
  printf '%-20s %s / %s\n' "UDP 缓冲错误:" "$udp_rx" "$udp_tx"
  printf '%-20s %s / %s bp\n' "TCP 重传:" "$retrans" "$retrans_bp"
  printf '%-20s %s / %s\n' "监听/qdisc丢包:" "$listen_drops" "$qdisc_drops"
  printf '%-20s %s\n' "本机压力分:" "$score"
  printf '%-20s %s / %s / %sus\n' "backlog/budget:" "$active_backlog" "$active_budget" "$active_usecs"
  printf '%-20s %s/%s/%s/%s\n' "sysctl A/N/S/F:" "$sys_applied" "$sys_normalized" "$sys_skipped" "$sys_failed"
  printf '%-20s %s\n' "更新时间:" "$updated"
  echo "================================================"
  echo
}

redetect_environment() {
  local nic old_nic=""
  nic=$(select_nic_noninteractive || true)
  [ -n "$nic" ] || { err "未检测到可用网卡。"; return 1; }
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop live-relay-auto-controller.service >/dev/null 2>&1 || true
  fi
  if [ -f "$SNAPSHOT_DIR/runtime.env" ]; then
    # A NIC switch must not reuse the previous device's restoration snapshot.
    # Restore the old device first, then capture a clean baseline for the new one.
    # shellcheck disable=SC1090
    source "$SNAPSHOT_DIR/runtime.env" || true
    old_nic="${ORIGINAL_NIC:-}"
    if [ -n "$old_nic" ] && [ "$old_nic" != "$nic" ]; then
      restore_original_runtime
      rm -rf "$SNAPSHOT_DIR"
    fi
  fi
  capture_original_runtime "$nic"
  setup_mode2_persistence "$nic"
  write_auto_env "$nic"
  build_auto_controller
  if command -v systemctl >/dev/null 2>&1; then
    systemctl start live-relay-auto-controller.service >/dev/null 2>&1 || true
  fi
  log "已重新检测：$(detect_data_plane) / $nic"
}

calibrate_now() {
  [ -x "$AUTO_HELPER" ] || { err "自动控制器尚未安装。"; return 1; }
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop live-relay-auto-controller.service >/dev/null 2>&1 || true
  fi
  "$AUTO_HELPER" calibrate
  if command -v systemctl >/dev/null 2>&1; then
    systemctl start live-relay-auto-controller.service >/dev/null 2>&1 || true
  fi
  log "立即校准已完成。"
}

toggle_auto_tuning() {
  if [ -e "$PAUSE_FILE" ]; then
    rm -f "$PAUSE_FILE"
    log "自动调优已继续。"
  else
    touch "$PAUSE_FILE"
    log "自动调优已暂停，当前参数保持不变。"
  fi
}

rollback_stable() {
  [ -x "$AUTO_HELPER" ] || { err "自动控制器尚未安装。"; return 1; }
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop live-relay-auto-controller.service >/dev/null 2>&1 || true
  fi
  "$AUTO_HELPER" apply-stable
  if command -v systemctl >/dev/null 2>&1; then
    systemctl start live-relay-auto-controller.service >/dev/null 2>&1 || true
  fi
  log "已恢复上一个稳定配置。"
}

show_diagnostics() {
  show_auto_status
  show_status
  if [ -f "$METRICS_LOG" ]; then
    echo "最近调优记录："
    tail -n 20 "$METRICS_LOG"
    echo
  fi
}

write_hia_profile() {
  cat > "$HIA_SYSCTL_FILE" <<'EOF_HIA'
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
net.ipv4.ip_local_port_range = 1024 65535
fs.file-max = 16777216
vm.swappiness = 10
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
# ===== End HIA =====
EOF_HIA
}

build_hia_service() {
  cat > "$HIA_HELPER" <<EOF_HIA_HELPER
#!/usr/bin/env bash
set -u
modprobe tcp_bbr >/dev/null 2>&1 || true
while IFS= read -r line || [ -n "\$line" ]; do
  case "\$line" in ''|'#'*) continue ;; esac
  key="\${line%%=*}"
  value="\${line#*=}"
  key="\$(printf '%s' "\$key" | tr -d '[:space:]')"
  value="\$(printf '%s' "\$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*\$//')"
  path="/proc/sys/\${key//.//}"
  [ -e "\$path" ] && sysctl -q -w "\$key=\$value" >/dev/null 2>&1 || true
done < "$HIA_SYSCTL_FILE"
DEV="\$(ip -o route show to default 2>/dev/null | awk '{print \$5; exit}')"
[ -n "\$DEV" ] && command -v tc >/dev/null 2>&1 && tc qdisc replace dev "\$DEV" root fq >/dev/null 2>&1 || true
EOF_HIA_HELPER
  chmod +x "$HIA_HELPER"

  cat > "$HIA_SERVICE" <<EOF_HIA_SERVICE
[Unit]
Description=Apply designated HIA baseline
After=systemd-sysctl.service
Before=network.target

[Service]
Type=oneshot
ExecStart=$HIA_HELPER
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_HIA_SERVICE
}

verify_hia_profile() {
  local line key expected actual applied=0 failed=0 skipped=0 path
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    key="${line%%=*}"
    expected="${line#*=}"
    key=$(printf '%s' "$key" | tr -d '[:space:]')
    expected=$(printf '%s' "$expected" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    path=$(sysctl_proc_path "$key")
    if [ ! -e "$path" ]; then
      skipped=$(( skipped + 1 ))
      continue
    fi
    actual=$(sysctl -n "$key" 2>/dev/null | xargs || true)
    if [ "$actual" = "$expected" ]; then
      applied=$(( applied + 1 ))
    else
      failed=$(( failed + 1 ))
      warn "HIA 校验未匹配：$key 期望=$expected 实际=${actual:-unknown}"
    fi
  done < "$HIA_SYSCTL_FILE"
  printf 'HIA 校验：成功=%s，失败=%s，不支持=%s\n' "$applied" "$failed" "$skipped"
  [ "$failed" -eq 0 ]
}

cleanup_live_relay() {
  local hia_verified=0
  info "正在卸载自适应调优并回退指定 HIA..."
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now live-relay-auto-controller.service >/dev/null 2>&1 || true
  fi

  restore_original_runtime
  remove_mode2_service
  remove_sysctl_persistence
  rm -f "$AUTO_SERVICE" "$AUTO_HELPER" "$AUTO_ENV_FILE" \
        "$LIMITS_FILE" "$SYSTEMD_LIMIT_FILE" "$SYSCTL_FILE" "$SYSCTL_LOG"

  write_hia_profile
  build_hia_service
  "$HIA_HELPER"

  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable --now hia-baseline.service >/dev/null 2>&1 || true
    systemctl daemon-reexec >/dev/null 2>&1 || true
  fi
  if verify_hia_profile; then
    hia_verified=1
  fi
  rm -rf "$WORKDIR"
  if [ "$hia_verified" -eq 1 ]; then
    log "调优器已卸载，指定 HIA 已应用并持久化。"
  else
    err "调优器已卸载，但部分 HIA 参数未通过校验。"
    return 1
  fi
}

show_menu() {
  local status="未安装" data_plane="$(detect_data_plane)" pause_label="暂停调优"
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet live-relay-auto-controller.service 2>/dev/null; then
    status="运行中"
  elif [ -x "$AUTO_HELPER" ]; then
    status="已停止"
  fi
  [ -e "$PAUSE_FILE" ] && { status="已暂停"; pause_label="继续调优"; }
  clear || true
  cat <<EOF_MENU
========================================================
 Live Relay 高级自适应调优
========================================================
 状态：$status | 数据面：$data_plane
--------------------------------------------------------
 1) 自动调优
 2) 运行状态
 3) 重新检测
 4) 立即校准
 5) $pause_label
 6) 回退稳定版
 7) 高级诊断
 8) 卸载并回退 HIA
 0) 退出
========================================================
EOF_MENU
}

main() {
  need_root
  ensure_base_dirs
  ensure_cmd modprobe || true

  local choice="${1:-}"
  case "$choice" in
    1|auto|install|start)
      install_auto_tuning
      return 0
      ;;
    2|status)
      show_auto_status
      return 0
      ;;
    3|detect)
      redetect_environment
      return 0
      ;;
    4|calibrate)
      calibrate_now
      return 0
      ;;
    5|pause|resume|toggle)
      toggle_auto_tuning
      return 0
      ;;
    6|rollback)
      rollback_stable
      return 0
      ;;
    7|diag|diagnostics)
      show_diagnostics
      return 0
      ;;
    8|cleanup|remove|hia)
      cleanup_live_relay
      return 0
      ;;
    stable) apply_profile 1; return 0 ;;
    hyper) apply_profile 2; return 0 ;;
    "")
      ;;
    *)
      warn "未知参数：$choice"
      ;;
  esac

  while true; do
    show_menu
    read -r -p "请选择 [0-8]：" choice
    case "$choice" in
      1)
        install_auto_tuning
        break
        ;;
      2)
        show_auto_status
        read -r -p "按回车键继续..." _tmp
        ;;
      3)
        redetect_environment
        read -r -p "按回车键继续..." _tmp
        ;;
      4)
        calibrate_now
        read -r -p "按回车键继续..." _tmp
        ;;
      5)
        toggle_auto_tuning
        sleep 1
        ;;
      6)
        rollback_stable
        read -r -p "按回车键继续..." _tmp
        ;;
      7)
        show_diagnostics
        read -r -p "按回车键继续..." _tmp
        ;;
      8)
        read -r -p "输入 HIA 确认卸载并回退：" _confirm
        [ "$_confirm" = "HIA" ] || { warn "已取消。"; sleep 1; continue; }
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
