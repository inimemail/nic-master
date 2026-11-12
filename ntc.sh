#!/usr/bin/env bash
set -euo pipefail

VERSION="5.0.2-compatible-status"
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
SYSCTL_STATE_FILE="$WORKDIR/sysctl-state.env"
PAUSE_FILE="$WORKDIR/paused"
SNAPSHOT_DIR="$WORKDIR/original"
METRICS_LOG="$WORKDIR/metrics.log"
SYSCTL_LOG="$WORKDIR/sysctl.log"
DIAG_HELPER="/usr/local/sbin/live-relay-diagnostics.sh"

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
  [ "$(uname -s)" = Linux ] || { err "此脚本仅支持 Linux。"; exit 1; }
  (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )) || { err "需要 Bash 4.4 或更新版本。"; exit 1; }
  command bash -c '(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) ))' || { err "PATH 中的 bash 也需要 4.4 或更新版本，尚未修改配置。"; exit 1; }
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    err "请使用 root 权限运行。"
    exit 1
  fi
}

ensure_base_dirs() {
  [ ! -L "$WORKDIR" ] && [ ! -L "$SNAPSHOT_DIR" ] || { err "状态目录不能是符号链接。"; return 1; }
  mkdir -p "$WORKDIR" "$SNAPSHOT_DIR" "$SYSCTL_DIR" || return 1
  [ "$(stat -c %u "$WORKDIR")" = "${EUID:-$(id -u)}" ] || { err "状态目录不属于当前管理员。"; return 1; }
  chmod 0700 "$WORKDIR" "$SNAPSHOT_DIR" || return 1
}

is_container() {
  local root="${ROOTFS_ROOT:-/}" proc="${PROC_ROOT:-/proc}"
  [ -f "${root%/}/.dockerenv" ] || [ -f "${root%/}/run/.containerenv" ] || [ -f "${root%/}/run/systemd/container" ] && return 0
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    systemd-detect-virt --quiet --container >/dev/null 2>&1 && return 0
  fi
  grep -qaE 'docker|lxc|container|kubepods|openvz' "$proc/1/cgroup" 2>/dev/null ||
    grep -qaE '(^|[[:cntrl:]])container=' "$proc/1/environ" 2>/dev/null
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
    lscpu|flock) pkg_apt="util-linux"; pkg_rpm="util-linux"; pkg_pac="util-linux"; pkg_zypper="util-linux" ;;
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
  echo "${PROC_ROOT:-/proc}/sys/${1//.//}"
}

# Some vendor/physical-host kernels expose netdev_budget_usecs but reject
# writes to it, retaining the kernel-selected value. Treat that as a
# capability difference rather than a failed tuning transaction.
is_kernel_retained_sysctl() {
  local key="$1" actual="${2:-}"
  [ "$key" = "net.core.netdev_budget_usecs" ] || return 1
  [[ "$actual" =~ ^[0-9]+$ ]]
}

append_if_supported() {
  local key="$1" value="$2" path
  path=$(sysctl_proc_path "$key")
  if [ -e "$path" ] && [ -w "$path" ]; then
    printf '%s = %s\n' "$key" "$value" >> "$SYSCTL_FILE"
  fi
}

append_at_least_supported() {
  local key="$1" requested="$2" current
  case "$requested" in ''|*[!0-9]*) return 1 ;; esac
  current=$(sysctl -n "$key" 2>/dev/null || true)
  case "$current" in
    ''|*[!0-9]*) ;;
    *) [ "$current" -le "$requested" ] || requested="$current" ;;
  esac
  append_if_supported "$key" "$requested"
}

mem_total_kb() {
  local value limit path
  value=$(awk '/MemTotal:/ {print $2; exit}' "${PROC_ROOT:-/proc}/meminfo" 2>/dev/null || true)
  case "$value" in ''|*[!0-9]*) value=1048576 ;; esac
  while IFS= read -r path; do
    [ -r "$path" ] || continue
    read -r limit < "$path" || continue
    case "$limit" in ''|*[!0-9]*) continue ;; esac
    # v1 represents unlimited memory with a very large sentinel.
    [ "${#limit}" -le 16 ] || continue
    [ "$limit" -gt 0 ] && [ $(( limit / 1024 )) -lt "$value" ] && value=$(( limit / 1024 ))
  done < <(cgroup_resource_files memory)
  [ "$value" -gt 0 ] || value=1024
  echo "$value"
}

mem_total_gb() {
  local kb
  kb=$(mem_total_kb)
  echo $(( (kb + 1048575) / 1048576 ))
}

# Resolve the process cgroup and its ancestors, not just the mount root.
# PROC_ROOT/CGROUP_ROOT also make resource accounting testable off-host.
cgroup_resource_files() {
  local kind="$1" root="${CGROUP_ROOT:-/sys/fs/cgroup}" rel="" controller dir leaf
  if [ -r "$root/cgroup.controllers" ]; then
    rel=$(awk -F: '$1 == "0" {print $3; exit}' "${PROC_ROOT:-/proc}/self/cgroup" 2>/dev/null || true)
    case "$kind" in memory) leaf=memory.max ;; cpu) leaf=cpu.max ;; esac
    case "$rel" in *..*) rel="" ;; esac
    dir="$root${rel%/}"
  else
    case "$kind" in memory) controller=memory; leaf=memory.limit_in_bytes ;; cpu) controller=cpu; leaf=cpu.cfs_quota_us ;; esac
    rel=$(awk -F: -v c="$controller" 'index("," $2 ",", "," c ",") {print $3; exit}' "${PROC_ROOT:-/proc}/self/cgroup" 2>/dev/null || true)
    case "$rel" in *..*) rel="" ;; esac
    root="$root/$controller"
    [ -d "$root" ] || { [ "$controller" = cpu ] && root="${CGROUP_ROOT:-/sys/fs/cgroup}/cpu,cpuacct"; }
    dir="$root${rel%/}"
  fi
  while [ -n "$dir" ]; do
    printf '%s/%s\n' "$dir" "$leaf"
    [ "$dir" != "$root" ] || break
    case "$dir" in "$root"/*) dir="${dir%/*}" ;; *) break ;; esac
  done
}

online_cpu_count() {
  local n allowed quota period count path
  n=$(getconf _NPROCESSORS_ONLN 2>/dev/null || nproc 2>/dev/null || echo 1)
  case "$n" in ''|*[!0-9]*) n=1 ;; esac
  allowed=$(awk '/^Cpus_allowed_list:/ {n=split($2,a,","); for(i=1;i<=n;i++){m=split(a[i],b,"-"); c+=(m==2?b[2]-b[1]+1:1)} print c; exit}' "${PROC_ROOT:-/proc}/self/status" 2>/dev/null || true)
  case "$allowed" in ''|*[!0-9]*) ;; *) [ "$allowed" -gt 0 ] && [ "$allowed" -lt "$n" ] && n="$allowed" ;; esac
  while IFS= read -r path; do
    [ -r "$path" ] || continue
    if [[ "$path" == */cpu.max ]]; then
      read -r quota period < "$path" || continue
    else
      read -r quota < "$path" || continue
      read -r period < "${path%/*}/cpu.cfs_period_us" || continue
    fi
    case "$quota:$period" in *[!0-9:]*|:*) continue ;; esac
    [ "$period" -gt 0 ] && [ "$quota" -gt 0 ] || continue
    count=$(( (quota + period - 1) / period ))
    [ "$count" -lt "$n" ] && n="$count"
  done < <(cgroup_resource_files cpu)
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
  local DEV="$1" PROC_ROOT="${PROC_ROOT:-/proc}" SYS_ROOT="${SYS_ROOT:-/sys}"
  local path irq found=0
  # A PCI device's MSI IRQ directory is authoritative when available. Do not
  # add unrelated interfaces selected by an action-label substring.
  for path in "$SYS_ROOT/class/net/$DEV/device/msi_irqs/"*; do
    [ -e "$path" ] || continue
    irq="${path##*/}"
    case "$irq" in ''|*[!0-9]*) continue ;; esac
    printf '%s\n' "$irq"; found=1
  done
  [ "$found" = 0 ] || return 0
  awk -v dev="$DEV" '
    function belongs(action, pos, before, tail, offset) {
      offset=1
      while((pos=index(substr(action,offset),dev))>0) {
        pos+=offset-1
        before=(pos==1?" ":substr(action,pos-1,1))
        tail=substr(action,pos+length(dev))
        if(before ~ /[[:space:],\/@]/ &&
          (tail=="" || tail ~ /^[[:space:],:]/ ||
           tolower(tail) ~ /^[-_.](txrx|tx-rx|rx|tx|input|output|comp|queue|block)([-_.]?[0-9]|[[:space:],]|$)/)) return 1
        offset=pos+length(dev)
      }
      return 0
    }
    belongs($0) {irq=$1;sub(/:$/,"",irq);if(irq~/^[0-9]+$/)print irq}
  ' "$PROC_ROOT/interrupts" 2>/dev/null || true
}

calc_socket_buffer_max() {
  local kb value
  kb=$(mem_total_kb)
  value=$(( kb * 1024 / 32 ))
  [ "$value" -gt 268435456 ] && value=268435456
  [ "$value" -lt 4194304 ] && value=4194304
  echo "$value"
}

calc_socket_buffer_default() {
  local kb value
  kb=$(mem_total_kb)
  value=$(( kb * 1024 / 4096 ))
  [ "$value" -lt 262144 ] && value=262144
  [ "$value" -gt 2097152 ] && value=2097152
  echo "$value"
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

  warn "当前内核不支持 BBR，回退到当前拥塞控制算法：$current" >&2
  echo "$current"
}

effective_nofile_limit() {
  local limit=1048576 maximum
  maximum=$(cat "${PROC_ROOT:-/proc}/sys/fs/nr_open" 2>/dev/null || true)
  case "$maximum" in ''|*[!0-9]*) ;; *) [ "$maximum" -ge "$limit" ] || limit="$maximum" ;; esac
  printf '%s\n' "$limit"
}

write_limits() {
  local limit temporary
  limit=$(effective_nofile_limit)
  mkdir -p "$(dirname "$LIMITS_FILE")" "$SYSTEMD_LIMIT_DIR" || return 1
  temporary="$LIMITS_FILE.tmp.$$"
  printf '* soft nofile %s\n* hard nofile %s\nroot soft nofile %s\nroot hard nofile %s\n' "$limit" "$limit" "$limit" "$limit" > "$temporary" || return 1
  mv -f "$temporary" "$LIMITS_FILE" || return 1
  temporary="$SYSTEMD_LIMIT_FILE.tmp.$$"
  printf '[Manager]\nDefaultLimitNOFILE=%s\n' "$limit" > "$temporary" || return 1
  mv -f "$temporary" "$SYSTEMD_LIMIT_FILE" || return 1
  # Do not re-exec PID 1 or remove global process/task limits for network tuning.
  ulimit -SHn "$limit" 2>/dev/null || true
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
  local kb page_size pages maximum pressure minimum
  kb=$(mem_total_kb)
  page_size=$(getconf PAGE_SIZE 2>/dev/null || echo 4096)
  case "$page_size" in ''|*[!0-9]*|0) page_size=4096 ;; esac
  pages=$(( kb * 1024 / page_size ))
  # Budget the UDP protocol pool separately from each socket's ceiling.
  # Actual allocation remains demand-driven; these are accounting thresholds.
  maximum=$(( pages / 16 ))
  [ "$maximum" -le $(( 2147483648 / page_size )) ] || maximum=$(( 2147483648 / page_size ))
  [ "$maximum" -gt 0 ] || maximum=1
  pressure=$(( maximum * 3 / 4 ))
  minimum=$(( maximum / 2 ))
  echo "$minimum $pressure $maximum"
}

calc_flow_limit_enabled() {
  case "${ENABLE_FLOW_LIMIT:-auto}" in
    0|off|no|false) echo 0 ;;
    *) echo 1 ;;
  esac
}

calc_netdev_backlog() {
  local speed="$1" cpus="$2" kb cap base=8192
  kb=$(mem_total_kb)
  case "$cpus" in ''|*[!0-9]*|0) cpus=1 ;; esac
  case "$speed" in ''|*[!0-9]*) ;; *) [ "$speed" -ge 10000 ] && base=16384 ;; esac
  # Estimate 4 KiB per queued skb and allow for every allowed CPU backlog.
  # A minimum must never override this estimate's memory ceiling.
  cap=$(( kb * 1024 / 50 / cpus / 4096 ))
  [ "$cap" -gt 65536 ] && cap=65536
  [ "$cap" -gt 0 ] || cap=1
  [ "$base" -le "$cap" ] || base="$cap"
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

calc_tcp_max_tw_buckets() {
  local mem_gb cpus override mem_target cpu_target target floor
  override="${TCP_MAX_TW_BUCKETS:-}"
  case "$override" in
    ''|*[!0-9]*) ;;
    *)
      [ "$override" -ge 32768 ] || override=32768
      [ "$override" -le 1048576 ] || override=1048576
      echo "$override"
      return 0
      ;;
  esac

  mem_gb=$(mem_total_gb)
  cpus=$(online_cpu_count)
  case "$cpus" in ''|*[!0-9]*) cpus=1 ;; esac
  # Budget roughly 12K TIME_WAIT entries per GB and 16K per online CPU, then
  # use the tighter side.  This yields 16K-granular tiers without letting a
  # high core count outrun the host's memory budget.
  mem_target=$(( mem_gb * 12288 ))
  cpu_target=$(( cpus * 16384 ))
  if [ "$mem_target" -lt "$cpu_target" ]; then
    target="$mem_target"
  else
    target="$cpu_target"
  fi

  if [ "$mem_gb" -ge 4 ] || [ "$cpus" -ge 4 ]; then
    floor=65536
  else
    floor=32768
  fi
  [ "$target" -ge "$floor" ] || target="$floor"
  [ "$target" -le 1048576 ] || target=1048576
  target=$(( (target + 16383) / 16384 * 16384 ))
  [ "$target" -le 1048576 ] || target=1048576
  echo "$target"
}

calc_tcp_notsent_lowat() {
  local value="${TCP_NOTSENT_LOWAT:-131072}"
  case "$value" in ''|*[!0-9]*) value=131072 ;; esac
  [ "$value" -ge 16384 ] || value=16384
  [ "$value" -le 524288 ] || value=524288
  echo "$value"
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
  local cc="$1" lowat
  lowat=$(calc_tcp_notsent_lowat)
  append_if_supported net.core.default_qdisc fq || return 1
  append_if_supported net.ipv4.tcp_congestion_control "$cc" || return 1

  append_if_supported net.ipv4.tcp_mtu_probing 1 || return 1
  append_if_supported net.ipv4.tcp_slow_start_after_idle 0 || return 1
  append_if_supported net.ipv4.tcp_notsent_lowat "$lowat" || return 1
  append_if_supported net.ipv4.tcp_fastopen 3 || return 1
  append_if_supported net.ipv4.ip_local_port_range "10000 65535" || return 1

  append_if_supported net.ipv4.tcp_fin_timeout 10 || return 1
  append_if_supported net.ipv4.tcp_keepalive_time 300 || return 1
  append_if_supported net.ipv4.tcp_keepalive_intvl 30 || return 1
  append_if_supported net.ipv4.tcp_keepalive_probes 5 || return 1

  if [ "${ENABLE_BUSY_POLL:-0}" = "1" ]; then
    append_if_supported net.core.busy_read 50 || return 1
    append_if_supported net.core.busy_poll 50 || return 1
  else
    append_if_supported net.core.busy_read 0 || return 1
    append_if_supported net.core.busy_poll 0 || return 1
  fi

  # Network tuning does not change the global VM overcommit/swap policy.
}

append_hyper_sysctls() {
  local speed cpus somax backlog budget budget_usecs filemax flow_table_len udp_mem mem_gb socket_max socket_default tw_buckets
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
  socket_default=$(calc_socket_buffer_default)
  tw_buckets=$(calc_tcp_max_tw_buckets)

  append_if_supported net.core.somaxconn "$somax" || return 1
  # Keep SYN backlog coupled to the machine-sized listen queue; do not force
  # 262144 on small hosts where the extra SYN_RECV memory is counterproductive.
  append_if_supported net.ipv4.tcp_max_syn_backlog "$somax" || return 1
  case "${ENABLE_TCP_TW_REUSE:-1}" in
    1|on|yes|true) append_if_supported net.ipv4.tcp_tw_reuse 1 ;;
  esac
  append_if_supported net.ipv4.tcp_max_tw_buckets "$tw_buckets" || return 1
  append_if_supported net.core.netdev_max_backlog "$backlog" || return 1
  append_if_supported net.core.netdev_budget "$budget" || return 1
  append_if_supported net.core.netdev_budget_usecs "$budget_usecs" || return 1
  append_if_supported net.core.dev_weight 768 || return 1
  append_if_supported net.core.dev_weight_rx_bias 1 || return 1
  append_if_supported net.core.dev_weight_tx_bias 1 || return 1
  append_if_supported net.core.flow_limit_table_len "$flow_table_len" || return 1

  append_at_least_supported fs.file-max "$filemax" || return 1

  append_if_supported net.core.rmem_max "$socket_max" || return 1
  append_if_supported net.core.wmem_max "$socket_max" || return 1
  append_if_supported net.core.rmem_default "$socket_default" || return 1
  append_if_supported net.core.wmem_default "$socket_default" || return 1
  append_if_supported net.core.optmem_max 262144 || return 1

  append_if_supported net.ipv4.tcp_rmem "4096 $socket_default $socket_max" || return 1
  append_if_supported net.ipv4.tcp_wmem "4096 $socket_default $socket_max" || return 1
  append_if_supported net.ipv4.udp_mem "$udp_mem" || return 1
  append_if_supported net.ipv4.udp_rmem_min 131072 || return 1

  append_if_supported net.ipv4.tcp_limit_output_bytes 524288 || return 1


}

conntrack_sysctl_path() {
  printf '%s/sys/net/netfilter/nf_conntrack_max\n' "${PROC_ROOT:-/proc}"
}

ensure_conntrack_available() {
  local path pm kernel package
  path=$(conntrack_sysctl_path)
  [ -e "$path" ] && return 0

  ensure_cmd modprobe || true
  if command -v modprobe >/dev/null 2>&1; then
    modprobe nf_conntrack >/dev/null 2>&1 || true
  fi
  if [ -e "$path" ]; then
    log "conntrack 内核模块已加载。"
    return 0
  fi

  if is_container; then
    warn "容器无法加载宿主机 conntrack 模块，跳过连接跟踪调优。"
    return 1
  fi

  pm=$(detect_pm)
  kernel=$(uname -r)
  package=""
  case "$pm" in
    apt) package="linux-modules-extra-${kernel}" ;;
    dnf|yum) package="kernel-modules-extra-${kernel}" ;;
    zypper) package="kernel-default-extra" ;;
  esac

  if [ -n "$package" ]; then
    info "conntrack 模块缺失，正在安装 ${package}..."
    install_packages "$pm" "$package" || true
    command -v depmod >/dev/null 2>&1 && depmod -a "$kernel" >/dev/null 2>&1 || true
    command -v modprobe >/dev/null 2>&1 && modprobe nf_conntrack >/dev/null 2>&1 || true
  fi

  if [ -e "$path" ]; then
    log "conntrack 内核支持已安装并加载。"
    return 0
  fi

  warn "当前内核未提供可加载的 nf_conntrack 模块，连接跟踪调优已跳过。"
  return 1
}

append_conntrack_sysctls() {
  local mode="${1:-auto}" buckets ct_max current key value
  case "${ENABLE_CONNTRACK_TUNING:-auto}" in
    0|off|no|false) return 0 ;;
    auto|'') [ -e "$(conntrack_sysctl_path)" ] || return 0 ;;
    1|on|yes|true) ensure_conntrack_available || return 0 ;;
    *) return 1 ;;
  esac
  buckets=$(calc_conntrack_buckets)
  ct_max=$(calc_conntrack_max "$mode")
  current=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo 0)
  case "$current" in ''|*[!0-9]*) current=0 ;; esac
  [ "$current" -le "$ct_max" ] || ct_max="$current"
  append_at_least_supported net.netfilter.nf_conntrack_buckets "$buckets" || return 1
  append_if_supported net.netfilter.nf_conntrack_max "$ct_max" || return 1
  # Keep kernel/operator timeout policy unless a specific override is supplied.
  # Reclaiming idle entries aggressively is not a throughput optimization.
  for key in tcp_timeout_established tcp_timeout_unacknowledged udp_timeout udp_timeout_stream; do
    case "$key" in
      tcp_timeout_established) value="${CONNTRACK_TCP_ESTABLISHED:-}" ;;
      tcp_timeout_unacknowledged) value="${CONNTRACK_TCP_UNACKNOWLEDGED:-}" ;;
      udp_timeout) value="${CONNTRACK_UDP_TIMEOUT:-}" ;;
      udp_timeout_stream) value="${CONNTRACK_UDP_STREAM_TIMEOUT:-}" ;;
    esac
    case "$value" in ''|*[!0-9]*|0) continue ;; esac
    append_if_supported "net.netfilter.nf_conntrack_$key" "$value" || return 1
  done
}

write_profile_2() {
  local cc="$1" target="$SYSCTL_FILE" temporary
  temporary=$(mktemp "$SYSCTL_FILE.build.XXXXXX") || return 1
  if ! write_profile_2_to "$temporary" "$cc"; then rm -f "$temporary"; return 1; fi
  chmod 0644 "$temporary" || { rm -f "$temporary"; return 1; }
  mv -f "$temporary" "$target" || return 1
}

write_profile_2_to() {
  local SYSCTL_FILE="$1" cc="$2"
  begin_sysctl_file "VPS / 独服低延迟与吞吐调优" || return 1
  append_common_sysctls "$cc" || return 1
  append_hyper_sysctls || return 1
  append_conntrack_sysctls hyper || return 1
}

read_sysctl_original() {
  local key="$1" path="$2" raw=""
  if raw=$(sysctl -n "$key" 2>> "$SYSCTL_PREFLIGHT_LOG") && [ -n "$raw" ]; then
    printf '%s\n' "$raw"; return 0
  fi
  # procps/vendor sysctl can reject a key which is readable through procfs.
  if raw=$(cat "$path" 2>> "$SYSCTL_PREFLIGHT_LOG") && [ -n "$raw" ]; then
    printf 'FALLBACK %s source=procfs\n' "$key" >> "$SYSCTL_PREFLIGHT_LOG" || return 1
    printf '%s\n' "$raw"; return 0
  fi
  return 1
}

capture_sysctl_values() {
  local profile="$1" destination="$2" prepared="${3:-$2.profile}" line key value path
  local temporary journal_tmp selected=0 skipped=0 number=0
  SYSCTL_PREFLIGHT_LOG="${SYSCTL_PREFLIGHT_LOG:-$destination.log}"
  SYSCTL_PREFLIGHT_SKIPPED=0
  : > "$SYSCTL_PREFLIGHT_LOG" || { err "无法写入预检日志：$SYSCTL_PREFLIGHT_LOG"; return 1; }
  : > "$destination" || { err "无法创建 sysctl 原值备份：$destination"; return 1; }
  temporary=$(mktemp "$prepared.prepare.XXXXXX") || { err "无法创建待应用配置：$prepared"; return 1; }
  journal_tmp=$(mktemp "$destination.prepare.XXXXXX") || { rm -f "$temporary"; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    number=$((number + 1)); line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in ''|'#'*|';'*) printf '%s\n' "$line" >> "$temporary" || return 1; continue ;; esac
    key="${line%%=*}"; key="${key//[[:space:]]/}"
    if [[ "$line" != *=* ]] || ! [[ "$key" =~ ^[a-zA-Z0-9_.]+$ ]]; then
      printf 'FAILED line=%s reason=invalid-profile-line\n' "$number" >> "$SYSCTL_PREFLIGHT_LOG"
      err "sysctl 配置第 $number 行格式无效；详情：$SYSCTL_PREFLIGHT_LOG"
      rm -f "$temporary" "$journal_tmp"; return 1
    fi
    path=$(sysctl_proc_path "$key")
    value=""
    if [ ! -e "$path" ] || [ ! -w "$path" ]; then
      printf 'SKIPPED %s reason=unsupported-or-read-only\n' "$key" >> "$SYSCTL_PREFLIGHT_LOG" || return 1
    elif value=$(read_sysctl_original "$key" "$path") && [ -n "$value" ] && [[ "$value" != *$'\n'* ]]; then
      value=$(printf '%s\n' "$value" | awk '{$1=$1;print}') || return 1
      if [ -n "$value" ]; then
        printf '%s\t%s\n' "$key" "$value" >> "$journal_tmp" || return 1
        printf '%s\n' "$line" >> "$temporary" || return 1
        selected=$((selected + 1)); continue
      fi
      printf 'SKIPPED %s reason=empty-original\n' "$key" >> "$SYSCTL_PREFLIGHT_LOG" || return 1
    else
      printf 'SKIPPED %s reason=original-unreadable-or-invalid\n' "$key" >> "$SYSCTL_PREFLIGHT_LOG" || return 1
    fi
    skipped=$((skipped + 1))
    printf '# SKIPPED %s: no readable/writable restorable original\n' "$key" >> "$temporary" || return 1
    warn "跳过 $key：无法确认可读、可写的原值，本项不调整。"
  done < "$profile"
  if [ "$selected" = 0 ]; then
    printf 'FAILED reason=no-restorable-parameters\n' >> "$SYSCTL_PREFLIGHT_LOG"
    err "没有可安全调整的 sysctl 参数；详情：$SYSCTL_PREFLIGHT_LOG"
    rm -f "$temporary" "$journal_tmp"; return 1
  fi
  mv -f "$journal_tmp" "$destination" || return 1
  mv -f "$temporary" "$prepared" || return 1
  SYSCTL_PREFLIGHT_SKIPPED="$skipped"
  printf 'PREPARED selected=%s skipped=%s journal=%s profile=%s\n' "$selected" "$skipped" "$destination" "$prepared" >> "$SYSCTL_PREFLIGHT_LOG" || return 1
}

restore_sysctl_values() {
  local journal="$1" line key value actual i failed=0
  local SYSCTL_PREFLIGHT_LOG="${SYSCTL_PREFLIGHT_LOG:-$journal.log}"
  local -a records=()
  [ -r "$journal" ] || return 1
  mapfile -t records < "$journal"
  for ((i=${#records[@]}-1;i>=0;i--)); do
    line="${records[$i]}"; key="${line%%$'\t'*}"; value="${line#*$'\t'}"
    [[ "$key" =~ ^[a-zA-Z0-9_.]+$ ]] && [ "$key" != "$line" ] || { failed=1; continue; }
    actual=$(read_sysctl_original "$key" "$(sysctl_proc_path "$key")" | awk '{$1=$1;print}') || actual=""
    [ "$actual" != "$value" ] || continue
    sysctl -q -w "$key=$value" >/dev/null 2>&1 || true
    actual=$(read_sysctl_original "$key" "$(sysctl_proc_path "$key")" | awk '{$1=$1;print}') || actual=""
    [ "$actual" = "$value" ] || failed=1
  done
  return "$failed"
}

apply_sysctl_file() {
  local journal="${SYSCTL_TRANSACTION_JOURNAL:-$WORKDIR/sysctl-before.env}"
  local requested="$journal.requested.conf" prepared="$journal.selected.conf"
  local SYSCTL_PREFLIGHT_LOG="$journal.log"
  cp -p "$SYSCTL_FILE" "$requested" || { err "无法保存待应用配置：$requested"; return 1; }
  capture_sysctl_values "$requested" "$journal" "$prepared" || {
    err "sysctl 预检未通过，未应用参数；详情：$SYSCTL_PREFLIGHT_LOG"; return 1;
  }
  # Persist exactly the subset whose previous values were safely captured.
  local temporary
  temporary=$(mktemp "$SYSCTL_FILE.apply.XXXXXX") || return 1
  cp "$prepared" "$temporary" && chmod 0644 "$temporary" && mv -f "$temporary" "$SYSCTL_FILE" || { rm -f "$temporary"; return 1; }
  if apply_sysctl_file_impl; then return 0; fi
  if restore_sysctl_values "$journal"; then
    warn "sysctl 配置未完整通过，已恢复应用前的参数。"
  else
    err "部分 sysctl 恢复未确认，原值记录保留在 $journal。"
  fi
  return 1
}

apply_sysctl_file_impl() {
  : > "$SYSCTL_LOG"
  local line key value expected actual path
  local applied=0 normalized=0 skipped="${SYSCTL_PREFLIGHT_SKIPPED:-0}" failed=0 stack_failed=0
  # Apply only our profile; replaying unrelated sysctl files can disrupt services.
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
      actual=$(read_sysctl_original "$key" "$path" | awk '{$1=$1; print}' || true)
      if is_kernel_retained_sysctl "$key" "$actual"; then
        printf 'SKIPPED %s requested=%s actual=%s reason=kernel-rejected-retained\n' \
          "$key" "$value" "$actual" >> "$SYSCTL_LOG"
        skipped=$(( skipped + 1 ))
      else
        printf 'FAILED %s requested=%s reason=write-error\n' "$key" "$value" >> "$SYSCTL_LOG"
        failed=$(( failed + 1 ))
      fi
      continue
    fi
    expected=$(printf '%s\n' "$value" | awk '{$1=$1; print}')
    actual=$(read_sysctl_original "$key" "$path" | awk '{$1=$1; print}' || true)
    if [ "$actual" = "$expected" ]; then
      applied=$(( applied + 1 ))
    elif is_kernel_retained_sysctl "$key" "$actual"; then
      printf 'SKIPPED %s requested=%s actual=%s reason=kernel-retained-value\n' \
        "$key" "$expected" "$actual" >> "$SYSCTL_LOG"
      skipped=$(( skipped + 1 ))
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
  local key path
  [ ! -L "$SYSCTL_HELPER" ] && [ ! -L "$SYSCTL_SERVICE" ] || return 1
  mkdir -p "$(dirname "$SYSCTL_HELPER")" "$(dirname "$SYSCTL_SERVICE")" || return 1
  {
    printf '#!/usr/bin/env bash\n'
    printf '%s\n' '(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )) || { echo "Bash 4.4 or newer is required; no settings were changed." >&2; exit 1; }'
    printf 'set -u\numask 077\n'
    printf 'SYSCTL_FILE=${SYSCTL_FILE:-%q}\n' "$SYSCTL_FILE"
    printf 'WORKDIR=${WORKDIR:-%q}\n' "$WORKDIR"
    cat <<'EOF_SYSCTL_HELPER'
PROC_ROOT="${PROC_ROOT:-/proc}"
[ -r "$SYSCTL_FILE" ] || exit 0
[ ! -L "$WORKDIR" ] || { echo 'Refusing symlinked sysctl state directory.' >&2; exit 1; }
mkdir -p "$WORKDIR" || exit 1
owner=$(stat -c %u "$WORKDIR" 2>/dev/null || stat -f %u "$WORKDIR" 2>/dev/null || true)
[ "$owner" = "${EUID:-$(id -u)}" ] || { echo 'Sysctl state directory has another owner.' >&2; exit 1; }
chmod 0700 "$WORKDIR" || exit 1
command -v flock >/dev/null 2>&1 || { echo 'flock is required; no boot sysctls were changed.' >&2; exit 1; }
exec 9> "$WORKDIR/configuration.lock" || exit 1
flock -n 9 || { echo 'Configuration is in progress; no boot sysctls were changed.' >&2; exit 1; }
PENDING_FILE="$WORKDIR/sysctl-boot-pending"
TRANSACTION_DIR=""; TRANSACTION_ACTIVE=0
KEYS=(); VALUES=(); ORIGINALS=(); WRITTEN=()
normalize() { awk '{$1=$1;print}'; }
read_value() {
  local raw=""
  if ! raw=$(sysctl -n "$1" 2>/dev/null) || [ -z "$raw" ]; then
    raw=$(cat "$PROC_ROOT/sys/${1//.//}" 2>/dev/null) || return 1
  fi
  [ -n "$raw" ] && [[ "$raw" != *$'\n'* ]] || return 1
  printf '%s\n' "$raw" | normalize
}
is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
retained_budget() {
  [ "$1" = net.core.netdev_budget_usecs ] && is_uint "$2"
}
conntrack_aligned() {
  [ "$1" = net.netfilter.nf_conntrack_buckets ] && is_uint "$2" && is_uint "$3" && [ "$3" -gt 0 ]
}
log_event() {
  [ -n "$TRANSACTION_DIR" ] || return 0
  printf '%s\n' "$*" >> "$TRANSACTION_DIR/events.log"
}
restore_journal() {
  local directory="$1" journal="$1/before.tsv" entry key value actual i failed=0
  local -a records=() restore_keys=() restore_values=()
  [ -f "$journal" ] && [ ! -L "$journal" ] || return 1
  mapfile -t records < "$journal" || return 1
  # Validate the entire journal before any restoration write.
  for entry in "${records[@]}"; do
    key="${entry%%$'\t'*}"; value="${entry#*$'\t'}"
    [[ "$key" =~ ^[A-Za-z0-9_.]+$ ]] && [ "$entry" != "$key" ] && [ -n "$value" ] || return 1
    restore_keys+=("$key"); restore_values+=("$value")
  done
  for ((i=${#restore_keys[@]}-1;i>=0;i--)); do
    key="${restore_keys[$i]}"; value="${restore_values[$i]}"
    actual=$(read_value "$key") || actual=""
    [ "$actual" != "$value" ] || continue
    sysctl -q -w "$key=$value" >> "$directory/events.log" 2>&1 || true
    actual=$(read_value "$key") || actual=""
    if [ "$actual" != "$value" ]; then
      printf 'RESTORE_FAILED %s expected=%s actual=%s\n' "$key" "$value" "${actual:-unknown}" >> "$directory/events.log"
      failed=1
    fi
  done
  return "$failed"
}
clear_pending() {
  local recorded=""
  [ ! -r "$PENDING_FILE" ] || IFS= read -r recorded < "$PENDING_FILE" || true
  [ "$recorded" != "$TRANSACTION_DIR" ] || rm -f "$PENDING_FILE"
}
abort_transaction() {
  local reason="$1"
  TRANSACTION_ACTIVE=0
  log_event "FAILED reason=$reason"
  if restore_journal "$TRANSACTION_DIR"; then
    printf 'restored\n' > "$TRANSACTION_DIR/status"
    clear_pending || return 1
    echo "Boot sysctl apply failed; previous values restored. Journal: $TRANSACTION_DIR" >&2
  else
    printf 'restore_failed\n' > "$TRANSACTION_DIR/status"
    echo "Boot sysctl rollback requires attention. Journal: $TRANSACTION_DIR" >&2
  fi
  return 1
}
finish_on_exit() {
  local result=$?
  trap - EXIT INT TERM
  if [ "$TRANSACTION_ACTIVE" = 1 ]; then abort_transaction interrupted || true; result=1; fi
  exit "$result"
}
trap finish_on_exit EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

# Recover a previously interrupted write before creating a new baseline.
if [ -e "$PENDING_FILE" ] || [ -L "$PENDING_FILE" ]; then
  [ -f "$PENDING_FILE" ] && [ ! -L "$PENDING_FILE" ] || exit 1
  IFS= read -r recovery < "$PENDING_FILE" || exit 1
  case "$recovery" in "$WORKDIR"/sysctl-boot.*) ;; *) echo 'Invalid pending sysctl journal.' >&2; exit 1 ;; esac
  [ "${recovery%/*}" = "$WORKDIR" ] && [ -d "$recovery" ] && [ ! -L "$recovery" ] || exit 1
  TRANSACTION_DIR="$recovery"
  if ! restore_journal "$recovery"; then
    printf 'restore_failed\n' > "$recovery/status"
    echo "Pending boot sysctl recovery failed; no new profile applied. Journal: $recovery" >&2
    exit 1
  fi
  printf 'recovered\n' > "$recovery/status"
  rm -f "$PENDING_FILE" || exit 1
fi

# Prepare every readable, writable key before ANY write to the live kernel.
TRANSACTION_DIR=$(mktemp -d "$WORKDIR/sysctl-boot.XXXXXX") || exit 1
chmod 0700 "$TRANSACTION_DIR" || exit 1
journal_tmp="$TRANSACTION_DIR/before.tmp"
profile_tmp="$TRANSACTION_DIR/profile.tmp"
: > "$journal_tmp" && : > "$profile_tmp" || exit 1
while IFS= read -r line || [ -n "$line" ]; do
  line="${line#"${line%%[![:space:]]*}"}"
  case "$line" in ''|'#'*|';'*) continue ;; esac
  case "$line" in *=*) ;; *) log_event 'PREPARE_FAILED invalid_profile_line'; exit 1 ;; esac
  key="${line%%=*}"; value="${line#*=}"
  key="${key//[[:space:]]/}"
  value=$(printf '%s\n' "$value" | normalize)
  [[ "$key" =~ ^[A-Za-z0-9_.]+$ ]] && [ -n "$value" ] || { log_event 'PREPARE_FAILED invalid_key_or_value'; exit 1; }
  path="$PROC_ROOT/sys/${key//.//}"
  if [ ! -e "$path" ] || [ ! -r "$path" ] || [ ! -w "$path" ]; then log_event "SKIPPED $key unsupported-or-readonly"; continue; fi
  original=$(read_value "$key") || { log_event "PREPARE_FAILED $key unreadable"; exit 1; }
  [ -n "$original" ] || { log_event "PREPARE_FAILED $key empty"; exit 1; }
  case "$original$value" in *$'\n'*|*$'\t'*) log_event "PREPARE_FAILED $key multiline"; exit 1 ;; esac
  KEYS+=("$key"); VALUES+=("$value"); ORIGINALS+=("$original")
  printf '%s\t%s\n' "$key" "$original" >> "$journal_tmp" || exit 1
  printf '%s\t%s\n' "$key" "$value" >> "$profile_tmp" || exit 1
done < "$SYSCTL_FILE"
mv -f "$journal_tmp" "$TRANSACTION_DIR/before.tsv" || exit 1
mv -f "$profile_tmp" "$TRANSACTION_DIR/profile.tsv" || exit 1
printf 'prepared\n' > "$TRANSACTION_DIR/status" || exit 1
pending_tmp=$(mktemp "$WORKDIR/.sysctl-boot-pending.XXXXXX") || exit 1
printf '%s\n' "$TRANSACTION_DIR" > "$pending_tmp" && mv -f "$pending_tmp" "$PENDING_FILE" || { rm -f "$pending_tmp"; exit 1; }
TRANSACTION_ACTIVE=1
for ((index=0;index<${#KEYS[@]};index++)); do
  key="${KEYS[$index]}"; value="${VALUES[$index]}"; original="${ORIGINALS[$index]}"
  # Profiles can contain a later override of an earlier key. Compare live
  # state here; its preflight original may no longer be the current value.
  actual=$(read_value "$key") || { abort_transaction "read-before-write:$key"; exit 1; }
  [ "$actual" != "$value" ] || { log_event "UNCHANGED $key"; continue; }
  if ! sysctl -q -w "$key=$value" >> "$TRANSACTION_DIR/events.log" 2>&1; then
    actual=$(read_value "$key") || actual=""
    if retained_budget "$key" "$actual"; then log_event "RETAINED $key requested=$value actual=$actual"; continue; fi
    abort_transaction "write:$key"; exit 1
  fi
  actual=$(read_value "$key") || actual=""
  if [ "$actual" = "$value" ]; then log_event "APPLIED $key"
  elif retained_budget "$key" "$actual"; then log_event "RETAINED $key requested=$value actual=$actual"
  elif conntrack_aligned "$key" "$value" "$actual"; then log_event "NORMALIZED $key requested=$value actual=$actual"
  else abort_transaction "verify:$key"; exit 1; fi
done
printf 'applied\n' > "$TRANSACTION_DIR/status" || { abort_transaction status_write; exit 1; }
TRANSACTION_ACTIVE=0
clear_pending || exit 1
# Retain a single success journal. Failure journals and pending recovery remain.
previous_success=""
[ ! -r "$WORKDIR/sysctl-boot-last-success" ] || IFS= read -r previous_success < "$WORKDIR/sysctl-boot-last-success" || true
success_tmp=$(mktemp "$WORKDIR/.sysctl-boot-success.XXXXXX") || exit 1
printf '%s\n' "$TRANSACTION_DIR" > "$success_tmp" && mv -f "$success_tmp" "$WORKDIR/sysctl-boot-last-success" || { rm -f "$success_tmp"; exit 1; }
case "$previous_success" in "$WORKDIR"/sysctl-boot.*)
  if [ "$previous_success" != "$TRANSACTION_DIR" ] && [ "${previous_success%/*}" = "$WORKDIR" ] && [ -f "$previous_success/status" ] && [ "$(cat "$previous_success/status")" = applied ]; then rm -rf "$previous_success"; fi ;;
esac
exit 0
EOF_SYSCTL_HELPER
  } > "$SYSCTL_HELPER" || return 1
  chmod 0755 "$SYSCTL_HELPER" || return 1
  cat > "$SYSCTL_SERVICE" <<EOF_SYSCTL_SERVICE || return 1
[Unit]
Description=Apply Live Relay sysctl profile transactionally after system defaults
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
  build_sysctl_persistence || return 1
  if command -v systemctl >/dev/null 2>&1 && systemctl show-environment >/dev/null 2>&1; then
    systemctl daemon-reload || return 1
    systemctl enable live-relay-sysctl.service >/dev/null 2>&1 || return 1
  fi
  return 0
}

remove_sysctl_persistence() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now live-relay-sysctl.service >/dev/null 2>&1 || true
  fi
  rm -f "$SYSCTL_SERVICE" "$SYSCTL_HELPER"
}

persist_state() {
  local temporary="$STATE_FILE.tmp.$$"
  mkdir -p "$WORKDIR" || return 1
  printf 'PROFILE=%q\nNIC=%q\nUPDATED_AT=%q\n' "$1" "${2:-}" "$(date +%F_%T)" > "$temporary" || return 1
  mv -f "$temporary" "$STATE_FILE"
}

remove_mode2_service() {
  local marker unit
  if [ -x "$DIAG_HELPER" ]; then
    for marker in "$WORKDIR"/application-adapters/*.service/original.marker; do
      [ -f "$marker" ] || continue
      unit="${marker%/original.marker}"; unit="${unit##*/}"
      ENABLE_APP_ADAPTER=1 WORKDIR="$WORKDIR" "$DIAG_HELPER" adapter-restore "$unit" || return 1
    done
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now live-relay-nic-tuning.service >/dev/null 2>&1 || true
  fi
  rm -f "$NIC_SERVICE" "$NIC_HELPER" "$NIC_ENV_FILE" "$DIAG_HELPER"
}

build_nic_helper() {
  cat > "$NIC_HELPER" <<'EOF_HELPER' || return 1
#!/usr/bin/env bash
(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )) || { echo "Bash 4.4 or newer is required; no settings were changed." >&2; exit 1; }
set -euo pipefail

NIC_ENV_FILE="${NIC_ENV_FILE:-/etc/live-relay-nic.env}"
[ -f "$NIC_ENV_FILE" ] || { echo "缺少 $NIC_ENV_FILE"; exit 1; }
# shellcheck disable=SC1090
source "$NIC_ENV_FILE"

PROC_ROOT="${PROC_ROOT:-/proc}"
SYS_ROOT="${SYS_ROOT:-/sys}"
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

_allowed_cpu_spec() {
  local allowed online cpu
  allowed=$(awk '/^Cpus_allowed_list:/ {print $2; exit}' "$PROC_ROOT/self/status" 2>/dev/null || true)
  online=$(cat "$SYS_ROOT/devices/system/cpu/online" 2>/dev/null || true)
  [ -n "$allowed" ] || allowed="$online"
  [ -n "$online" ] || online="$allowed"
  [ -n "$allowed" ] || return 0
  awk -v allowed="$allowed" -v online="$online" '
    function expand(spec, set, n, part, b, i, c) {
      n=split(spec,part,",")
      for(i=1;i<=n;i++) {
        if(part[i] ~ /^[0-9]+-[0-9]+$/) {
          split(part[i],b,"-")
          for(c=b[1];c<=b[2];c++) set[c]=1
        } else if(part[i] ~ /^[0-9]+$/) set[part[i]+0]=1
      }
    }
    BEGIN {
      expand(allowed,a); expand(online,o)
      for(c in a) if(c in o) print c
    }' | sort -n | awk 'BEGIN {sep=""} {printf "%s%s",sep,$1; sep=","} END {print ""}'
}

_cpu_is_allowed() {
  local spec
  spec=",${ALLOWED_CPU_SPEC:-$(_allowed_cpu_spec)},"
  case "$spec" in *",$1,"*) return 0 ;; *) return 1 ;; esac
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
  if [ -r "$SYS_ROOT/class/net/$DEV/device/numa_node" ]; then
    cat "$SYS_ROOT/class/net/$DEV/device/numa_node"
  else
    echo -1
  fi
}

_get_nic_local_cpulist() {
  if [ -r "$SYS_ROOT/class/net/$DEV/device/local_cpulist" ]; then
    cat "$SYS_ROOT/class/net/$DEV/device/local_cpulist"
  else
    echo ""
  fi
}

_nic_irq_candidates() {
  local path irq found=0
  # A PCI device's MSI IRQ directory is authoritative when available. Do not
  # add unrelated interfaces selected by an action-label substring.
  for path in "$SYS_ROOT/class/net/$DEV/device/msi_irqs/"*; do
    [ -e "$path" ] || continue
    irq="${path##*/}"
    case "$irq" in ''|*[!0-9]*) continue ;; esac
    printf '%s\n' "$irq"; found=1
  done
  [ "$found" = 0 ] || return 0
  awk -v dev="$DEV" '
    function belongs(action, pos, before, tail, offset) {
      offset=1
      while((pos=index(substr(action,offset),dev))>0) {
        pos+=offset-1
        before=(pos==1?" ":substr(action,pos-1,1))
        tail=substr(action,pos+length(dev))
        if(before ~ /[[:space:],\/@]/ &&
          (tail=="" || tail ~ /^[[:space:],:]/ ||
           tolower(tail) ~ /^[-_.](txrx|tx-rx|rx|tx|input|output|comp|queue|block)([-_.]?[0-9]|[[:space:],]|$)/)) return 1
        offset=pos+length(dev)
      }
      return 0
    }
    belongs($0) {irq=$1;sub(/:$/,"",irq);if(irq~/^[0-9]+$/)print irq}
  ' "$PROC_ROOT/interrupts" 2>/dev/null || true
}

_get_nic_irq_cpu_hint() {
  local irq affinity first_cpu
  while read -r irq; do
    case "$irq" in ''|*[!0-9]*) continue ;; esac
    affinity=$(cat "$PROC_ROOT/irq/$irq/effective_affinity_list" 2>/dev/null || cat "$PROC_ROOT/irq/$irq/smp_affinity_list" 2>/dev/null || true)
    [ -n "$affinity" ] || continue
    first_cpu=""
    read -r first_cpu < <(_expand_cpulist "$affinity") || true
    [ -n "$first_cpu" ] || continue
    printf '%s\n' "$first_cpu"
    return 0
  done < <(_nic_irq_candidates)
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
  local nic_node local_cpus use_ht allowed_cpus
  nic_node=$(_resolve_nic_numa_node)
  local_cpus=$(_get_nic_local_cpulist)
  use_ht="${USE_HT:-0}"
  allowed_cpus="${ALLOWED_CPU_SPEC:-$(_allowed_cpu_spec)}"
  [ -n "$allowed_cpus" ] || return 1

  if command -v lscpu >/dev/null 2>&1 && lscpu -p=CPU,CORE,SOCKET,NODE,ONLINE >/dev/null 2>&1; then
    lscpu -p=CPU,CORE,SOCKET,NODE,ONLINE | awk -F, -v want_node="$nic_node" -v local_cpus="$local_cpus" -v use_ht="$use_ht" -v allowed_cpus="$allowed_cpus" '
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
      !/^#/ && ($5 == "Y" || $5 == "1") && cpu_in_list($1, allowed_cpus) {
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
  [ -n "$fallback_cpus" ] || fallback_cpus="$(cat "$SYS_ROOT"/devices/system/cpu/online)"
  _expand_cpulist "$fallback_cpus" | while read -r cpu; do
    _cpu_is_allowed "$cpu" && printf "LOCAL_PRIMARY %s\n" "$cpu" || true
  done
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

  local -a allowed_workers=() allowed_primary=()
  for cpu in "${WORKER_CPUS[@]}"; do
    _cpu_is_allowed "$cpu" && allowed_workers+=("$cpu") || true
  done
  for cpu in "${WORKER_PRIMARY_CPUS[@]}"; do
    _cpu_is_allowed "$cpu" && allowed_primary+=("$cpu") || true
  done
  WORKER_CPUS=("${allowed_workers[@]}")
  WORKER_PRIMARY_CPUS=("${allowed_primary[@]}")

  if [ "${#WORKER_CPUS[@]}" -eq 0 ]; then
    mapfile -t WORKER_CPUS < <(_expand_cpulist "${ALLOWED_CPU_SPEC:-$(_allowed_cpu_spec)}")
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
    target_q="$worker_primary"
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
  case "${EFFECTIVE_CPUS:-}" in
    ''|*[!0-9]*|0) ;;
    *) [ "$target_q" -le "$EFFECTIVE_CPUS" ] || target_q="$EFFECTIVE_CPUS" ;;
  esac

  if [ -n "$max_combined" ] && [ "$max_combined" != "n/a" ] && [ "$max_combined" -gt 0 ] && [ "$target_q" -gt "$max_combined" ]; then
    target_q="$max_combined"
  fi

  [ "$target_q" -lt 1 ] && target_q=1
  echo "$target_q"
}

_pick_target_queues() {
  local target auto max_combined workers current
  workers="${#WORKER_CPUS[@]}"
  target="${TARGET_QUEUES:-auto}"
  case "$target" in
    auto|'')
      # Changing channels can reset a live NIC. Preserve a readable current
      # configuration unless disruptive reconfiguration was explicitly enabled.
      if [ "${ALLOW_NIC_RECONFIGURE:-0}" != 1 ]; then
        current=$(_get_current_combined || true)
        if [[ "$current" =~ ^[1-9][0-9]*$ ]]; then printf '%s\n' "$current"; return 0; fi
      fi
      target=$(_calc_auto_queue_base || echo 1) ;;
    max)
      max_combined=$(_get_max_combined || true)
      if [[ "$max_combined" =~ ^[1-9][0-9]*$ ]]; then target="$max_combined"
      else target=$(_calc_auto_queue_base || echo 1); fi ;;
    all|full) target="$workers" ;;
    *[!0-9]*) target=$(_calc_auto_queue_base || echo 1) ;;
    *) : ;;
  esac
  max_combined=$(_get_max_combined || true)
  if [[ "$max_combined" =~ ^[1-9][0-9]*$ ]] && [ "$target" -gt "$max_combined" ]; then target="$max_combined"; fi
  [ "$target" -ge 1 ] || target=1
  printf '%s\n' "$target"
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
  local target="$1" max_combined before after cur changed=0
  case "$target" in ''|*[!0-9]*|0) target=1 ;; esac
  before=$(_get_current_combined || true)
  if ethtool -l "$DEV" >/dev/null 2>&1; then
    max_combined=$(_get_max_combined)
    if [[ "$max_combined" =~ ^[1-9][0-9]*$ ]] && [ "$target" -gt "$max_combined" ]; then
      target="$max_combined"
    fi
    if [ "$before" != "$target" ]; then
      if ethtool -L "$DEV" combined "$target" >/dev/null 2>&1; then
        after=$(_get_current_combined || true)
        if [[ "$before" =~ ^[1-9][0-9]*$ ]] && [[ "$after" =~ ^[1-9][0-9]*$ ]] && [ "$after" != "$before" ]; then
          changed=1
        fi
      else
        printf '网卡 %s 队列调整未应用，保留当前配置。\n' "$DEV" >&2
      fi
    fi
  fi
  # Preserve a pre-existing RSS indirection table on every ordinary reapply.
  # Only repair its distribution after a confirmed channel-count change.
  if [ "$changed" = "1" ] && ethtool -x "$DEV" >/dev/null 2>&1; then
    ethtool -X "$DEV" equal "$after" >/dev/null 2>&1 || \
      printf '网卡 %s RSS 重分配不支持，保留驱动实际值。\n' "$DEV" >&2
  fi
  cur=$(_get_current_combined || true)
  if ! [[ "$cur" =~ ^[1-9][0-9]*$ ]]; then
    cur=$(find "$SYS_ROOT/class/net/$DEV/queues" -maxdepth 1 -type d -name 'rx-*' 2>/dev/null | awk 'END {print NR + 0}')
  fi
  [[ "$cur" =~ ^[1-9][0-9]*$ ]] || cur=1
  echo "$cur"
}

_apply_max_rings() {
  local ring_info rxmax txmax cur_rx cur_tx target_rx target_tx mode missed previous speed auto_cap
  local -a args=()
  mode="${RING_MODE:-auto}"
  [ "${MAX_RINGS:-0}" != "1" ] || mode=throughput
  ring_info=$(ethtool -g "$DEV" 2>/dev/null) || { echo unsupported; return 0; }
  read -r rxmax txmax cur_rx cur_tx < <(printf '%s\n' "$ring_info" | awk '
    /Pre-set maximums:/ {sec=1; next}
    /Current hardware settings:/ {sec=2; next}
    sec == 1 && $1 == "RX:" {rxmax=$2}
    sec == 1 && $1 == "TX:" {txmax=$2}
    sec == 2 && $1 == "RX:" {rx=$2}
    sec == 2 && $1 == "TX:" {tx=$2}
    END {print rxmax+0,txmax+0,rx+0,tx+0}')
  target_rx="$cur_rx"; target_tx="$cur_tx"
  case "$mode" in
    keep) _get_current_rings; return 0 ;;
    latency) target_rx=512; target_tx=512 ;;
    throughput|max) target_rx="$rxmax"; target_tx="$txmax" ;;
    auto|'')
      # Keep the driver's RX baseline and TX depth. Grow RX moderately only
      # after a confirmed increase in missed packets between helper runs.
      missed=$(cat "$SYS_ROOT/class/net/$DEV/statistics/rx_missed_errors" 2>/dev/null || true)
      previous=$(cat "$TUNER_STATE_DIR/rx-missed-$DEV" 2>/dev/null || true)
      if [[ "$missed" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$missed" > "$TUNER_STATE_DIR/rx-missed-$DEV"
      fi
      if [ "${ALLOW_NIC_RECONFIGURE:-0}" = 1 ] && [[ "$previous" =~ ^[0-9]+$ ]] && [[ "$missed" =~ ^[0-9]+$ ]] && [ "$missed" -gt "$previous" ] && [ "$cur_rx" -gt 0 ]; then
        speed=$(_get_link_speed || true)
        auto_cap=1024
        [[ "$speed" =~ ^[0-9]+$ ]] && [ "$speed" -ge 10000 ] && auto_cap=2048
        if [ "$cur_rx" -lt "$auto_cap" ]; then
          target_rx=$(( cur_rx * 2 ))
          [ "$target_rx" -ge 512 ] || target_rx=512
          [ "$target_rx" -le "$auto_cap" ] || target_rx="$auto_cap"
        fi
      fi
      ;;
    *) printf '未知 ring 模式 %s，保留当前值。\n' "$mode" >&2 ;;
  esac
  if [[ "${RX_RING_TARGET:-}" =~ ^[1-9][0-9]*$ ]]; then
    target_rx="$RX_RING_TARGET"
    if [ "$mode" = auto ] && [ "$target_rx" -lt "$cur_rx" ]; then target_rx="$cur_rx"; fi
  fi
  if [[ "${TX_RING_TARGET:-}" =~ ^[1-9][0-9]*$ ]]; then target_tx="$TX_RING_TARGET"; fi
  [ "$target_rx" -le "$rxmax" ] || target_rx="$rxmax"
  [ "$target_tx" -le "$txmax" ] || target_tx="$txmax"
  if [ "$target_rx" -gt 0 ] && [ "$target_rx" != "$cur_rx" ]; then args+=(rx "$target_rx"); fi
  if [ "$target_tx" -gt 0 ] && [ "$target_tx" != "$cur_tx" ]; then args+=(tx "$target_tx"); fi
  if [ "${#args[@]}" -gt 0 ]; then
    ethtool -G "$DEV" "${args[@]}" >/dev/null 2>&1 || \
      printf '网卡 %s ring 调整未应用，保留驱动实际值。\n' "$DEV" >&2
  fi
  _get_current_rings
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
  local mode initial rx tx current_rx current_tx
  local -a args=()
  mode="${COALESCE_MODE:-auto}"
  initial=$(ethtool -c "$DEV" 2>/dev/null) || { echo unsupported; return 0; }
  current_rx=$(printf '%s\n' "$initial" | awk -F': *' '$1 == "rx-usecs" {print $2; exit}')
  current_tx=$(printf '%s\n' "$initial" | awk -F': *' '$1 == "tx-usecs" {print $2; exit}')
  case "$mode" in
    auto|keep|'') : ;;
    adaptive)
      if ! printf '%s\n' "$initial" | awk '/Adaptive RX: on[[:space:]]+TX: on/ {found=1} END {exit !found}'; then
        ethtool -C "$DEV" adaptive-rx on adaptive-tx on >/dev/null 2>&1 || \
          printf '网卡 %s 不支持所请求的 adaptive coalesce。\n' "$DEV" >&2
      fi
      ;;
    latency|throughput)
      if [ "$mode" = latency ]; then rx=2; tx=2; else rx=12; tx=12; fi
      if ! printf '%s\n' "$initial" | awk '/Adaptive RX: off[[:space:]]+TX: off/ {found=1} END {exit !found}'; then
        ethtool -C "$DEV" adaptive-rx off adaptive-tx off >/dev/null 2>&1 || true
      fi
      [[ "$current_rx" =~ ^[0-9]+$ ]] && [ "$current_rx" != "$rx" ] && args+=(rx-usecs "$rx")
      [[ "$current_tx" =~ ^[0-9]+$ ]] && [ "$current_tx" != "$tx" ] && args+=(tx-usecs "$tx")
      if [ "${#args[@]}" -gt 0 ]; then
        ethtool -C "$DEV" "${args[@]}" >/dev/null 2>&1 || \
          printf '网卡 %s coalesce 调整未应用，保留驱动实际值。\n' "$DEV" >&2
      fi
      ;;
    *) printf '未知 coalesce 模式 %s，保留当前值。\n' "$mode" >&2 ;;
  esac
  ethtool -c "$DEV" 2>/dev/null | awk -F': *' -v mode="$mode" '
    $1 == "rx-usecs" {rx=$2}
    $1 == "tx-usecs" {tx=$2}
    /^Adaptive RX:/ {adaptive=$0}
    END {printf "actual:%s/%s (%s; %s)\n",(rx==""?"unknown":rx),(tx==""?"unknown":tx),mode,(adaptive==""?"adaptive unknown":adaptive)}'
}

_force_fq_qdisc() {
  [ "${FORCE_FQ:-1}" = "1" ] || return 0
  local current root_type root_handle txq_count i parent
  current=$(tc qdisc show dev "$DEV" 2>/dev/null) || {
    printf '无法读取 %s qdisc，保留现有配置。\n' "$DEV" >&2; return 0;
  }
  # Custom classes, shapers, AQM, noqueue and ingress remain under their owner.
  if printf '%s\n' "$current" | awk '/^qdisc / && $2 != "mq" && $2 != "fq" && $2 != "ingress" && $2 != "clsact" {found=1} END {exit !found}'; then
    printf '保留 %s 已有 qdisc 策略。\n' "$DEV" >&2
    return 0
  fi
  root_type=$(printf '%s\n' "$current" | awk '/^qdisc / && / root([[:space:]]|$)/ {print $2; exit}')
  root_handle=$(printf '%s\n' "$current" | awk '/^qdisc / && / root([[:space:]]|$)/ {print $3; exit}')
  [ "$root_type" != fq ] || return 0
  modprobe sch_fq >/dev/null 2>&1 || true
  txq_count=$(find "$SYS_ROOT/class/net/$DEV/queues" -maxdepth 1 -type d -name 'tx-*' 2>/dev/null | awk 'END {print NR+0}')
  if [ "$root_type" = mq ]; then
    # Keep the root and every existing fq; populate only absent children.
    for ((i=1;i<=txq_count;i++)); do
      parent="${root_handle%:}:$i"
      if ! printf '%s\n' "$current" | awk -v parent="$parent" -v short=":$i" '
        /^qdisc / && $2 == "fq" {for(i=1;i<NF;i++) if($i == "parent" && ($(i+1)==parent || $(i+1)==short)) found=1}
        END {exit !found}'; then
        tc qdisc replace dev "$DEV" parent "$parent" fq >/dev/null 2>&1 || true
      fi
    done
  elif [ -z "$root_type" ]; then
    tc qdisc replace dev "$DEV" root fq >/dev/null 2>&1 || true
  fi
}

_apply_offloads() {
  local mode snapshot feature alias desired line current
  mode="${TUNE_OFFLOADS:-auto}"
  # Auto preserves an operator/driver's existing feature dependencies.
  # Explicit tuning writes individual mutable features, never one all-or-none
  # command whose first unsupported flag hides the remaining capabilities.
  case "$mode" in 1|on|yes|true) : ;; *) return 0 ;; esac
  snapshot=$(ethtool -k "$DEV" 2>/dev/null) || return 0
  while read -r feature alias desired; do
    line=$(printf '%s\n' "$snapshot" | awk -F': *' -v key="$feature" '$1 == key {print; exit}')
    [ -n "$line" ] || continue
    [[ "$line" != *"[fixed]"* ]] || continue
    current=$(printf '%s\n' "$line" | awk -F': *' '{split($2,v," ");print v[1]}')
    [ "$current" != "$desired" ] || continue
    ethtool -K "$DEV" "$alias" "$desired" >/dev/null 2>&1 || \
      printf '网卡 %s offload %s 未应用，保留实际值。\n' "$DEV" "$feature" >&2
  done <<'EOF_OFFLOADS'
rx-checksumming rx on
tx-checksumming tx on
scatter-gather sg on
generic-segmentation-offload gso on
tcp-segmentation-offload tso on
generic-receive-offload gro on
EOF_OFFLOADS
}

_calc_rfs_total_flows() {
  local rxqs workers mem_gb total cap
  rxqs="$1"
  workers="$2"
  mem_gb=$(awk '/MemTotal:/ {printf "%d\n", int(($2 + 1048575) / 1048576)}' "$PROC_ROOT"/meminfo)

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
    [ -e "$PROC_ROOT"/sys/net/core/flow_limit_cpu_bitmap ] || return 0
    current=$(cat "$PROC_ROOT"/sys/net/core/flow_limit_cpu_bitmap 2>/dev/null || true)
    if [ ! -f "$FLOW_LIMIT_BEFORE" ]; then
      printf '%s\n' "$current" > "$FLOW_LIMIT_BEFORE"
    fi
    mask=$(_bitmap_for_all_workers)
    printf '%s\n' "$mask" > "$PROC_ROOT"/sys/net/core/flow_limit_cpu_bitmap 2>/dev/null || return 0
    if [ "$(cat "$PROC_ROOT"/sys/net/core/flow_limit_cpu_bitmap 2>/dev/null || true)" = "$mask" ]; then
      printf '%s\n' "$mask" > "$FLOW_LIMIT_OWNED"
    fi
    return 0
  fi

  [ -f "$FLOW_LIMIT_BEFORE" ] && [ -f "$FLOW_LIMIT_OWNED" ] || return 0
  before=$(cat "$FLOW_LIMIT_BEFORE" 2>/dev/null || true)
  owned=$(cat "$FLOW_LIMIT_OWNED" 2>/dev/null || true)
  current=$(cat "$PROC_ROOT"/sys/net/core/flow_limit_cpu_bitmap 2>/dev/null || true)
  if [ -n "$before" ] && [ "$current" = "$owned" ] && [ -w "$PROC_ROOT"/sys/net/core/flow_limit_cpu_bitmap ]; then
    printf '%s\n' "$before" > "$PROC_ROOT"/sys/net/core/flow_limit_cpu_bitmap 2>/dev/null || true
  fi
  rm -f "$FLOW_LIMIT_BEFORE" "$FLOW_LIMIT_OWNED"
}

_apply_irq_affinity() {
  local i irq cpu effective queue
  IRQ_AFFINITY_OK=0
  [ "${IRQ_MANUAL_ALLOWED:-1}" = "1" ] || return 0
  [ "${IRQ_MAPPING_COMPLETE:-0}" = "1" ] || return 0
  [ "${#IRQS[@]}" -gt 0 ] || return 0
  [ "${#IRQ_CPUS[@]}" -gt 0 ] || return 0
  IRQ_AFFINITY_OK=1
  for ((i = 0; i < ${#IRQS[@]}; i++)); do
    irq="${IRQS[$i]}"
    queue="${IRQ_QUEUE_IDS[$i]:-}"
    case "$queue" in ''|*[!0-9]*) IRQ_AFFINITY_OK=0; continue ;; esac
    cpu="${IRQ_CPUS[$(( queue % ${#IRQ_CPUS[@]} ))]}"
    if [ -w "$PROC_ROOT/irq/$irq/smp_affinity_list" ]; then
      echo "$cpu" > "$PROC_ROOT/irq/$irq/smp_affinity_list" 2>/dev/null || true
      effective=$(cat "$PROC_ROOT/irq/$irq/effective_affinity_list" 2>/dev/null || cat "$PROC_ROOT/irq/$irq/smp_affinity_list" 2>/dev/null || true)
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

  case "$enable" in
    0|off|no|false) enable=no ;;
    1|on|yes|true) enable=yes ;;
    auto|keep|'') _sync_flow_limit; return 0 ;;
    *) printf '未知 RPS 模式 %s，保留当前设置。\n' "$enable" >&2; return 0 ;;
  esac

  if [ "$enable" = "yes" ]; then
    total_flows="${RFS_FLOW_ENTRIES:-auto}"
    case "$total_flows" in
      auto|''|*[!0-9]*) total_flows=$(_calc_rfs_total_flows "${#RXQS[@]}" "$worker_cnt") ;;
      *) : ;;
    esac

    minimum_flows=$(( ${#RXQS[@]} * 1024 ))
    [ "$total_flows" -lt "$minimum_flows" ] && total_flows="$minimum_flows"
    current_flows=$(cat "$PROC_ROOT"/sys/net/core/rps_sock_flow_entries 2>/dev/null || echo 0)
    case "$current_flows" in ''|*[!0-9]*) current_flows=0 ;; esac
    [ "$current_flows" -gt "$total_flows" ] && total_flows="$current_flows"
    echo "$total_flows" > "$PROC_ROOT"/sys/net/core/rps_sock_flow_entries 2>/dev/null || true
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
  IRQ_MANUAL_ALLOWED=1
  command -v systemctl >/dev/null 2>&1 || return 0
  systemctl is-active --quiet irqbalance >/dev/null 2>&1 || return 0
  case "$policy" in
    disable)
      if [ "${DISABLE_IRQBALANCE:-1}" = "1" ]; then
        systemctl stop irqbalance >/dev/null 2>&1 || true
        if systemctl is-active --quiet irqbalance >/dev/null 2>&1; then
          IRQ_MANUAL_ALLOWED=0
        else
          systemctl disable irqbalance >/dev/null 2>&1 || true
        fi
      else
        IRQ_MANUAL_ALLOWED=0
      fi
      ;;
    auto|keep|''|*)
      # No global service shutdown for one NIC. Without a confirmed per-IRQ
      # exclusion contract, irqbalance owns these interrupts exclusively.
      IRQ_MANUAL_ALLOWED=0
      ;;
  esac
}

_collect_irqs() {
  _nic_irq_candidates
}

_collect_irq_map() {
  local allowed="" irq
  while read -r irq; do
    case "$irq" in ''|*[!0-9]*) continue ;; esac
    allowed="$allowed,$irq"
  done < <(_nic_irq_candidates)
  [ -n "$allowed" ] || return 0
  allowed="$allowed,"
  awk -v allowed="$allowed" '
    {
      irq=$1;sub(/:$/,"",irq)
      if(irq!~/^[0-9]+$/ || !index(allowed,"," irq ","))next
      action=tolower($0)
      if(action ~ /(admin|config|mgmt|management|async|command)/)next
      candidate=action;queue=""
      if(candidate ~ /(txrx|tx-rx|rx|tx)[-_.]?[0-9]+/){
        sub(/^.*(txrx|tx-rx|rx|tx)[-_.]?/,"",candidate);sub(/[^0-9].*$/,"",candidate);queue=candidate
      } else if(candidate ~ /(input|output)\.[0-9]+/){
        sub(/^.*(input|output)\./,"",candidate);sub(/[^0-9].*$/,"",candidate);queue=candidate
      } else if(candidate ~ /comp[0-9]+/){
        sub(/^.*comp/,"",candidate);sub(/[^0-9].*$/,"",candidate);queue=candidate
      } else if(candidate ~ /(queue|block)[-_.]?[0-9]+/){
        sub(/^.*(queue|block)[-_.]?/,"",candidate);sub(/[^0-9].*$/,"",candidate);queue=candidate
      }
      if(queue~/^[0-9]+$/)print queue,irq
    }
  ' "$PROC_ROOT/interrupts" 2>/dev/null || true
}

ALLOWED_CPU_SPEC=$(_allowed_cpu_spec)
[ -n "$ALLOWED_CPU_SPEC" ] || { echo "未找到允许使用的在线 CPU"; exit 1; }

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

mapfile -t RXQS < <(find "$SYS_ROOT/class/net/$DEV/queues" -maxdepth 1 -type d -name 'rx-*' | sort -V)
mapfile -t TXQS < <(find "$SYS_ROOT/class/net/$DEV/queues" -maxdepth 1 -type d -name 'tx-*' | sort -V)
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

_maybe_disable_irqbalance
_apply_irq_affinity
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
printf 'IRQ 手动管理: %s\n' "${IRQ_MANUAL_ALLOWED:-1}"
printf 'IRQ 映射: %s\n' "${IRQ_MAPPING_COMPLETE:-0}" | sed 's/^IRQ 映射: 1$/IRQ 映射: queue-aware/;s/^IRQ 映射: 0$/IRQ 映射: unknown (保留 irqbalance)/'
printf '工作 CPU 数: %s\n' "${#WORKER_CPUS[@]}"
printf '目标队列: %s\n' "$TARGET_QUEUES"
printf 'ring: %s\n' "$RING_RESULT"
printf 'flow control: %s\n' "$FLOW_RESULT"
printf 'coalesce: %s\n' "$COALESCE_RESULT"
printf 'rps_sock_flow_entries: %s\n' "$(cat "$PROC_ROOT"/sys/net/core/rps_sock_flow_entries 2>/dev/null || echo 0)"
if [ -e "$PROC_ROOT"/sys/net/core/flow_limit_cpu_bitmap ]; then
  printf 'flow_limit_cpu_bitmap: %s\n' "$(cat "$PROC_ROOT"/sys/net/core/flow_limit_cpu_bitmap 2>/dev/null || echo 0)"
fi
printf '网卡调优已应用到 %s\n' "$DEV"
EOF_HELPER
  chmod +x "$NIC_HELPER"
}

build_nic_service() {
  cat > "$NIC_SERVICE" <<'EOF_SERVICE' || return 1
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
  local nic
  nic=$(ip -o route show to default 2>/dev/null | awk '{for(i=1;i<NF;i++)if($i=="dev"){print $(i+1);exit}}' || true)
  [ -n "$nic" ] || nic=$(ip -o -6 route show to default 2>/dev/null | awk '{for(i=1;i<NF;i++)if($i=="dev"){print $(i+1);exit}}' || true)
  printf '%s\n' "$nic"
}

select_nic_noninteractive() {
  local nic="${NIC:-$(default_nic)}"
  if [ -n "$nic" ] && ip link show dev "$nic" >/dev/null 2>&1; then
    printf '%s\n' "$nic"; return 0
  fi
  [ -z "${NIC:-}" ] || { err "指定的网卡不存在：$NIC" >&2; return 1; }
  nic=$(ip -o link show | awk -F': ' '{n=$2;sub(/@.*/,"",n);if(n!="lo"){print n;exit}}') || return 1
  [ -n "$nic" ] || return 1
  printf '%s\n' "$nic"
}

setup_mode2_persistence() {
  local nic="$1" service_started=0
  ensure_cmd ethtool || return 1
  ensure_cmd ip || return 1
  ensure_cmd tc || return 1
  ensure_cmd lscpu || true
  ensure_cmd modprobe || true

  build_nic_helper || return 1
  build_nic_service || return 1
  local temporary
  temporary=$(mktemp "$NIC_ENV_FILE.build.XXXXXX") || return 1
  {
    printf 'DEV=%q\nTUNER_STATE_DIR=%q\nEFFECTIVE_CPUS=%q\n' "$nic" "$WORKDIR" "$(online_cpu_count)"
    printf 'USE_HT=%q\n' "${USE_HT:-0}"
    printf 'WORKER_CPUS_TARGET=%q\n' "${WORKER_CPUS_TARGET:-local}"
    printf 'TARGET_QUEUES=%q\n' "${TARGET_QUEUES:-auto}"
    printf 'ALLOW_NIC_RECONFIGURE=%q\n' "${ALLOW_NIC_RECONFIGURE:-0}"
    printf 'MAX_RINGS=%q\n' "${MAX_RINGS:-0}"
    printf 'RING_MODE=%q\n' "${RING_MODE:-auto}"
    printf 'RX_RING_TARGET=%q\n' "${RX_RING_TARGET:-}"
    printf 'TX_RING_TARGET=%q\n' "${TX_RING_TARGET:-}"
    printf 'COALESCE_MODE=%q\n' "${COALESCE_MODE:-auto}"
    printf 'RFS_FLOW_ENTRIES=%q\n' "${RFS_FLOW_ENTRIES:-auto}"
    printf 'ENABLE_RPS=%q\n' "${ENABLE_RPS:-auto}"
    printf 'RPS_FORWARD_ONLY=%q\n' "${RPS_FORWARD_ONLY:-1}"
    printf 'RPS_CPUS_PER_QUEUE=%q\n' "${RPS_CPUS_PER_QUEUE:-2}"
    printf 'ENABLE_FLOW_LIMIT=%q\n' "${ENABLE_FLOW_LIMIT:-0}"
    printf 'DISABLE_IRQBALANCE=%q\n' "${DISABLE_IRQBALANCE:-1}"
    printf 'IRQBALANCE_POLICY=%q\n' "${IRQBALANCE_POLICY:-auto}"
    printf 'FLOW_CONTROL_MODE=%q\n' "${FLOW_CONTROL_MODE:-keep}"
    printf 'FORCE_FQ=%q\n' "${FORCE_FQ:-1}"
    printf 'TUNE_OFFLOADS=%q\n' "${TUNE_OFFLOADS:-auto}"
  } > "$temporary" || { rm -f "$temporary"; return 1; }
  chmod 0600 "$temporary" || { rm -f "$temporary"; return 1; }
  mv -f "$temporary" "$NIC_ENV_FILE" || return 1

  # Restart a single oneshot after writing its complete configuration. This
  # covers both a first install and an already-active service exactly once.
  if command -v systemctl >/dev/null 2>&1 && systemctl show-environment >/dev/null 2>&1; then
    systemctl daemon-reload || return 1
    systemctl enable live-relay-nic-tuning.service >/dev/null 2>&1 || return 1
    systemctl restart live-relay-nic-tuning.service || return 1
    service_started=1
    log "网卡调优服务已应用并启用。"
  fi
  if [ "$service_started" = "0" ]; then
    NIC_ENV_FILE="$NIC_ENV_FILE" "$NIC_HELPER" || return 1
    warn "systemd 不可用，网卡调优已立即应用。"
  fi
}

detect_data_plane() {
  local cached="" stamp="" now="" detected="" tcp=0 udp=0 forward=0
  if [ -r "$WORKDIR/diagnostics.env" ]; then
    cached=$(awk -F= '$1=="DIAG_DATA_PLANE" {print $2;exit}' "$WORKDIR/diagnostics.env")
    stamp=$(awk -F= '$1=="DIAG_UPDATED_MONO" {print $2;exit}' "$WORKDIR/diagnostics.env")
    now=$(awk '{print int($1)}' "${PROC_ROOT:-/proc}/uptime" 2>/dev/null || true)
    case "$stamp:$now" in *[!0-9:]*|:*|*:) ;; *)
      if [ "$now" -ge "$stamp" ] && [ $((now - stamp)) -le 90 ]; then
        case "$cached" in Proxy-local/*|Proxy-other-netns*|Mixed/*|Forward/*|Forward-observed) printf '%s\n' "$cached"; return 0 ;; esac
      fi ;;
    esac
  fi
  detected=$(ps -eo comm= 2>/dev/null | awk '{n=$1;sub(/^.*\//,"",n);if(n~/^(sing-box|xray|v2ray|realm|gost|hysteria2?|tuic(-server)?|ss-server|ssserver|haproxy|nginx|caddy)([-_.].*)?$/){print "Proxy/Protocols-unknown";exit}}' || true)
  if [ -n "$detected" ]; then printf '%s\n' "$detected"; return 0; fi
  if command -v ss >/dev/null 2>&1; then
    tcp=$(ss -H -ltn 2>/dev/null | awk 'END {print NR+0}' || echo 0)
    udp=$(ss -H -lun 2>/dev/null | awk 'END {print NR+0}' || echo 0)
  fi
  [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || true)" != 1 ] || forward=1
  case "$tcp" in ''|*[!0-9]*) tcp=0 ;; esac
  case "$udp" in ''|*[!0-9]*) udp=0 ;; esac
  if [ "$tcp" -gt 0 ] && [ "$udp" -gt 0 ]; then printf 'Listeners/TCP+UDP\n'
  elif [ "$tcp" -gt 0 ]; then printf 'Listeners/TCP\n'
  elif [ "$udp" -gt 0 ]; then printf 'Listeners/UDP\n'
  elif [ "$forward" = 1 ]; then printf 'Forward-enabled\n'
  else printf 'Unknown\n'; fi
}

data_plane_label() {
  case "${1:-Unknown}" in
    Proxy-local/*+Forward-observed|Proxy-other-netns+Forward-observed) printf '代理与转发混合业务\n' ;;
    Proxy-local/TCP+UDP) printf '本机代理 · TCP/UDP\n' ;;
    Proxy-local/TCP) printf '本机代理 · TCP\n' ;;
    Proxy-local/UDP) printf '本机代理 · UDP\n' ;;
    Proxy/Protocols-unknown|Proxy-local/Protocols-unknown) printf '已识别代理 · 协议待采集\n' ;;
    Proxy-other-netns) printf '代理位于其他网络命名空间\n' ;;
    Mixed/*) printf '代理与转发混合业务\n' ;;
    Forward/*|Forward-observed) printf '已观测到转发业务\n' ;;
    Listeners/TCP+UDP) printf 'TCP/UDP 监听 · 代理待识别\n' ;;
    Listeners/TCP) printf 'TCP 监听 · 代理待识别\n' ;;
    Listeners/UDP) printf 'UDP 监听 · 代理待识别\n' ;;
    Forward-enabled) printf '已开启转发 · 业务待确认\n' ;;
    *) printf '待识别\n' ;;
  esac
}

installed_tuner_version() {
  local value=""
  if [ -r "$AUTO_ENV_FILE" ]; then
    value=$(awk -F= '$1=="TUNER_VERSION" {print $2;exit}' "$AUTO_ENV_FILE")
    if [[ "$value" =~ ^[0-9][A-Za-z0-9_.-]*$ ]]; then printf 'V%s\n' "${value%%-*}"; return 0; fi
  fi
  if [ -r "$AUTO_HELPER" ]; then
    if grep -q '^DETAIL_FILE=' "$AUTO_HELPER"; then printf 'V5\n'
    elif grep -q '^COOLDOWN_WINDOWS=' "$AUTO_HELPER"; then printf 'V4\n'
    else printf '版本待识别\n'; fi
  else printf '版本待识别\n'; fi
}

tuner_status_label() {
  local active=0 installed=0 previous="" version
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet live-relay-auto-controller.service >/dev/null 2>&1; then active=1; fi
  [ ! -x "$AUTO_HELPER" ] || installed=1
  if [ -r "$WORKDIR/last-operation.env" ]; then
    previous=$(awk -F= '$1=="OPERATION_STATUS" {print $2;exit}' "$WORKDIR/last-operation.env")
  fi
  if [ "$previous" = recovery_failed ] || [ -e "$WORKDIR/sysctl-boot-pending" ]; then printf '恢复待处理\n'; return; fi
  if [ "$active" = 1 ]; then
    version=$(installed_tuner_version)
    if [ -e "$PAUSE_FILE" ]; then printf '已暂停（%s）\n' "$version"
    elif [ "$previous" = failed_restored ]; then printf '运行中（%s，上次操作未完成）\n' "$version"
    else printf '运行中（%s）\n' "$version"; fi
  elif [ "$installed" = 1 ]; then
    version=$(installed_tuner_version)
    if [ "$previous" = failed_restored ]; then printf '已停止（%s，上次操作未完成）\n' "$version"
    elif [ -e "$PAUSE_FILE" ]; then printf '已暂停（%s，服务未运行）\n' "$version"
    else printf '已停止（%s）\n' "$version"; fi
  elif [ "$previous" = failed_restored ]; then printf '安装未完成\n'
  else printf '未安装\n'; fi
}

write_operation_result() {
  local status="$1" transaction="$2" reason="$3" temporary
  temporary=$(mktemp "$WORKDIR/.last-operation.XXXXXX") || return 1
  {
    printf 'OPERATION_STATUS=%q\nOPERATION_TRANSACTION=%q\nOPERATION_REASON=%q\n' "$status" "$transaction" "$reason"
    printf 'OPERATION_VERSION=%q\nOPERATION_UPDATED_AT=%q\n' "$VERSION" "$(date +%F_%T)"
  } > "$temporary" && chmod 0600 "$temporary" && mv -f "$temporary" "$WORKDIR/last-operation.env" || { rm -f "$temporary"; return 1; }
}

show_installation_diagnostics() {
  local OPERATION_STATUS="" OPERATION_TRANSACTION="" OPERATION_REASON="" OPERATION_VERSION="" OPERATION_UPDATED_AT=""
  [ -r "$WORKDIR/last-operation.env" ] || return 0
  # This atomic mode-0600 file belongs to the root-owned state directory.
  # shellcheck disable=SC1090
  source "$WORKDIR/last-operation.env" || return 0
  case "$OPERATION_STATUS" in failed_restored|recovery_failed|started) ;; *) return 0 ;; esac
  printf '最近配置操作：%s / %s / %s\n' "$OPERATION_REASON" "$OPERATION_VERSION" "$OPERATION_UPDATED_AT"
  printf '诊断目录：%s\n' "$OPERATION_TRANSACTION"
  if [ -r "$OPERATION_TRANSACTION/sysctl.before.log" ]; then
    printf 'sysctl 预检记录（最近 12 行）：\n'
    tail -n 12 "$OPERATION_TRANSACTION/sysctl.before.log"
  fi
}

capture_original_runtime() {
  local nic="$1" root="${SNAPSHOT_DIR%/}" snapshot="$SNAPSHOT_DIR/runtime.env" stage backup="" irq path value name
  local proc_root="${PROC_ROOT:-/proc}" sys_root="${SYS_ROOT:-/sys}" complete=1
  # Earlier versions have no marker. Keep a complete legacy snapshot intact;
  # never replace an original baseline with a new, already-tuned baseline.
  if [ -f "$snapshot" ]; then
    for name in offloads.tsv irq-affinity.tsv queue-state.tsv cpu-power.tsv; do
      [ -f "$root/$name" ] || complete=0
    done
    if [ "$complete" = 1 ]; then
      [ -f "$root/capture.complete" ] || : > "$root/capture.complete"
      return 0
    fi
  fi
  mkdir -p "${root%/*}" || return 1
  stage=$(mktemp -d "$root.capture.XXXXXX") || return 1
  chmod 700 "$stage" || { rm -rf "$stage"; return 1; }
  # Recover an interrupted legacy capture without overwriting fields/files
  # that still describe the original runtime.
  for name in runtime.env offloads.tsv irq-affinity.tsv queue-state.tsv cpu-power.tsv; do
    if [ -f "$root/$name" ]; then
      cp -p "$root/$name" "$stage/$name" || { rm -rf "$stage"; return 1; }
    fi
  done
  if [ ! -f "$stage/runtime.env" ]; then
    {
      printf 'ORIGINAL_NIC=%q\n' "$nic"
      printf 'IRQBALANCE_ENABLED=%q\n' "$(systemctl is-enabled irqbalance 2>/dev/null || true)"
      printf 'IRQBALANCE_ACTIVE=%q\n' "$(systemctl is-active irqbalance 2>/dev/null || true)"
      printf 'ORIGINAL_COMBINED=%q\n' "$(ethtool -l "$nic" 2>/dev/null | awk '/Current hardware settings:/ {s=1; next} s && /Combined:/ {print $2; exit}' || true)"
      printf 'ORIGINAL_RX_RING=%q\n' "$(ethtool -g "$nic" 2>/dev/null | awk '/Current hardware settings:/ {s=1; next} s && $1 == "RX:" {print $2; exit}' || true)"
      printf 'ORIGINAL_TX_RING=%q\n' "$(ethtool -g "$nic" 2>/dev/null | awk '/Current hardware settings:/ {s=1; next} s && $1 == "TX:" {print $2; exit}' || true)"
      printf 'ORIGINAL_RX_USECS=%q\n' "$(ethtool -c "$nic" 2>/dev/null | awk -F': ' '/rx-usecs:/ {print $2; exit}' || true)"
      printf 'ORIGINAL_TX_USECS=%q\n' "$(ethtool -c "$nic" 2>/dev/null | awk -F': ' '/tx-usecs:/ {print $2; exit}' || true)"
      printf 'ORIGINAL_ADAPTIVE_RX=%q\n' "$(ethtool -c "$nic" 2>/dev/null | awk '/Adaptive RX:/ {for(i=1;i<NF;i++)if($i=="RX:"){print $(i+1);exit}}' || true)"
      printf 'ORIGINAL_ADAPTIVE_TX=%q\n' "$(ethtool -c "$nic" 2>/dev/null | awk '/Adaptive RX:/ {for(i=1;i<NF;i++)if($i=="TX:"){print $(i+1);exit}}' || true)"
      printf 'ORIGINAL_PAUSE_RX=%q\n' "$(ethtool -a "$nic" 2>/dev/null | awk -F': ' '/RX:/ {print $2; exit}' || true)"
      printf 'ORIGINAL_PAUSE_TX=%q\n' "$(ethtool -a "$nic" 2>/dev/null | awk -F': ' '/TX:/ {print $2; exit}' || true)"
      printf 'ORIGINAL_RPS_SOCK_FLOW_ENTRIES=%q\n' "$(cat "$proc_root/sys/net/core/rps_sock_flow_entries" 2>/dev/null || true)"
      printf 'ORIGINAL_FLOW_LIMIT_CPU_BITMAP=%q\n' "$(cat "$proc_root/sys/net/core/flow_limit_cpu_bitmap" 2>/dev/null || true)"
    } > "$stage/runtime.env" || { rm -rf "$stage"; return 1; }
  fi
  if [ ! -f "$stage/offloads.tsv" ]; then
    # Unsupported offload inspection is a capability gap, not a failed capture.
    { ethtool -k "$nic" 2>/dev/null || true; } | awk -F': ' '
      /^(rx-checksumming|tx-checksumming|scatter-gather|tcp-segmentation-offload|generic-segmentation-offload|generic-receive-offload|large-receive-offload):/ {
        split($2,value," ");if(value[1]=="on"||value[1]=="off")print $1 "\t" value[1]
      }' > "$stage/offloads.tsv" || { rm -rf "$stage"; return 1; }
  fi
  if [ ! -f "$stage/irq-affinity.tsv" ]; then
    {
      while read -r irq; do
        [ -r "$proc_root/irq/$irq/smp_affinity_list" ] || continue
        printf '%s\t%s\n' "$irq" "$(cat "$proc_root/irq/$irq/smp_affinity_list" 2>/dev/null || true)"
      done < <(collect_nic_irqs "$nic" | awk '!seen[$0]++')
    } > "$stage/irq-affinity.tsv" || { rm -rf "$stage"; return 1; }
  fi
  if [ ! -f "$stage/queue-state.tsv" ]; then
    {
      for path in "$sys_root"/class/net/"$nic"/queues/{rx,tx}-*/{rps_cpus,rps_flow_cnt,xps_cpus,xps_rxqs}; do
        [ -r "$path" ] || continue
        value=$(cat "$path" 2>/dev/null || true)
        printf '%s\t%s\n' "$path" "$value"
      done
    } > "$stage/queue-state.tsv" || { rm -rf "$stage"; return 1; }
  fi
  if [ ! -f "$stage/cpu-power.tsv" ]; then
    {
      for path in "$sys_root"/devices/system/cpu/cpu*/cpufreq/scaling_governor "$sys_root"/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
        [ -r "$path" ] || continue
        value=$(cat "$path" 2>/dev/null || true)
        printf '%s\t%s\n' "$path" "$value"
      done
    } > "$stage/cpu-power.tsv" || { rm -rf "$stage"; return 1; }
  fi
  : > "$stage/capture.complete" || { rm -rf "$stage"; return 1; }
  if [ -e "$root" ]; then
    backup=$(mktemp -d "$root.previous.XXXXXX") || { rm -rf "$stage"; return 1; }
    rmdir "$backup" || { rm -rf "$stage"; return 1; }
    mv "$root" "$backup" || { rm -rf "$stage"; return 1; }
  fi
  if ! mv "$stage" "$root"; then
    [ -z "$backup" ] || mv "$backup" "$root" || true
    rm -rf "$stage"
    return 1
  fi
  [ -z "$backup" ] || rm -rf "$backup"
  return 0
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
  local snapshot="$SNAPSHOT_DIR/runtime.env" path value irq nic current output desired feature line old_rx old_tx adaptive_rx adaptive_tx failed=0 original key name
  local proc_root="${PROC_ROOT:-/proc}"
  local -a args=()
  [ -f "$snapshot" ] || return 0
  # Keep legacy snapshots readable without requiring fields added later.
  local ORIGINAL_NIC="" ORIGINAL_COMBINED="" ORIGINAL_RX_RING="" ORIGINAL_TX_RING=""
  local ORIGINAL_RX_USECS="" ORIGINAL_TX_USECS="" ORIGINAL_ADAPTIVE_RX="" ORIGINAL_ADAPTIVE_TX=""
  local ORIGINAL_PAUSE_RX="" ORIGINAL_PAUSE_TX="" ORIGINAL_RPS_SOCK_FLOW_ENTRIES="" ORIGINAL_FLOW_LIMIT_CPU_BITMAP=""
  local IRQBALANCE_ENABLED=unknown IRQBALANCE_ACTIVE=unknown
  # shellcheck disable=SC1090
  source "$snapshot" || return 1
  nic="$ORIGINAL_NIC"
  if [ -n "$nic" ]; then
    if ! ip link show "$nic" >/dev/null 2>&1; then
      failed=1
    else
      if [[ "$ORIGINAL_COMBINED" =~ ^[1-9][0-9]*$ ]]; then
        output=$(ethtool -l "$nic" 2>/dev/null || true)
        current=$(printf '%s\n' "$output" | awk '/Current hardware settings:/ {s=1;next}s&&/Combined:/ {print $2;exit}')
        if [ "$current" != "$ORIGINAL_COMBINED" ]; then
          if ! [[ "$current" =~ ^[1-9][0-9]*$ ]]; then failed=1
          else
          if ! ethtool -L "$nic" combined "$ORIGINAL_COMBINED" >/dev/null 2>&1; then failed=1; fi
          current=$(ethtool -l "$nic" 2>/dev/null | awk '/Current hardware settings:/ {s=1;next}s&&/Combined:/ {print $2;exit}' || true)
          [ "$current" = "$ORIGINAL_COMBINED" ] || failed=1
          fi
        fi
      fi
      args=()
      output=$(ethtool -g "$nic" 2>/dev/null || true)
      old_rx=$(printf '%s\n' "$output" | awk '/Current hardware settings:/ {s=1;next}s&&$1=="RX:" {print $2;exit}')
      old_tx=$(printf '%s\n' "$output" | awk '/Current hardware settings:/ {s=1;next}s&&$1=="TX:" {print $2;exit}')
      if [[ "$ORIGINAL_RX_RING" =~ ^[1-9][0-9]*$ ]] && [ "$old_rx" != "$ORIGINAL_RX_RING" ]; then
        if [[ "$old_rx" =~ ^[1-9][0-9]*$ ]]; then args+=(rx "$ORIGINAL_RX_RING"); else failed=1; fi
      fi
      if [[ "$ORIGINAL_TX_RING" =~ ^[1-9][0-9]*$ ]] && [ "$old_tx" != "$ORIGINAL_TX_RING" ]; then
        if [[ "$old_tx" =~ ^[1-9][0-9]*$ ]]; then args+=(tx "$ORIGINAL_TX_RING"); else failed=1; fi
      fi
      if [ "${#args[@]}" -gt 0 ]; then
        ethtool -G "$nic" "${args[@]}" >/dev/null 2>&1 || failed=1
        output=$(ethtool -g "$nic" 2>/dev/null || true)
        current=$(printf '%s\n' "$output" | awk '/Current hardware settings:/ {s=1;next}s&&$1=="RX:" {print $2;exit}')
        if [[ "$ORIGINAL_RX_RING" =~ ^[1-9][0-9]*$ ]]; then [ "$current" = "$ORIGINAL_RX_RING" ] || failed=1; fi
        current=$(printf '%s\n' "$output" | awk '/Current hardware settings:/ {s=1;next}s&&$1=="TX:" {print $2;exit}')
        if [[ "$ORIGINAL_TX_RING" =~ ^[1-9][0-9]*$ ]]; then [ "$current" = "$ORIGINAL_TX_RING" ] || failed=1; fi
      fi
      args=()
      output=$(ethtool -c "$nic" 2>/dev/null || true)
      old_rx=$(printf '%s\n' "$output" | awk -F': *' '$1=="rx-usecs" {print $2;exit}')
      old_tx=$(printf '%s\n' "$output" | awk -F': *' '$1=="tx-usecs" {print $2;exit}')
      adaptive_rx=$(printf '%s\n' "$output" | awk '/Adaptive RX:/ {for(i=1;i<NF;i++)if($i=="RX:"){print $(i+1);exit}}')
      adaptive_tx=$(printf '%s\n' "$output" | awk '/Adaptive RX:/ {for(i=1;i<NF;i++)if($i=="TX:"){print $(i+1);exit}}')
      if [[ "$ORIGINAL_RX_USECS" =~ ^[0-9]+$ ]] && [ "$old_rx" != "$ORIGINAL_RX_USECS" ]; then
        if [[ "$old_rx" =~ ^[0-9]+$ ]]; then args+=(rx-usecs "$ORIGINAL_RX_USECS"); else failed=1; fi
      fi
      if [[ "$ORIGINAL_TX_USECS" =~ ^[0-9]+$ ]] && [ "$old_tx" != "$ORIGINAL_TX_USECS" ]; then
        if [[ "$old_tx" =~ ^[0-9]+$ ]]; then args+=(tx-usecs "$ORIGINAL_TX_USECS"); else failed=1; fi
      fi
      case "$ORIGINAL_ADAPTIVE_RX" in on|off)
        case "$adaptive_rx" in on|off) [ "$adaptive_rx" = "$ORIGINAL_ADAPTIVE_RX" ] || args+=(adaptive-rx "$ORIGINAL_ADAPTIVE_RX") ;; *) failed=1 ;; esac ;;
      esac
      case "$ORIGINAL_ADAPTIVE_TX" in on|off)
        case "$adaptive_tx" in on|off) [ "$adaptive_tx" = "$ORIGINAL_ADAPTIVE_TX" ] || args+=(adaptive-tx "$ORIGINAL_ADAPTIVE_TX") ;; *) failed=1 ;; esac ;;
      esac
      if [ "${#args[@]}" -gt 0 ]; then
        ethtool -C "$nic" "${args[@]}" >/dev/null 2>&1 || failed=1
        output=$(ethtool -c "$nic" 2>/dev/null || true)
        for key in RX_USECS TX_USECS ADAPTIVE_RX ADAPTIVE_TX; do
          original="ORIGINAL_$key"; desired="${!original}"
          case "$key" in
            RX_USECS) current=$(printf '%s\n' "$output" | awk -F': *' '$1=="rx-usecs" {print $2;exit}') ;;
            TX_USECS) current=$(printf '%s\n' "$output" | awk -F': *' '$1=="tx-usecs" {print $2;exit}') ;;
            ADAPTIVE_RX) current=$(printf '%s\n' "$output" | awk '/Adaptive RX:/ {for(i=1;i<NF;i++)if($i=="RX:"){print $(i+1);exit}}') ;;
            ADAPTIVE_TX) current=$(printf '%s\n' "$output" | awk '/Adaptive RX:/ {for(i=1;i<NF;i++)if($i=="TX:"){print $(i+1);exit}}') ;;
          esac
          [ -z "$desired" ] || [ "$desired" = "$current" ] || failed=1
        done
      fi
      args=()
      output=$(ethtool -a "$nic" 2>/dev/null || true)
      old_rx=$(printf '%s\n' "$output" | awk -F': *' '$1=="RX" {print $2;exit}')
      old_tx=$(printf '%s\n' "$output" | awk -F': *' '$1=="TX" {print $2;exit}')
      case "$ORIGINAL_PAUSE_RX" in on|off)
        case "$old_rx" in on|off) [ "$old_rx" = "$ORIGINAL_PAUSE_RX" ] || args+=(rx "$ORIGINAL_PAUSE_RX") ;; *) failed=1 ;; esac ;;
      esac
      case "$ORIGINAL_PAUSE_TX" in on|off)
        case "$old_tx" in on|off) [ "$old_tx" = "$ORIGINAL_PAUSE_TX" ] || args+=(tx "$ORIGINAL_PAUSE_TX") ;; *) failed=1 ;; esac ;;
      esac
      if [ "${#args[@]}" -gt 0 ]; then
        ethtool -A "$nic" "${args[@]}" >/dev/null 2>&1 || failed=1
        output=$(ethtool -a "$nic" 2>/dev/null || true)
        current=$(printf '%s\n' "$output" | awk -F': *' '$1=="RX" {print $2;exit}')
        case "$ORIGINAL_PAUSE_RX" in on|off) [ "$current" = "$ORIGINAL_PAUSE_RX" ] || failed=1 ;; esac
        current=$(printf '%s\n' "$output" | awk -F': *' '$1=="TX" {print $2;exit}')
        case "$ORIGINAL_PAUSE_TX" in on|off) [ "$current" = "$ORIGINAL_PAUSE_TX" ] || failed=1 ;; esac
      fi
      if [ -f "$SNAPSHOT_DIR/offloads.tsv" ]; then
        while IFS=$'\t' read -r feature value; do
          case "$value" in on|off) : ;; *) failed=1; continue ;; esac
          output=$(ethtool -k "$nic" 2>/dev/null || true)
          line=$(printf '%s\n' "$output" | awk -F': *' -v key="$feature" '$1==key {print;exit}')
          current=$(printf '%s\n' "$line" | awk -F': *' '{split($2,v," ");print v[1]}')
          [ "$current" != "$value" ] || continue
          if [ -z "$line" ] || [[ "$line" == *"[fixed]"* ]]; then failed=1; continue; fi
          ethtool -K "$nic" "$feature" "$value" >/dev/null 2>&1 || failed=1
          current=$(ethtool -k "$nic" 2>/dev/null | awk -F': *' -v key="$feature" '$1==key {split($2,v," ");print v[1];exit}' || true)
          [ "$current" = "$value" ] || failed=1
        done < "$SNAPSHOT_DIR/offloads.tsv"
      fi
    fi
  fi
  if [ -f "$SNAPSHOT_DIR/irq-affinity.tsv" ]; then
    while IFS=$'\t' read -r irq value; do
      case "$irq" in ''|*[!0-9]*) failed=1; continue ;; esac
      path="$proc_root/irq/$irq/smp_affinity_list"
      current=$(cat "$path" 2>/dev/null || true)
      [ "$current" != "$value" ] || continue
      if [ ! -w "$path" ] || ! printf '%s\n' "$value" > "$path" 2>/dev/null; then failed=1; continue; fi
      [ "$(cat "$path" 2>/dev/null || true)" = "$value" ] || failed=1
    done < "$SNAPSHOT_DIR/irq-affinity.tsv"
  fi
  for name in queue-state.tsv cpu-power.tsv; do
    [ -f "$SNAPSHOT_DIR/$name" ] || continue
    while IFS=$'\t' read -r path value; do
      current=$(cat "$path" 2>/dev/null || true)
      [ "$current" != "$value" ] || continue
      if [ ! -w "$path" ] || ! printf '%s\n' "$value" > "$path" 2>/dev/null; then failed=1; continue; fi
      [ "$(cat "$path" 2>/dev/null || true)" = "$value" ] || failed=1
    done < "$SNAPSHOT_DIR/$name"
  done
  for key in ORIGINAL_RPS_SOCK_FLOW_ENTRIES ORIGINAL_FLOW_LIMIT_CPU_BITMAP; do
    value="${!key}"
    [ -n "$value" ] || continue
    case "$key" in ORIGINAL_RPS_SOCK_FLOW_ENTRIES) path="$proc_root/sys/net/core/rps_sock_flow_entries" ;; *) path="$proc_root/sys/net/core/flow_limit_cpu_bitmap" ;; esac
    current=$(cat "$path" 2>/dev/null || true)
    [ "$current" != "$value" ] || continue
    if [ ! -w "$path" ] || ! printf '%s\n' "$value" > "$path" 2>/dev/null; then failed=1; continue; fi
    [ "$(cat "$path" 2>/dev/null || true)" = "$value" ] || failed=1
  done
  if command -v systemctl >/dev/null 2>&1; then
    if [ "$IRQBALANCE_ENABLED" = enabled ] && ! systemctl is-enabled --quiet irqbalance >/dev/null 2>&1; then
      systemctl enable irqbalance >/dev/null 2>&1 || failed=1
      systemctl is-enabled --quiet irqbalance >/dev/null 2>&1 || failed=1
    fi
    if [ "$IRQBALANCE_ACTIVE" = active ] && ! systemctl is-active --quiet irqbalance >/dev/null 2>&1; then
      systemctl start irqbalance >/dev/null 2>&1 || failed=1
      systemctl is-active --quiet irqbalance >/dev/null 2>&1 || failed=1
    fi
  elif [ "$IRQBALANCE_ENABLED" = enabled ] || [ "$IRQBALANCE_ACTIVE" = active ]; then
    failed=1
  fi
  return "$failed"
}

build_diagnostics_helper() {
  DIAG_HELPER="${DIAG_HELPER:-/usr/local/sbin/live-relay-diagnostics.sh}"
  mkdir -p "$(dirname "$DIAG_HELPER")" || return 1
  cat > "$DIAG_HELPER" <<'EOF_DIAGNOSTICS' || return 1
#!/usr/bin/env bash
(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )) || { echo "Bash 4.4 or newer is required; no settings were changed." >&2; exit 1; }
# Read-only diagnostics by default; application changes require an explicit command.
set -u
umask 077
# Explicit invocation settings override persisted defaults, including empty values.
_requested_names=(WORKDIR PROC_ROOT SYS_ROOT SYSTEMD_ROOT DEV DIAG_INTERVAL PROXY_PID PROXY_SERVICES MTU_PROBE_HOST MTU_PROBE_PAYLOAD ENABLE_APP_ADAPTER APP_ADAPTER ADAPTER_CPU_AFFINITY ADAPTER_LIMIT_NOFILE CONTROLLER_GENERATION)
_requested_values=(); _requested_set=()
for _requested_name in "${_requested_names[@]}"; do
  if [ "${!_requested_name+x}" = x ]; then
    _requested_set+=(1); _requested_values+=("${!_requested_name}")
  else _requested_set+=(0); _requested_values+=(""); fi
done
NIC_ENV_FILE="${NIC_ENV_FILE:-/etc/live-relay-nic.env}"
AUTO_ENV_FILE="${AUTO_ENV_FILE:-/etc/live-relay-auto.env}"
_nic_input="$NIC_ENV_FILE"; _auto_input="$AUTO_ENV_FILE"
[ ! -r "$_nic_input" ] || source "$_nic_input"
[ ! -r "$_auto_input" ] || source "$_auto_input"
for ((_requested_i=0; _requested_i<${#_requested_names[@]}; _requested_i++)); do
  if [ "${_requested_set[$_requested_i]}" = 1 ]; then
    printf -v "${_requested_names[$_requested_i]}" '%s' "${_requested_values[$_requested_i]}"
  fi
done
NIC_ENV_FILE="$_nic_input"; AUTO_ENV_FILE="$_auto_input"
unset _requested_values _requested_set _requested_names _requested_name _requested_i _nic_input _auto_input
WORKDIR="${WORKDIR:-/opt/live-relay-tuner}"
PROC_ROOT="${PROC_ROOT:-/proc}"
SYS_ROOT="${SYS_ROOT:-/sys}"
SYSTEMD_ROOT="${SYSTEMD_ROOT:-/etc/systemd/system}"
DIAG_STATE_FILE="$WORKDIR/diagnostics.env"
DEV="${DEV:-}"
DIAG_INTERVAL="${DIAG_INTERVAL:-30}"
case "$DIAG_INTERVAL" in ''|*[!0-9]*) DIAG_INTERVAL=30 ;; esac
[ "$DIAG_INTERVAL" -ge 30 ] || DIAG_INTERVAL=30
mkdir -p "$WORKDIR" || exit 1

bounded() {
  local seconds="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout -k 1 "$seconds" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout -k 1 "$seconds" "$@"
  else
    return 125
  fi
}

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
now_seconds() {
  awk '{printf "%.0f\n", $1}' "$PROC_ROOT/uptime" 2>/dev/null || date +%s
}
read_number() {
  local value
  if [ -r "$1" ]; then
    read -r value < "$1" || true
    if is_uint "${value:-}"; then printf '%s\n' "$value"; else printf 'unknown\n'; fi
  else
    printf 'unknown\n'
  fi
}
valid_unit() {
  [[ "$1" =~ ^[A-Za-z0-9_@:][A-Za-z0-9_.@:-]*\.service$ ]] && [[ "$1" != *..* ]]
}
recognized_name() {
  case "$1" in
    sing-box|xray|v2ray|realm|gost|hysteria|hysteria2|tuic|tuic-server|ss-server|ss-local|ss-redir|ss-tunnel|ssserver|sslocal|haproxy|nginx|caddy) return 0 ;;
    *) return 1 ;;
  esac
}
add_pid() {
  local pid="$1"
  is_uint "$pid" && [ "$pid" -gt 0 ] && [ -r "$PROC_ROOT/$pid/stat" ] || return 0
  case " $PROXY_PIDS " in *" $pid "*) return 0 ;; esac
  [ "$PROXY_COUNT" -lt 16 ] || { DIAG_PROCESS_TRUNCATED=1; return 0; }
  PROXY_PIDS="${PROXY_PIDS:+$PROXY_PIDS }$pid"
  PROXY_COUNT=$(( PROXY_COUNT + 1 ))
}
find_proxies() {
  local path pid comm svc explicit=0 exe ns current_ns same=0 different=0 unknown=0 service_count=0
  PROXY_PIDS=""; PROXY_COUNT=0; SAME_NETNS_PIDS=""
  DIAG_PROCESS_TRUNCATED=0; DIAG_PROXY_PROCESSES=""
  current_ns=$(readlink "$PROC_ROOT/self/ns/net" 2>/dev/null || true)
  if [ -n "${PROXY_PID:-}" ]; then
    explicit=1
    for pid in ${PROXY_PID//,/ }; do add_pid "$pid"; done
  fi
  if [ -n "${PROXY_SERVICES:-}" ]; then
    explicit=1
    for svc in ${PROXY_SERVICES//,/ }; do
      valid_unit "$svc" || continue
      [ "$service_count" -lt 16 ] || { DIAG_PROCESS_TRUNCATED=1; break; }
      service_count=$(( service_count + 1 ))
      pid=$(bounded 2 systemctl show --property=MainPID --value -- "$svc" 2>/dev/null || true)
      add_pid "$pid"
    done
  fi
  if [ "$explicit" -eq 0 ]; then
    for path in "$PROC_ROOT"/[0-9]*/comm; do
      [ -r "$path" ] || continue
      read -r comm < "$path" || continue
      recognized_name "$comm" || continue
      pid="${path%/comm}"; pid="${pid##*/}"
      add_pid "$pid"
    done
  fi
  if [ "$explicit" -eq 1 ] && [ "$PROXY_COUNT" -eq 0 ]; then
    DIAG_PROXY_STATUS=explicit_target_unavailable
  elif [ "$PROXY_COUNT" -eq 0 ]; then
    DIAG_PROXY_STATUS=no_recognized_process
  else
    DIAG_PROXY_STATUS=detected
  fi
  for pid in $PROXY_PIDS; do
    comm="unknown"; read -r comm < "$PROC_ROOT/$pid/comm" 2>/dev/null || true
    exe=$(readlink "$PROC_ROOT/$pid/exe" 2>/dev/null || true)
    ns=$(readlink "$PROC_ROOT/$pid/ns/net" 2>/dev/null || true)
    if [ -z "$current_ns" ] || [ -z "$ns" ]; then
      unknown=$(( unknown + 1 )); ns=unknown
    elif [ "$ns" = "$current_ns" ]; then
      same=$(( same + 1 )); ns=same
      SAME_NETNS_PIDS="${SAME_NETNS_PIDS:+$SAME_NETNS_PIDS }$pid"
    else
      different=$(( different + 1 )); ns=different
    fi
    DIAG_PROXY_PROCESSES="${DIAG_PROXY_PROCESSES}${DIAG_PROXY_PROCESSES:+; }pid=$pid name=$comm version=unknown netns=$ns exe=${exe:-unknown}"
  done
  if [ "$different" -gt 0 ] && [ "$same" -gt 0 ]; then DIAG_PROXY_NETNS_STATUS=mixed
  elif [ "$different" -gt 0 ]; then DIAG_PROXY_NETNS_STATUS=different
  elif [ "$unknown" -gt 0 ]; then DIAG_PROXY_NETNS_STATUS=unknown
  elif [ "$same" -gt 0 ]; then DIAG_PROXY_NETNS_STATUS=same
  else DIAG_PROXY_NETNS_STATUS=no_target; fi
  # A detected executable is never invoked merely to obtain its version.
  DIAG_PROXY_VERSION_STATUS=not_executed_unknown
}

thread_snapshot() {
  local pid path tid stat rest fields ticks start count=0
  DIAG_THREAD_TRUNCATED=0
  for pid in $PROXY_PIDS; do
    for path in "$PROC_ROOT/$pid/task"/[0-9]*/stat; do
      [ -r "$path" ] || continue
      [ "$count" -lt 512 ] || { DIAG_THREAD_TRUNCATED=1; break 2; }
      read -r stat < "$path" || continue
      rest="${stat##*) }"
      read -r -a fields <<< "$rest"
      [ "${#fields[@]}" -ge 20 ] || continue
      is_uint "${fields[11]}" && is_uint "${fields[12]}" && is_uint "${fields[19]}" || continue
      ticks=$(( fields[11] + fields[12] )); start="${fields[19]}"
      tid="${path%/stat}"; tid="${tid##*/}"
      printf '%s %s %s %s\n' "$pid" "$tid" "$start" "$ticks"
      count=$(( count + 1 ))
    done
  done
}
collect_threads() {
  local stamp hz prev="$WORKDIR/diagnostics-threads.prev" next="$WORKDIR/diagnostics-threads.next.$$" rows
  stamp=$(awk '{printf "%.0f\n", $1 * 1000}' "$PROC_ROOT/uptime" 2>/dev/null || true)
  hz=$(getconf CLK_TCK 2>/dev/null || true)
  DIAG_THREAD_SCOPE=up_to_512_threads_top_8
  DIAG_THREAD_CPU_STATUS=unavailable; DIAG_THREAD_TOP=""; DIAG_THREAD_MAX_CPU_BP=unknown
  is_uint "$stamp" && is_uint "$hz" && [ "$hz" -gt 0 ] || return 0
  {
    printf 'time %s %s\n' "$stamp" "$hz"
    thread_snapshot
  } > "$next"
  if [ -s "$prev" ]; then
    rows=$(awk '
      NR == FNR {if ($1=="time") {old_ms=$2; old_hz=$3} else ticks[$1 ":" $2 ":" $3]=$4; next}
      $1=="time" {elapsed=$2-old_ms; hz=$3; next}
      elapsed>0 && hz==old_hz && ($1 ":" $2 ":" $3 in ticks) {
        delta=$4-ticks[$1 ":" $2 ":" $3]
        if (delta>=0) printf "%s %s %.0f\n", $1,$2,delta*10000000/(hz*elapsed)
      }' "$prev" "$next" | sort -k3,3nr | head -n 8)
    if [ -n "$rows" ]; then
      DIAG_THREAD_CPU_STATUS=sampled_one_core_10000bp
      DIAG_THREAD_MAX_CPU_BP=$(printf '%s\n' "$rows" | awk 'NR==1 {print $3}')
      DIAG_THREAD_TOP=$(printf '%s\n' "$rows" | awk '{printf "%spid=%s/tid=%s:%sbp", (NR>1?"; ":""),$1,$2,$3}')
    else DIAG_THREAD_CPU_STATUS=warming_up_or_process_changed; fi
  else DIAG_THREAD_CPU_STATUS=warming_up; fi
  mv -f "$next" "$prev"
}

parse_socket_sample() {
  awk -v targets="$SAME_NETNS_PIDS" '
    BEGIN {split(targets,pids," "); n=0; rtt=-1; rcv=0; snd=0; queued=0; drops=0; memseen=0}
    !/^[[:space:]]/ {
      selected=0
      for(i in pids) if(index($0,"pid=" pids[i] ",")) {selected=1; break}
      if(selected) n++
    }
    selected {
      for(i=1;i<=NF;i++) {
        if($i ~ /^rtt:[0-9]/) {split($i,a,":"); split(a[2],b,"/"); v=b[1]*1000; if(v>rtt) rtt=v}
        if($i ~ /^skmem:/) {
          t=$i; sub(/^skmem:\(/,"",t); sub(/\).*$/,"",t); k=split(t,a,",")
          for(j=1;j<=k;j++) {
            if(a[j] ~ /^r[0-9]+$/) {v=a[j]; sub(/^r/,"",v); rcv+=v; memseen=1}
            if(a[j] ~ /^t[0-9]+$/) {v=a[j]; sub(/^t/,"",v); snd+=v; memseen=1}
            if(a[j] ~ /^w[0-9]+$/) {v=a[j]; sub(/^w/,"",v); queued+=v; memseen=1}
            if(a[j] ~ /^d[0-9]+$/) {v=a[j]; sub(/^d/,"",v); drops+=v; memseen=1}
          }
        }
      }
    }
    END {printf "%d %s %s %s %s %s\n",n,(rtt<0?"unknown":sprintf("%.0f",rtt)),(memseen?sprintf("%.0f",rcv):"unknown"),(memseen?sprintf("%.0f",snd):"unknown"),(memseen?sprintf("%.0f",queued):"unknown"),(memseen?sprintf("%.0f",drops):"unknown")}' "$1"
}
collect_rtt_identity() {
  local sample="$1" total="$2" peers="$WORKDIR/diagnostics-peers.$$" counts matched complete
  DIAG_RTT_VALID=0; DIAG_RTT_US=unknown; DIAG_FLOW_FINGERPRINT=unknown
  [ -n "$SAME_NETNS_PIDS" ] || return 0
  counts=$(awk -v targets="$SAME_NETNS_PIDS" -v peers="$peers" '
    BEGIN {split(targets,pids," "); selected=0; matched=0; complete=0}
    !/^[[:space:]]/ {
      selected=0
      for(i in pids) if(index($0,"pid=" pids[i] ",")) {selected=1; break}
      if(selected) {
        matched++
        for(i=1;i<=3 && i+3<=NF;i++) if($i ~ /^[0-9]+$/ && $(i+1) ~ /^[0-9]+$/) {print $(i+3) > peers; break}
      }
    }
    selected {for(i=1;i<=NF;i++) if($i ~ /^rtt:[0-9]+([.][0-9]+)?\//) {complete++; break}}
    END {print matched+0,complete+0}' "$sample")
  read -r matched complete <<< "$counts"
  if [ -s "$peers" ]; then
    DIAG_FLOW_FINGERPRINT=$({ printf 'pids=%s\n' "$SAME_NETNS_PIDS"; LC_ALL=C sort "$peers" | uniq -c; } | cksum | awk '{print $1 ":" $2}')
  fi
  rm -f "$peers"
  if [ "$DIAG_PROXY_NETNS_STATUS" = same ] && [ "$DIAG_PROCESS_TRUNCATED" -eq 0 ] && is_uint "$DIAG_PROXY_RTT_MAX_US" && [ "$matched" -gt 0 ] && [ "$matched" -eq "$complete" ] && [ "$total" -lt 100 ] && [ "$DIAG_FLOW_FINGERPRINT" != unknown ]; then
    DIAG_RTT_US="$DIAG_PROXY_RTT_MAX_US"; DIAG_RTT_VALID=1
  fi
}

collect_sockets() {
  local sample="$WORKDIR/diagnostics-ss.$$" rc protocol count values tcp_count=unknown udp_count=unknown tcp_sampled=0 udp_sampled=0
  DIAG_MONOTONIC_MS=$(awk '{printf "%.0f\n", $1*1000}' "$PROC_ROOT/uptime" 2>/dev/null || true)
  is_uint "$DIAG_MONOTONIC_MS" || DIAG_MONOTONIC_MS=$(( DIAG_UPDATED_MONO * 1000 ))
  DIAG_RTT_VALID=0; DIAG_RTT_US=unknown; DIAG_FLOW_FINGERPRINT=unknown
  DIAG_SOCKET_STATUS=unavailable; DIAG_SOCKET_SCOPE=up_to_100_tcp_and_100_udp_current_netns
  DIAG_SOCKET_COUNT=unknown; DIAG_PROXY_SOCKET_COUNT=unknown; DIAG_PROXY_RTT_MAX_US=unknown
  DIAG_PROXY_RCVBUF_ALLOC=unknown; DIAG_PROXY_SNDBUF_ALLOC=unknown; DIAG_PROXY_SNDBUF_QUEUED=unknown
  DIAG_PROXY_UDP_SOCKET_COUNT=unknown; DIAG_PROXY_UDP_RCVBUF_ALLOC=unknown; DIAG_PROXY_UDP_SNDBUF_ALLOC=unknown
  DIAG_PROXY_UDP_SNDBUF_QUEUED=unknown; DIAG_PROXY_UDP_SOCKET_DROPS=unknown
  DIAG_PROXY_SOCKET_STATUS="netns_${DIAG_PROXY_NETNS_STATUS}"
  if ! command -v ss >/dev/null 2>&1; then DIAG_SOCKET_STATUS=ss_unavailable; return 0; fi
  for protocol in tcp udp; do
    if [ "$protocol" = tcp ]; then
      bounded 3 ss -H -t -i -n -m -p state established 2>/dev/null |
        awk '!/^[[:space:]]/ {n++; if(n>100) exit} {print}' > "$sample"
    else
      bounded 3 ss -H -u -a -n -m -p 2>/dev/null |
        awk '!/^[[:space:]]/ {n++; if(n>100) exit} {print}' > "$sample"
    fi
    rc=${PIPESTATUS[0]}
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 141 ]; then continue; fi
    count=$(awk '!/^[[:space:]]/ {n++} END {print n+0}' "$sample")
    if [ "$protocol" = tcp ]; then tcp_count="$count"; tcp_sampled=1
    else udp_count="$count"; udp_sampled=1; fi
    [ -n "$SAME_NETNS_PIDS" ] || continue
    values=$(parse_socket_sample "$sample")
    if [ "$protocol" = tcp ]; then
      local ignored
      read -r DIAG_PROXY_SOCKET_COUNT DIAG_PROXY_RTT_MAX_US DIAG_PROXY_RCVBUF_ALLOC DIAG_PROXY_SNDBUF_ALLOC DIAG_PROXY_SNDBUF_QUEUED ignored <<< "$values"
      collect_rtt_identity "$sample" "$count"
    else
      local ignored
      read -r DIAG_PROXY_UDP_SOCKET_COUNT ignored DIAG_PROXY_UDP_RCVBUF_ALLOC DIAG_PROXY_UDP_SNDBUF_ALLOC DIAG_PROXY_UDP_SNDBUF_QUEUED DIAG_PROXY_UDP_SOCKET_DROPS <<< "$values"
    fi
  done
  rm -f "$sample"
  if [ "$tcp_sampled" -eq 1 ] && [ "$udp_sampled" -eq 1 ]; then
    DIAG_SOCKET_STATUS=sampled; DIAG_SOCKET_COUNT=$(( tcp_count + udp_count ))
  elif [ "$tcp_sampled" -eq 1 ] || [ "$udp_sampled" -eq 1 ]; then DIAG_SOCKET_STATUS=partial_sample
  else DIAG_SOCKET_STATUS=timeout_or_unavailable; fi
  if [ -n "$SAME_NETNS_PIDS" ]; then DIAG_PROXY_SOCKET_STATUS="${DIAG_SOCKET_STATUS}_matching_pids_not_complete"; fi
}

collect_memory_network() {
  DIAG_MEM_AVAILABLE_KB=$(awk '/^MemAvailable:/ {print $2; found=1; exit} END {if(!found) print "unknown"}' "$PROC_ROOT/meminfo" 2>/dev/null || true)
  DIAG_MEM_AVAILABLE_KB="${DIAG_MEM_AVAILABLE_KB:-unknown}"
  DIAG_UDP_MEM_PAGES=$(awk '$1=="UDP:" {for(i=2;i<NF;i++) if($i=="mem") {print $(i+1); found=1; exit}} END {if(!found) print "unknown"}' "$PROC_ROOT/net/sockstat" 2>/dev/null || true)
  DIAG_UDP_MEM_PAGES="${DIAG_UDP_MEM_PAGES:-unknown}"
  DIAG_UDP6_SOCKETS=$(awk '$1=="UDP6:" {for(i=2;i<NF;i++) if($i=="inuse") {print $(i+1); found=1; exit}} END {if(!found) print "unknown"}' "$PROC_ROOT/net/sockstat6" 2>/dev/null || true)
  DIAG_UDP6_SOCKETS="${DIAG_UDP6_SOCKETS:-unknown}"
  DIAG_MEMORY_PSI=$(awk '/^(some|full) / {printf "%s%s", (NR>1?"; ":""),$0}' "$PROC_ROOT/pressure/memory" 2>/dev/null || true)
  DIAG_MEMORY_PSI="${DIAG_MEMORY_PSI:-unavailable}"
  DIAG_CPU_PSI=$(awk '/^some / {print; exit}' "$PROC_ROOT/pressure/cpu" 2>/dev/null || true)
  DIAG_CPU_PSI="${DIAG_CPU_PSI:-unavailable}"
  DIAG_CONNTRACK_COUNT=$(read_number "$PROC_ROOT/sys/net/netfilter/nf_conntrack_count")
  DIAG_CONNTRACK_MAX=$(read_number "$PROC_ROOT/sys/net/netfilter/nf_conntrack_max")
  DIAG_IPV4_COUNTERS=$(awk '
    $1=="Ip:" && !iph {for(i=2;i<=NF;i++) ip[i]=$i; iph=1; next}
    $1=="Ip:" && iph {for(i=2;i<=NF;i++) if(ip[i] ~ /^(ReasmReqds|ReasmFails|ReasmOKs|FragFails|FragCreates)$/) printf "%s=%s ",ip[i],$i; iph=0}
    $1=="Udp:" && !uh {for(i=2;i<=NF;i++) u[i]=$i; uh=1; next}
    $1=="Udp:" && uh {for(i=2;i<=NF;i++) if(u[i] ~ /^(InErrors|RcvbufErrors|SndbufErrors|InCsumErrors|NoPorts)$/) printf "Udp%s=%s ",u[i],$i; uh=0}
    ' "$PROC_ROOT/net/snmp" 2>/dev/null || true)
  DIAG_IPV4_COUNTERS="${DIAG_IPV4_COUNTERS:-unavailable}"
  DIAG_IPV6_COUNTERS=$(awk '$1 ~ /^(Ip6ReasmReqds|Ip6ReasmOKs|Ip6ReasmFails|Ip6FragFails|Ip6FragCreates|Udp6InErrors|Udp6RcvbufErrors|Udp6SndbufErrors|Udp6InCsumErrors|Udp6NoPorts)$/ {printf "%s=%s ",$1,$2}' "$PROC_ROOT/net/snmp6" 2>/dev/null || true)
  DIAG_IPV6_COUNTERS="${DIAG_IPV6_COUNTERS:-unavailable}"
  DIAG_COUNTER_SCOPE=current_network_namespace_cumulative_not_end_to_end_loss
}

classify_data_plane() {
  local tcp=0 udp=0 ip4 ip6 current previous=unknown
  DIAG_DATA_PLANE=Unknown; DIAG_FORWARD_DELTA=unknown
  is_uint "$DIAG_PROXY_SOCKET_COUNT" && [ "$DIAG_PROXY_SOCKET_COUNT" -gt 0 ] && tcp=1
  is_uint "$DIAG_PROXY_UDP_SOCKET_COUNT" && [ "$DIAG_PROXY_UDP_SOCKET_COUNT" -gt 0 ] && udp=1
  if [ "$PROXY_COUNT" -gt 0 ]; then
    if [ "$DIAG_PROXY_NETNS_STATUS" = different ]; then DIAG_DATA_PLANE=Proxy-other-netns
    elif [ "$tcp" -eq 1 ] && [ "$udp" -eq 1 ]; then DIAG_DATA_PLANE=Proxy-local/TCP+UDP
    elif [ "$tcp" -eq 1 ]; then DIAG_DATA_PLANE=Proxy-local/TCP
    elif [ "$udp" -eq 1 ]; then DIAG_DATA_PLANE=Proxy-local/UDP
    else DIAG_DATA_PLANE=Proxy-local/Protocols-unknown; fi
  fi
  ip4=$(awk '$1=="Ip:" && !seen {for(i=2;i<=NF;i++) h[i]=$i; seen=1; next} $1=="Ip:" && seen {for(i=2;i<=NF;i++) if(h[i]=="ForwDatagrams") print $i; exit}' "$PROC_ROOT/net/snmp" 2>/dev/null || true)
  ip6=$(awk '$1=="Ip6OutForwDatagrams" {print $2; exit}' "$PROC_ROOT/net/snmp6" 2>/dev/null || true)
  if is_uint "$ip4" || is_uint "$ip6"; then
    is_uint "$ip4" || ip4=0; is_uint "$ip6" || ip6=0
    current=$(( ip4 + ip6 ))
    [ ! -r "$WORKDIR/diagnostics-forward.prev" ] || read -r previous < "$WORKDIR/diagnostics-forward.prev" || true
    if is_uint "$previous" && [ "$current" -ge "$previous" ]; then
      DIAG_FORWARD_DELTA=$(( current - previous ))
      if [ "$DIAG_FORWARD_DELTA" -gt 0 ]; then
        if [ "$DIAG_DATA_PLANE" = Unknown ]; then DIAG_DATA_PLANE=Forward-observed
        else DIAG_DATA_PLANE="${DIAG_DATA_PLANE}+Forward-observed"; fi
      fi
    fi
    printf '%s\n' "$current" > "$WORKDIR/diagnostics-forward.prev"
  fi
}

collect_link() {
  DIAG_LINK_MTU=unknown; DIAG_ROUTE_MTU=unknown; DIAG_OFFLOADS=unavailable
  DIAG_OFFLOAD_SCOPE=device_flags_not_proof_of_application_udp_gso
  if [[ "$DEV" =~ ^[A-Za-z0-9_.:-]+$ ]]; then
    DIAG_LINK_MTU=$(read_number "$SYS_ROOT/class/net/$DEV/mtu")
    local route output
    route=$(bounded 2 ip -o route show default dev "$DEV" 2>/dev/null || true)
    DIAG_ROUTE_MTU=$(printf '%s\n' "$route" | awk '{for(i=1;i<NF;i++) if($i=="mtu") {print $(i+1); found=1; exit}} END {if(!found) print "not_explicitly_set"}')
    output=$(bounded 2 ethtool -k "$DEV" 2>/dev/null | awk '/^[[:space:]]*(generic-segmentation-offload|generic-receive-offload|tcp-segmentation-offload|tx-udp-segmentation|rx-udp-gro-forwarding|rx-gro-list):/ {printf "%s%s",(n++?"; ":""),$0}')
    DIAG_OFFLOADS="${output:-unavailable}"
  fi
}

probe_mtu() {
  local host="${MTU_PROBE_HOST:-}" payload="${MTU_PROBE_PAYLOAD:-1200}" result rc
  DIAG_MTU_PROBE_STATUS=not_requested; DIAG_MTU_PROBE_RESULT=""
  [ -n "$host" ] || return 0
  if ! [[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9.:%_-]*$ ]] || [ "${#host}" -gt 253 ]; then
    DIAG_MTU_PROBE_STATUS=invalid_target; return 1
  fi
  if command -v tracepath >/dev/null 2>&1; then
    result=$(bounded 8 tracepath -n -m 12 "$host" 2>&1); rc=$?
    DIAG_MTU_PROBE_STATUS=tracepath_result_requires_interpretation
  elif command -v ping >/dev/null 2>&1; then
    is_uint "$payload" && [ "$payload" -ge 64 ] && [ "$payload" -le 1452 ] || payload=1200
    result=$(bounded 5 ping -n -c 2 -W 1 -M do -s "$payload" "$host" 2>&1); rc=$?
    DIAG_MTU_PROBE_STATUS="ping_payload_${payload}_not_full_pmtu_discovery"
  else DIAG_MTU_PROBE_STATUS=tools_unavailable; return 0; fi
  [ "$rc" -eq 0 ] || DIAG_MTU_PROBE_STATUS="${DIAG_MTU_PROBE_STATUS}_inconclusive"
  DIAG_MTU_PROBE_RESULT="${result:0:3000}"
}

write_diagnostics() {
  local temporary="$DIAG_STATE_FILE.tmp.$$" variable
  {
    for variable in DIAG_DEV DIAG_CONTROLLER_GENERATION DIAG_MONOTONIC_MS DIAG_RTT_US DIAG_RTT_VALID DIAG_FLOW_FINGERPRINT DIAG_UPDATED_MONO DIAG_PROXY_STATUS DIAG_DATA_PLANE DIAG_FORWARD_DELTA DIAG_PROXY_PROCESSES DIAG_PROXY_VERSION_STATUS DIAG_PROXY_NETNS_STATUS DIAG_PROCESS_TRUNCATED DIAG_THREAD_CPU_STATUS DIAG_THREAD_SCOPE DIAG_THREAD_TOP DIAG_THREAD_MAX_CPU_BP DIAG_SOCKET_STATUS DIAG_SOCKET_SCOPE DIAG_SOCKET_COUNT DIAG_PROXY_SOCKET_STATUS DIAG_PROXY_SOCKET_COUNT DIAG_PROXY_RTT_MAX_US DIAG_PROXY_RCVBUF_ALLOC DIAG_PROXY_SNDBUF_ALLOC DIAG_PROXY_SNDBUF_QUEUED DIAG_PROXY_UDP_SOCKET_COUNT DIAG_PROXY_UDP_RCVBUF_ALLOC DIAG_PROXY_UDP_SNDBUF_ALLOC DIAG_PROXY_UDP_SNDBUF_QUEUED DIAG_PROXY_UDP_SOCKET_DROPS DIAG_MEM_AVAILABLE_KB DIAG_UDP_MEM_PAGES DIAG_UDP6_SOCKETS DIAG_MEMORY_PSI DIAG_CPU_PSI DIAG_CONNTRACK_COUNT DIAG_CONNTRACK_MAX DIAG_IPV4_COUNTERS DIAG_IPV6_COUNTERS DIAG_COUNTER_SCOPE DIAG_LINK_MTU DIAG_ROUTE_MTU DIAG_OFFLOADS DIAG_OFFLOAD_SCOPE DIAG_MTU_PROBE_STATUS DIAG_MTU_PROBE_RESULT DIAG_APP_BATCH_STATUS DIAG_APP_PACING_STATUS DIAG_APP_FEC_STATUS DIAG_APP_HEARTBEAT_STATUS; do
      printf '%s=%q\n' "$variable" "${!variable:-unknown}"
    done
  } > "$temporary" && mv -f "$temporary" "$DIAG_STATE_FILE"
}
# flock automatically releases on death. The directory fallback records PID birth
# time and serializes stale recovery; a live owner is never evicted for its age.
lock_process_birth() {
  local line rest fields
  is_uint "$1" && [ -r "$PROC_ROOT/$1/stat" ] || return 1
  read -r line < "$PROC_ROOT/$1/stat" || return 1
  rest="${line##*) }"; read -r -a fields <<< "$rest"
  [ "${#fields[@]}" -ge 20 ] && is_uint "${fields[19]}" || return 1
  printf '%s\n' "${fields[19]}"
}
lock_directory_age() {
  local modified epoch
  modified=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || true)
  epoch=$(date +%s)
  is_uint "$modified" && is_uint "$epoch" || { printf '0\n'; return; }
  [ "$epoch" -ge "$modified" ] && printf '%s\n' "$(( epoch - modified ))" || printf '0\n'
}
lock_owner_alive() {
  local directory="$1" owner="" birth="" actual="" commandline="" age
  if [ -r "$directory/owner" ]; then read -r owner birth < "$directory/owner" || true
  elif [ -r "$directory/pid" ]; then read -r owner < "$directory/pid" || true; fi
  if is_uint "$owner" && [ "$owner" -gt 0 ] && kill -0 "$owner" 2>/dev/null; then
    actual=$(lock_process_birth "$owner" || true)
    if is_uint "$birth" && is_uint "$actual"; then [ "$birth" = "$actual" ]; return; fi
    commandline=$(tr '\0' ' ' < "$PROC_ROOT/$owner/cmdline" 2>/dev/null || true)
    case "$commandline" in *"${0##*/}"*) return 0 ;; esac
    # During creation the owner record may not yet exist. Wait before recovering
    # an unverifiable legacy lock; it cannot block diagnostics indefinitely.
    age=$(lock_directory_age "$directory"); [ "$age" -lt 120 ]; return
  fi
  # A complete record for a dead owner is immediately stale.
  is_uint "$owner" && [ "$owner" -gt 0 ] && return 1
  age=$(lock_directory_age "$directory"); [ "$age" -lt 120 ]
}
release_job_lock() {
  local owner="" birth=""
  if [ "${JOB_LOCK_KIND:-}" = mkdir ] && [ -n "${JOB_LOCK_DIR:-}" ]; then
    [ ! -r "$JOB_LOCK_DIR/owner" ] || read -r owner birth < "$JOB_LOCK_DIR/owner" || true
    if [ "$owner" = "$$" ] && [ "$birth" = "${JOB_LOCK_BIRTH:-unknown}" ]; then
      rm -f "$JOB_LOCK_DIR/owner" "$JOB_LOCK_DIR/pid"
      rmdir "$JOB_LOCK_DIR" 2>/dev/null || true
    fi
  elif [ "${JOB_LOCK_KIND:-}" = flock ]; then
    exec 9>&-
  fi
  JOB_LOCK_KIND=""; JOB_LOCK_DIR=""
}
acquire_job_lock() {
  local name="$1" directory="$WORKDIR/$1.lock.d" reaper stale birth owner other_birth
  JOB_LOCK_KIND=""; JOB_LOCK_DIR=""
  # Honor a live legacy collector during upgrades even when flock is available.
  if [ -d "$directory" ] && lock_owner_alive "$directory"; then return 1; fi
  if command -v flock >/dev/null 2>&1; then
    exec 9> "$WORKDIR/$name.lock" || return 1
    flock -n 9 || { exec 9>&-; return 1; }
    JOB_LOCK_KIND=flock
  else
    reaper="$directory.reap"
    if ! mkdir "$directory" 2>/dev/null; then
      lock_owner_alive "$directory" && return 1
      if ! mkdir "$reaper" 2>/dev/null; then
        lock_owner_alive "$reaper" && return 1
        # Recover only a dead, old recovery owner. The live-owner check is
        # repeated immediately before the atomic rename.
        [ "$(lock_directory_age "$reaper")" -ge 120 ] || return 1
        lock_owner_alive "$reaper" && return 1
        stale="$reaper.stale.$$.$RANDOM"
        mv "$reaper" "$stale" 2>/dev/null || return 1
        rm -rf "$stale"
        mkdir "$reaper" 2>/dev/null || return 1
      fi
      birth=$(lock_process_birth "$$" || true); birth="${birth:-unknown}"
      printf '%s %s\n' "$$" "$birth" > "$reaper/owner"
      if lock_owner_alive "$directory"; then rm -f "$reaper/owner"; rmdir "$reaper" 2>/dev/null || true; return 1; fi
      stale="$directory.stale.$$.$RANDOM"
      if ! mv "$directory" "$stale" 2>/dev/null; then rm -f "$reaper/owner"; rmdir "$reaper" 2>/dev/null || true; return 1; fi
      if ! mkdir "$directory" 2>/dev/null; then
        rm -f "$reaper/owner"; rmdir "$reaper" 2>/dev/null || true; rm -rf "$stale"; return 1
      fi
      rm -rf "$stale"
      rm -f "$reaper/owner"; rmdir "$reaper" 2>/dev/null || true
    fi
    birth=$(lock_process_birth "$$" || true); JOB_LOCK_BIRTH="${birth:-unknown}"
    JOB_LOCK_KIND=mkdir; JOB_LOCK_DIR="$directory"
    trap release_job_lock EXIT
    trap 'exit 143' TERM
    trap 'exit 130' INT
    printf '%s %s\n' "$$" "$JOB_LOCK_BIRTH" > "$directory/owner.tmp.$$" || return 1
    mv -f "$directory/owner.tmp.$$" "$directory/owner" || return 1
    printf '%s\n' "$$" > "$directory/pid" || return 1
  fi
  trap release_job_lock EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT
  return 0
}
collect() {
  local stamp previous=0
  acquire_job_lock diagnostics || return 0
  stamp=$(now_seconds)
  is_uint "$stamp" || return 1
  [ ! -r "$WORKDIR/diagnostics-last" ] || read -r previous < "$WORKDIR/diagnostics-last" || true
  is_uint "$previous" || previous=0
  if [ "$stamp" -ge "$previous" ] && [ $(( stamp - previous )) -lt "$DIAG_INTERVAL" ] && [ -r "$DIAG_STATE_FILE" ]; then return 0; fi
  DIAG_DEV="$DEV"
  DIAG_CONTROLLER_GENERATION="${CONTROLLER_GENERATION:-standalone}"
  DIAG_UPDATED_MONO="$stamp"
  DIAG_MONOTONIC_MS=$(awk '{printf "%.0f\n", $1*1000}' "$PROC_ROOT/uptime" 2>/dev/null || true)
  is_uint "$DIAG_MONOTONIC_MS" || DIAG_MONOTONIC_MS=$(( stamp * 1000 ))
  find_proxies
  collect_threads
  collect_sockets
  collect_memory_network
  classify_data_plane
  collect_link
  # Probes run only through the explicit probe-mtu subcommand.
  DIAG_MTU_PROBE_STATUS=not_requested; DIAG_MTU_PROBE_RESULT=""
  DIAG_APP_BATCH_STATUS=unknown_requires_application_support
  DIAG_APP_PACING_STATUS=unknown_device_fq_does_not_prove_udp_pacing
  DIAG_APP_FEC_STATUS=unknown_requires_protocol_and_both_endpoints
  DIAG_APP_HEARTBEAT_STATUS=unknown_requires_application_and_peer_configuration
  write_diagnostics || return 1
  printf '%s\n' "$stamp" > "$WORKDIR/diagnostics-last"
}

unit_value() { bounded 3 systemctl show --property="$2" --value -- "$1" 2>/dev/null; }
validate_affinity() {
  local list="$1" allowed="$2" item start end cpu allowed_item lo hi found count=0
  [[ "$list" =~ ^[0-9]+([,-][0-9]+)*$ ]] || return 1
  [[ "$allowed" =~ ^[0-9]+([,-][0-9]+)*$ ]] || return 1
  for item in ${list//,/ }; do
    if [[ "$item" =~ ^([0-9]+)-([0-9]+)$ ]]; then start="${BASH_REMATCH[1]}"; end="${BASH_REMATCH[2]}"
    elif is_uint "$item"; then start="$item"; end="$item"
    else return 1; fi
    [ "${#start}" -le 5 ] && [ "${#end}" -le 5 ] || return 1
    start=$(( 10#$start )); end=$(( 10#$end ))
    [ "$start" -le "$end" ] && [ "$end" -le 65535 ] || return 1
    for ((cpu=start; cpu<=end; cpu++)); do
      count=$(( count + 1 )); [ "$count" -le 4096 ] || return 1
      found=0
      for allowed_item in ${allowed//,/ }; do
        if [[ "$allowed_item" =~ ^([0-9]+)-([0-9]+)$ ]]; then lo="${BASH_REMATCH[1]}"; hi="${BASH_REMATCH[2]}"
        elif is_uint "$allowed_item"; then lo="$allowed_item"; hi="$allowed_item"
        else return 1; fi
        if [ "$cpu" -ge "$lo" ] && [ "$cpu" -le "$hi" ]; then found=1; break; fi
      done
      [ "$found" -eq 1 ] || return 1
    done
  done
}
prepare_adapter() {
  ADAPTER_UNIT="$1"
  valid_unit "$ADAPTER_UNIT" || { echo 'Invalid service unit.' >&2; return 1; }
  [ "$(unit_value "$ADAPTER_UNIT" LoadState)" = loaded ] || { echo 'Service is not loaded or systemd/timeout is unavailable.' >&2; return 1; }
  ADAPTER_FRAGMENT=$(unit_value "$ADAPTER_UNIT" FragmentPath) || return 1
  [ -r "$ADAPTER_FRAGMENT" ] && [ -f "$ADAPTER_FRAGMENT" ] || { echo 'Readable service fragment required.' >&2; return 1; }
  ADAPTER_LIMIT="${ADAPTER_LIMIT_NOFILE:-1048576}"
  local nr_open pid allowed
  nr_open=$(read_number "$PROC_ROOT/sys/fs/nr_open")
  is_uint "$nr_open" || nr_open=1048576
  is_uint "$ADAPTER_LIMIT" && [ "${#ADAPTER_LIMIT}" -le 9 ] && [ "$ADAPTER_LIMIT" -ge 1024 ] && [ "$ADAPTER_LIMIT" -le "$nr_open" ] || { echo 'LimitNOFILE exceeds supported range.' >&2; return 1; }
  ADAPTER_LIMIT=$(( 10#$ADAPTER_LIMIT ))
  ADAPTER_AFFINITY="${ADAPTER_CPU_AFFINITY:-}"
  if [ -n "$ADAPTER_AFFINITY" ]; then
    pid=$(unit_value "$ADAPTER_UNIT" MainPID) || return 1
    is_uint "$pid" && [ "$pid" -gt 0 ] || { echo 'A running target is required to validate CPU affinity.' >&2; return 1; }
    allowed=$(awk '/^Cpus_allowed_list:/ {print $2; exit}' "$PROC_ROOT/$pid/status" 2>/dev/null || true)
    validate_affinity "$ADAPTER_AFFINITY" "$allowed" || { echo 'CPUAffinity must be a valid subset of the target process allowed CPUs.' >&2; return 1; }
  fi
}
print_adapter() {
  printf '[Service]\nLimitNOFILE=%s\n' "$ADAPTER_LIMIT"
  if [ -n "$ADAPTER_AFFINITY" ]; then printf 'CPUAffinity=\nCPUAffinity=%s\n' "${ADAPTER_AFFINITY//,/ }"; fi
}
file_digest() {
  local file="$1" algorithm="${2:-auto}" value
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  if [ "$algorithm" = auto ] || [ "$algorithm" = sha256 ]; then
    if command -v sha256sum >/dev/null 2>&1; then value=$(sha256sum < "$file" | awk '{print $1}')
    elif command -v shasum >/dev/null 2>&1; then value=$(shasum -a 256 < "$file" | awk '{print $1}')
    elif [ "$algorithm" = sha256 ]; then return 1
    else value=""; fi
    if [ -n "$value" ]; then printf 'sha256:%s\n' "$value"; return 0; fi
  fi
  case "$algorithm" in auto|cksum) value=$(cksum < "$file") || return 1; printf 'cksum:%s\n' "$value" ;; *) return 1 ;; esac
}
validate_adapter_backup() {
  local backup="$1" target="$2" marker expected actual recorded
  [ -d "$backup" ] && [ ! -L "$backup" ] || return 1
  [ -f "$backup/original.marker" ] && [ ! -L "$backup/original.marker" ] || return 1
  [ -f "$backup/target.path" ] && [ ! -L "$backup/target.path" ] || return 1
  read -r recorded < "$backup/target.path" || return 1
  [ "$recorded" = "$target" ] || return 1
  read -r marker < "$backup/original.marker" || return 1
  case "$marker" in
    present)
      [ -f "$backup/original.digest" ] && [ ! -L "$backup/original.digest" ] || return 1
      IFS= read -r expected < "$backup/original.digest" || return 1
      case "$expected" in sha256:*|cksum:*) : ;; *) return 1 ;; esac
      actual=$(file_digest "$backup/original.conf" "${expected%%:*}") || return 1
      [ "$actual" = "$expected" ] || return 1 ;;
    absent) [ ! -e "$backup/original.conf" ] && [ ! -L "$backup/original.conf" ] || return 1 ;;
    *) return 1 ;;
  esac
}
create_adapter_backup() {
  local target="$1" backup="$2" staging
  if [ -e "$backup" ] || [ -L "$backup" ]; then
    validate_adapter_backup "$backup" "$target" || { echo 'Existing adapter snapshot is incomplete, changed, or for another destination; it was retained.' >&2; return 1; }
    return 0
  fi
  mkdir -p "${backup%/*}" || return 1
  staging=$(mktemp -d "${backup%/*}/.snapshot.XXXXXX") || return 1
  if [ -f "$target" ] && [ ! -L "$target" ]; then
    if ! cp -p "$target" "$staging/original.conf" || ! file_digest "$staging/original.conf" > "$staging/original.digest"; then rm -rf "$staging"; return 1; fi
    printf 'present\n' > "$staging/original.marker"
  elif [ -e "$target" ] || [ -L "$target" ]; then rm -rf "$staging"; return 1
  else printf 'absent\n' > "$staging/original.marker"; fi
  printf '%s\n' "$target" > "$staging/target.path"
  validate_adapter_backup "$staging" "$target" || { rm -rf "$staging"; return 1; }
  mv "$staging" "$backup" || { rm -rf "$staging"; return 1; }
}
atomic_copy() {
  local source="$1" target="$2" temporary
  [ -f "$source" ] && [ ! -L "$source" ] || return 1
  [ ! -L "$target" ] && [ ! -L "${target%/*}" ] || return 1
  temporary=$(mktemp "${target%/*}/.live-relay.XXXXXX") || return 1
  if ! cp -p "$source" "$temporary" || ! mv -f "$temporary" "$target"; then rm -f "$temporary"; return 1; fi
}
save_adapter_previous() {
  local target="$1" stage="$2"
  if [ -f "$target" ] && [ ! -L "$target" ]; then
    cp -p "$target" "$stage/previous" && printf 'present\n' > "$stage/previous.marker"
  elif [ -e "$target" ] || [ -L "$target" ]; then return 1
  else printf 'absent\n' > "$stage/previous.marker"; fi
}
restore_adapter_previous() {
  local target="$1" stage="$2" marker
  read -r marker < "$stage/previous.marker" || return 1
  case "$marker" in present) atomic_copy "$stage/previous" "$target" ;; absent) rm -f "$target" ;; *) return 1 ;; esac
}
write_adapter_state() {
  local backup="$1" unit="$2" status="$3" temporary
  temporary=$(mktemp "$backup/.state.XXXXXX") || return 1
  if ! printf 'ADAPTER_UNIT=%q\nADAPTER_STATUS=%q\n' "$unit" "$status" > "$temporary" || ! mv -f "$temporary" "$backup/state.env"; then rm -f "$temporary"; return 1; fi
}
adapter_apply() {
  local unit="$1" directory target stage backup path drops managed=90-live-relay-performance.conf failure=0
  [ "${ENABLE_APP_ADAPTER:-0}" = 1 ] || { echo 'Set ENABLE_APP_ADAPTER=1 for an explicit application change.' >&2; return 1; }
  [ "${EUID:-$(id -u)}" -eq 0 ] || { echo 'Root is required.' >&2; return 1; }
  valid_unit "$unit" || return 1
  acquire_job_lock "application-adapter-$unit" || { echo 'An adapter operation is already running.' >&2; return 1; }
  prepare_adapter "$unit" || return 1
  command -v systemd-analyze >/dev/null 2>&1 || { echo 'systemd-analyze is required to validate the drop-in.' >&2; return 1; }
  directory="$SYSTEMD_ROOT/$unit.d"; target="$directory/$managed"
  [ ! -L "$directory" ] && [ ! -L "$target" ] || { echo 'Symlinked managed drop-in paths require manual review.' >&2; return 1; }
  stage=$(mktemp -d "$WORKDIR/adapter-verify.XXXXXX") || return 1
  mkdir -p "$stage/$unit.d" || { rm -rf "$stage"; return 1; }
  cp "$ADAPTER_FRAGMENT" "$stage/$unit" || { rm -rf "$stage"; return 1; }
  drops=$(unit_value "$unit" DropInPaths) || { rm -rf "$stage"; return 1; }
  for path in $drops; do
    case "$path" in *\\*) echo 'Escaped drop-in paths require manual review.' >&2; rm -rf "$stage"; return 1 ;; esac
    [ -f "$path" ] && cp "$path" "$stage/$unit.d/${path##*/}" || { rm -rf "$stage"; return 1; }
    if [[ "${path##*/}" > "$managed" ]] && awk -v affinity="$ADAPTER_AFFINITY" '
      /^[[:space:]]*LimitNOFILE[[:space:]]*=/ {found=1}
      affinity!="" && /^[[:space:]]*CPUAffinity[[:space:]]*=/ {found=1}
      END {exit !found}' "$path"; then
      echo 'A later service drop-in overrides the requested settings; resolve it explicitly first.' >&2
      rm -rf "$stage"; return 1
    fi
  done
  print_adapter > "$stage/$unit.d/$managed"
  chmod 0644 "$stage/$unit.d/$managed" || { rm -rf "$stage"; return 1; }
  if ! bounded 10 systemd-analyze verify --man=no "$stage/$unit" > "$stage/verify.log" 2>&1; then
    cat "$stage/verify.log" >&2; rm -rf "$stage"; return 1
  fi
  backup="$WORKDIR/application-adapters/$unit"
  mkdir -p "$directory" || { rm -rf "$stage"; return 1; }
  if ! save_adapter_previous "$target" "$stage" || ! create_adapter_backup "$target" "$backup"; then rm -rf "$stage"; return 1; fi
  if ! atomic_copy "$stage/$unit.d/$managed" "$target"; then rm -rf "$stage"; return 1; fi
  if ! bounded 5 systemctl daemon-reload || ! write_adapter_state "$backup" "$unit" pending_service_restart; then
    if ! restore_adapter_previous "$target" "$stage" || ! bounded 5 systemctl daemon-reload; then
      write_adapter_state "$backup" "$unit" apply_rollback_failed_backup_retained || true
      echo 'Adapter rollback could not be confirmed; original snapshot was retained.' >&2
    else write_adapter_state "$backup" "$unit" apply_failed_original_state_restored || true; fi
    rm -rf "$stage"; return 1
  fi
  rm -rf "$stage"
  echo "Drop-in installed for $unit; takes effect on a later service restart. The service was not restarted."
}
adapter_restore() {
  local unit="$1" backup marker target directory stage
  [ "${ENABLE_APP_ADAPTER:-0}" = 1 ] || { echo 'Set ENABLE_APP_ADAPTER=1 for an explicit application change.' >&2; return 1; }
  [ "${EUID:-$(id -u)}" -eq 0 ] || { echo 'Root is required.' >&2; return 1; }
  valid_unit "$unit" || return 1
  acquire_job_lock "application-adapter-$unit" || { echo 'An adapter operation is already running.' >&2; return 1; }
  backup="$WORKDIR/application-adapters/$unit"; directory="$SYSTEMD_ROOT/$unit.d"; target="$directory/90-live-relay-performance.conf"
  validate_adapter_backup "$backup" "$target" || { echo 'Adapter snapshot is missing, changed, or for another destination; no file was restored.' >&2; return 1; }
  [ ! -L "$directory" ] && [ ! -L "$target" ] || { echo 'Symlinked managed drop-in paths require manual review.' >&2; return 1; }
  mkdir -p "$directory" || return 1
  stage=$(mktemp -d "$WORKDIR/adapter-restore.XXXXXX") || return 1
  save_adapter_previous "$target" "$stage" || { rm -rf "$stage"; return 1; }
  read -r marker < "$backup/original.marker" || { rm -rf "$stage"; return 1; }
  case "$marker" in
    present) atomic_copy "$backup/original.conf" "$target" || { rm -rf "$stage"; return 1; } ;;
    absent) rm -f "$target" || { rm -rf "$stage"; return 1; } ;;
    *) rm -rf "$stage"; return 1 ;;
  esac
  if ! bounded 5 systemctl daemon-reload || ! write_adapter_state "$backup" "$unit" restored_pending_service_restart; then
    if ! restore_adapter_previous "$target" "$stage" || ! bounded 5 systemctl daemon-reload; then
      write_adapter_state "$backup" "$unit" restore_rollback_failed_backup_retained || true
      echo 'Restore rollback could not be confirmed; original snapshot was retained.' >&2
    else write_adapter_state "$backup" "$unit" restore_failed_previous_state_restored || true; fi
    rm -rf "$stage"; return 1
  fi
  rm -rf "$stage"
  echo "Original drop-in restored for $unit; the service was not restarted."
}

case "${1:-collect}" in
  collect) collect ;;
  status) [ ! -r "$DIAG_STATE_FILE" ] || cat "$DIAG_STATE_FILE" ;;
  probe-mtu) probe_mtu; probe_rc=$?; printf 'status=%s\n%s\n' "$DIAG_MTU_PROBE_STATUS" "$DIAG_MTU_PROBE_RESULT"; exit "$probe_rc" ;;
  adapter-plan) [ "$#" -eq 2 ] && prepare_adapter "$2" && print_adapter ;;
  adapter-apply) [ "$#" -eq 2 ] && adapter_apply "$2" ;;
  adapter-restore) [ "$#" -eq 2 ] && adapter_restore "$2" ;;
  *) echo 'Usage: diagnostics {collect|status|probe-mtu|adapter-plan SERVICE|adapter-apply SERVICE|adapter-restore SERVICE}' >&2; exit 2 ;;
esac
EOF_DIAGNOSTICS
  chmod +x "$DIAG_HELPER"
}

build_auto_controller() {
  cat > "$AUTO_HELPER" <<'EOF_AUTO'
#!/usr/bin/env bash
(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )) || { echo "Bash 4.4 or newer is required; no settings were changed." >&2; exit 1; }
set -u
umask 077

NIC_ENV_FILE="${NIC_ENV_FILE:-/etc/live-relay-nic.env}"
AUTO_ENV_FILE="${AUTO_ENV_FILE:-/etc/live-relay-auto.env}"
[ ! -f "$NIC_ENV_FILE" ] || source "$NIC_ENV_FILE"
[ ! -f "$AUTO_ENV_FILE" ] || source "$AUTO_ENV_FILE"
PROC_ROOT="${PROC_ROOT:-/proc}"
SYS_ROOT="${SYS_ROOT:-/sys}"
DEV="${DEV:-}"
WORKDIR="${WORKDIR:-/opt/live-relay-tuner}"
STATE_FILE="$WORKDIR/auto-state.env"
PAUSE_FILE="$WORKDIR/paused"
METRICS_LOG="$WORKDIR/metrics.log"
LOCK_DIR="$WORKDIR/controller.lock"
BEST_FILE="$WORKDIR/best-parameters.env"
PENDING_FILE="$WORKDIR/pending-parameters.env"
PENDING_META_FILE="$PENDING_FILE.meta"
BASELINE_FILE="$WORKDIR/baseline-parameters.env"
LOCK_FILE="$WORKDIR/controller.flock"
LOCK_METHOD=
LOCK_OWNER_TOKEN=
JOURNAL_OWNED=0
CONTROLLER_GENERATION="$$:${RANDOM}:${RANDOM}:$(date +%s)"
CPU_PREV_FILE="$WORKDIR/cpu-window.prev"
CPU_NOW_FILE="$WORKDIR/cpu-window.now"
DETAIL_FILE="$WORKDIR/detail-window.env"
DIAG_HELPER="${DIAG_HELPER:-/usr/local/sbin/live-relay-diagnostics.sh}"

uint() {
  local value="${1:-}" fallback="${2:-0}" maximum="${3:-2147483647}"
  case "$value" in ''|*[!0-9]*) value="$fallback" ;; esac
  [ "${#value}" -le 10 ] || value="$maximum"
  value=$(( 10#$value ))
  [ "$value" -le "$maximum" ] || value="$maximum"
  printf '%s\n' "$value"
}
INTERVAL=$(uint "${AUTO_INTERVAL:-1}" 1 60); [ "$INTERVAL" -gt 0 ] || INTERVAL=1
DETAIL_INTERVAL=$(uint "${AUTO_DETAIL_INTERVAL:-10}" 10 300); [ "$DETAIL_INTERVAL" -ge "$INTERVAL" ] || DETAIL_INTERVAL="$INTERVAL"
DIAG_INTERVAL=$(uint "${AUTO_DIAG_INTERVAL:-30}" 30 3600); [ "$DIAG_INTERVAL" -ge "$DETAIL_INTERVAL" ] || DIAG_INTERVAL="$DETAIL_INTERVAL"
UP_WINDOWS=$(uint "${AUTO_UP_WINDOWS:-3}" 3 60); [ "$UP_WINDOWS" -gt 0 ] || UP_WINDOWS=1
COOLDOWN_SECONDS=$(uint "${AUTO_COOLDOWN_SECONDS:-120}" 120 3600)
WARMUP_SECONDS=$(uint "${AUTO_WARMUP_SECONDS:-15}" 15 300)
TRIAL_SECONDS=$(uint "${AUTO_TRIAL_SECONDS:-30}" 30 300); [ "$TRIAL_SECONDS" -ge 5 ] || TRIAL_SECONDS=5
SOFTIRQ_HIGH=$(uint "${SOFTIRQ_HIGH:-70}" 70 100)
STEAL_HIGH=$(uint "${STEAL_HIGH:-5}" 5 100)
CPU_COUNT=$(uint "${ONLINE_CPUS:-1}" 1 1048576); [ "$CPU_COUNT" -gt 0 ] || CPU_COUNT=1
MEM_KB=$(uint "${MEMORY_KB:-1048576}" 1048576 2147483647)
PHYSICAL_COUNT=$(uint "${PHYSICAL_CORES:-$CPU_COUNT}" "$CPU_COUNT" 1048576)
NUMA_COUNT=$(uint "${NUMA_NODES:-1}" 1 65536)
RX_QUEUES=$(uint "${RX_QUEUE_COUNT:-1}" 1 1048576); [ "$RX_QUEUES" -gt 0 ] || RX_QUEUES=1
CURRENT_LEVEL=2
CURRENT_PPS=0; CURRENT_RX_PPS=0; CURRENT_TX_PPS=0; CURRENT_RX_BPS=0; CURRENT_TX_BPS=0
CURRENT_SOFTIRQ=0; CURRENT_HARDIRQ=0; CURRENT_STEAL=0; CURRENT_CPU_BUSY=0
CURRENT_SOFT_DROPS=0; CURRENT_DRIVER_DROPS=0; CURRENT_DROPS=0; CURRENT_SQUEEZE=0
CURRENT_UDP_RCVBUF=0; CURRENT_UDP_SNDBUF=0; CURRENT_UDP_ERRORS=0
CURRENT_RETRANS=0; CURRENT_RETRANS_BP=0; CURRENT_LISTEN_DROPS=0; CURRENT_QDISC_DROPS=0
CURRENT_QDISC_BACKLOG=0; CURRENT_QDISC_VALID=0; CURRENT_DRIVER_VALID=0; CURRENT_DETAIL_VALID=0
CURRENT_ERROR_RATE=0; CURRENT_RTT_US=0; CURRENT_RTT_VALID=0; CURRENT_PRESSURE_SCORE=0
CURRENT_METRICS_VALID=0; CURRENT_RESET=0; CURRENT_COOLDOWN=0
ACTIVE_BACKLOG=0; ACTIVE_BUDGET=0; ACTIVE_BUDGET_USECS=0; ACTIVE_WEIGHT=0; ACTIVE_COALESCE=0
ACTIVE_ADAPTIVE_RX=unknown; ACTIVE_ADAPTIVE_TX=unknown; COALESCE_SUPPORTED=0
TRIAL_ACTIVE=0; TRIAL_STATUS=baseline; VERIFICATION_SCOPE=unverified; TRIAL_GROUP=none
TRIAL_STARTED=0; TRIAL_SAMPLES=0; TRIAL_ERROR_SUM=0; TRIAL_RX_SUM=0; TRIAL_TX_SUM=0
BASE_ERROR=0; BASE_RX=0; BASE_TX=0; BASE_RTT=0; BASE_BACKLOG=0
HISTORY_SAMPLES=0; HISTORY_ERROR=0; HISTORY_RX=0; HISTORY_TX=0
HISTORY_RX_PPS=0; HISTORY_TX_PPS=0; HISTORY_KERNEL=0; HISTORY_SQUEEZE=0
HISTORY_UDP_SEND=0; HISTORY_RETRANS=0; HISTORY_LISTEN=0; HISTORY_QDISC=0
HISTORY_UDP_RCV=0; HISTORY_SOFTNET=0; HISTORY_DRIVER=0
CURRENT_ELAPSED_MS=1000; DETAIL_PID=; DIAG_PID=
LAST_REASON=controller_started; LAST_REJECTED_GROUP=none; LAST_REJECTED_AT=0
SNAPSHOT_KEYS=(net.core.netdev_max_backlog net.core.netdev_budget net.core.netdev_budget_usecs net.core.dev_weight)
PARAMETER_NAMES=(ACTIVE_BACKLOG ACTIVE_BUDGET ACTIVE_BUDGET_USECS ACTIVE_WEIGHT)
mkdir -p "$WORKDIR"

monotonic_millis() {
  local value
  value=$(awk '{printf "%.0f\n", $1*1000; exit}' "$PROC_ROOT/uptime" 2>/dev/null || true)
  case "$value" in ''|*[!0-9]*) value=$(( $(date +%s) * 1000 )) ;; esac
  printf '%s\n' "$value"
}
read_counter() {
  local value
  if [ -r "$1" ] && read -r value < "$1"; then
    case "$value" in ''|*[!0-9]*) ;; *) printf '%s\n' "$value"; return 0 ;; esac
  fi
  printf '%s\n' -1
  return 1
}
softnet_totals() {
  local line c1 c2 c3 rest dropped=0 squeezed=0 count=0
  [ -r "$PROC_ROOT/net/softnet_stat" ] || { echo '0 0 0'; return; }
  while read -r line; do
    read -r c1 c2 c3 rest <<< "$line"
    case "$c2:$c3" in *[!0-9a-fA-F:]*|:*|*:) echo '0 0 0'; return ;; esac
    dropped=$(( dropped + 16#$c2 )); squeezed=$(( squeezed + 16#$c3 )); count=$(( count + 1 ))
  done < "$PROC_ROOT/net/softnet_stat"
  [ "$count" -gt 0 ] && echo "$dropped $squeezed 1" || echo '0 0 0'
}
protocol_counters() {
  local v6="$PROC_ROOT/net/snmp6" require_v6=0
  [ ! -d "$PROC_ROOT/sys/net/ipv6" ] || require_v6=1
  [ -r "$PROC_ROOT/net/snmp" ] || { echo '0 0 0 0 0 0'; return; }
  [ -r "$v6" ] || v6=/dev/null
  awk -v require_v6="$require_v6" '
    FILENAME == ARGV[1] && ($1 == "Tcp:" || $1 == "Udp:") {
      kind=$1
      if ($2 !~ /^[0-9]+$/) { for(i=2;i<=NF;i++) h[kind,i]=$i; next }
      for(i=2;i<=NF;i++) { k=h[kind,i]; if(k!="") {v[kind,k]=$i; seen[kind,k]=1} }
    }
    FILENAME == ARGV[2] && $1 ~ /^Udp6/ {v6[$1]=$2; s6[$1]=1}
    END {
      valid=seen["Tcp:","RetransSegs"] && seen["Tcp:","OutSegs"] && seen["Udp:","InErrors"] && seen["Udp:","RcvbufErrors"] && seen["Udp:","SndbufErrors"]
      if(require_v6 && !(s6["Udp6InErrors"] && s6["Udp6RcvbufErrors"] && s6["Udp6SndbufErrors"])) valid=0
      printf "%.0f %.0f %.0f %.0f %.0f %d\n", v["Tcp:","RetransSegs"]+0,v["Tcp:","OutSegs"]+0,v["Udp:","InErrors"]+v6["Udp6InErrors"],v["Udp:","RcvbufErrors"]+v6["Udp6RcvbufErrors"],v["Udp:","SndbufErrors"]+v6["Udp6SndbufErrors"],valid
    }' "$PROC_ROOT/net/snmp" "$v6" 2>/dev/null
}
cpu_snapshot() {
  awk '/^cpu[0-9]+ / {total=0; for(i=2;i<=9 && i<=NF;i++) total+=$i; print $1,total,$8+0,$9+0,$7+0,$5+$6}' "$PROC_ROOT/stat" 2>/dev/null
}
cpu_window_pressure() {
  awk 'NR==FNR {t[$1]=$2;s[$1]=$3;v[$1]=$4;h[$1]=$5;idle[$1]=$6;old++;next}
    {if(!($1 in t)){bad=1;next} n++;dt=$2-t[$1];ds=$3-s[$1];dv=$4-v[$1];dh=$5-h[$1];di=$6-idle[$1]
     if(dt<=0||ds<0||dv<0||dh<0||di<0){bad=1;next}
     soft=int(ds*100/dt);steal=int(dv*100/dt);hard=int(dh*100/dt);busy=int((dt-di)*100/dt)
     if(soft>ms)ms=soft;if(steal>mv)mv=steal;if(hard>mh)mh=hard;if(busy>mb)mb=busy}
    END{if(bad||!n||n!=old)print "0 0 0 0 0";else print ms+0,mv+0,mh+0,mb+0,1}' "$1" "$2" 2>/dev/null
}
bounded() {
  if command -v timeout >/dev/null 2>&1; then timeout -k 1 3 "$@"; else "$@"; fi
}
listen_drops() {
  awk '$1=="TcpExt:" {if($2!~/^[0-9]+$/){for(i=2;i<=NF;i++)h[i]=$i;next}for(i=2;i<=NF;i++)if(h[i]=="ListenDrops"){print $i,1;found=1;exit}}END{if(!found)print "0 0"}' "$PROC_ROOT/net/netstat" 2>/dev/null
}
# Detailed counters are collected by one bounded background worker. Raw
# counters and sample stamps cross the process boundary; the parent computes
# deltas exactly once when it consumes a new atomic snapshot.
driver_drops() {
  local data
  data=$(bounded ethtool -S "$DEV" 2>/dev/null) || { echo '0 0 none'; return; }
  printf '%s\n' "$data" | awk -F: '
    {name=$1;gsub(/^[ \t]+|[ \t]+$/,"",name);value=$2;gsub(/[ \t]/,"",value)
     if(value~/^[0-9]+$/) counters[name]=value}
    END {
      # Fixed identity/priority, never the currently largest lifetime count.
      n=split("rx_missed_errors rx_no_buffer_count rx_out_of_buffer rx_no_buffer rx_dropped rx_discards",names," ")
      for(i=1;i<=n;i++) if(names[i] in counters) {printf "%.0f 1 %s\n",counters[names[i]],names[i];exit}
      print "0 0 none"
    }'
}
qdisc_stats() {
  local data
  data=$(bounded tc -s qdisc show dev "$DEV" 2>/dev/null) || { echo '0 0 0 unknown none'; return; }
  printf '%s\n' "$data" | awk '
    function size_bytes(token, unit, number) {
      if(token !~ /^[0-9]+([.][0-9]+)?[KMGkmg]?b$/) return -1
      unit=token;sub(/^[0-9]+([.][0-9]+)?/,"",unit)
      number=token+0
      if(unit=="Kb"||unit=="kb")return number*1024
      if(unit=="Mb"||unit=="mb")return number*1048576
      if(unit=="Gb"||unit=="gb")return number*1073741824
      return number
    }
    /^qdisc / {
      current=0
      if($2=="mq"||$2=="ingress"||$2=="clsact")next
      current=++n;kind[current]=$2;handle[current]=$3;parent[current]="root"
      for(i=4;i<NF;i++)if($i=="parent")parent[current]=$(i+1)
      if($2!="fq"&&$2!="pfifo"&&$2!="bfifo"&&$2!="pfifo_fast"&&$2!="noqueue")managed=1
      identity=identity kind[current] "@" handle[current] ">" parent[current] ";"
      next
    }
    current && /Sent / {
      for(i=1;i<NF;i++) {key=$i;gsub(/[()]/,"",key);if(key=="dropped"){
        value=$(i+1);gsub(/,/,"",value)
        if(value~/^[0-9]+$/){drops[current]=value;drop_seen[current]=1}
      }}
    }
    current && /backlog / {
      for(i=1;i<NF;i++)if($i=="backlog"){
        value=size_bytes($(i+1));if(value>=0){bytes[current]=value;backlog_seen[current]=1}else bad=1
      }
    }
    END {
      # A qdisc may itself own a child qdisc via one of its classes. Count
      # terminal data qdiscs only, avoiding root/class/leaf duplication.
      for(i=1;i<=n;i++)for(j=1;j<=n;j++)if(i!=j&&parent[j]!="root"){
        split(handle[i],h,":");split(parent[j],p,":")
        if(h[1]!=""&&h[1]!="0"&&h[1]==p[1])has_child[i]=1
      }
      for(i=1;i<=n;i++)if(!has_child[i]){
        leaves++;if(!drop_seen[i]||!backlog_seen[i])bad=1
        total_drops+=drops[i];total_bytes+=bytes[i]
      }
      valid=(leaves>0&&!bad)
      printf "%.0f %.0f %d %s %s\n",total_drops,total_bytes,valid,(managed?"managed":"plain"),(identity==""?"none":identity)
    }'
}
read_details() {
  local requested="${1:-0}" driver=0 dvalid=0 did=none drops=0 backlog=0 qvalid=0 policy=unknown qid=none listen=0 lvalid=0
  local driver_stamp qdisc_stamp listen_stamp stamp tmp
  read -r driver dvalid did < <(driver_drops)
  driver_stamp=$(monotonic_millis)
  read -r drops backlog qvalid policy qid < <(qdisc_stats)
  qdisc_stamp=$(monotonic_millis)
  read -r listen lvalid < <(listen_drops)
  listen_stamp=$(monotonic_millis)
  stamp=$(monotonic_millis)
  tmp="$DETAIL_FILE.tmp.${BASHPID:-$$}"
  umask 077
  {
    printf 'DETAIL_SNAPSHOT_DEV=%q\nDETAIL_SNAPSHOT_GENERATION=%q\n' "$DEV" "$CONTROLLER_GENERATION"
    printf 'DETAIL_SNAPSHOT_STAMP=%q\nDETAIL_SNAPSHOT_REQUESTED=%q\n' "$stamp" "$requested"
    printf 'DETAIL_SNAPSHOT_DRIVER=%q\nDETAIL_SNAPSHOT_DRIVER_VALID=%q\nDETAIL_SNAPSHOT_DRIVER_ID=%q\nDETAIL_SNAPSHOT_DRIVER_TS=%q\n' "$driver" "$dvalid" "$did" "$driver_stamp"
    printf 'DETAIL_SNAPSHOT_QDISC=%q\nDETAIL_SNAPSHOT_BACKLOG=%q\nDETAIL_SNAPSHOT_QDISC_VALID=%q\nDETAIL_SNAPSHOT_QDISC_POLICY=%q\nDETAIL_SNAPSHOT_QDISC_ID=%q\nDETAIL_SNAPSHOT_QDISC_TS=%q\n' "$drops" "$backlog" "$qvalid" "$policy" "$qid" "$qdisc_stamp"
    printf 'DETAIL_SNAPSHOT_LISTEN=%q\nDETAIL_SNAPSHOT_LISTEN_VALID=%q\nDETAIL_SNAPSHOT_LISTEN_TS=%q\n' "$listen" "$lvalid" "$listen_stamp"
  } > "$tmp" && mv -f "$tmp" "$DETAIL_FILE"
}
launch_details() {
  local now="${1:-$(monotonic_millis)}"
  if [ -n "${DETAIL_PID:-}" ]; then
    if kill -0 "$DETAIL_PID" 2>/dev/null; then return 0; fi
    wait "$DETAIL_PID" 2>/dev/null || true
    DETAIL_PID=""
  fi
  (
    # Never inherit the controller EXIT trap: a metrics worker must not
    # release the controller lock or restore an unrelated parameter trial.
    trap - EXIT INT TERM
    exec 8>&-
    [ "${LOCK_METHOD:-}" != flock ] || exec 9>&-
    read_details "$now"
  ) >/dev/null 2>&1 &
  DETAIL_PID=$!
}
stop_detail_worker() {
  if [ -n "${DETAIL_PID:-}" ]; then
    kill -TERM "$DETAIL_PID" 2>/dev/null || true
    wait "$DETAIL_PID" 2>/dev/null || true
    DETAIL_PID=""
  fi
}
_detail_value_valid() {
  [[ "${1:-}" =~ ^[0-9]+$ ]] && [ "${#1}" -le 18 ]
}
_detail_invalidate() {
  CURRENT_DETAIL_VALID=0; CURRENT_DRIVER_VALID=0; CURRENT_QDISC_VALID=0
  CURRENT_DRIVER_DROPS=0; CURRENT_QDISC_DROPS=0; CURRENT_LISTEN_DROPS=0
  CURRENT_QDISC_AQM_DROPS=0; CURRENT_QDISC_BACKLOG=0; CURRENT_QDISC_POLICY=unknown
}
read_detail_snapshot() {
  local now="${1:-$(monotonic_millis)}" ttl key delta dt
  local DETAIL_SNAPSHOT_DEV=unknown DETAIL_SNAPSHOT_GENERATION=unknown
  local DETAIL_SNAPSHOT_STAMP=0 DETAIL_SNAPSHOT_REQUESTED=0
  local DETAIL_SNAPSHOT_DRIVER=0 DETAIL_SNAPSHOT_DRIVER_VALID=0 DETAIL_SNAPSHOT_DRIVER_ID=none DETAIL_SNAPSHOT_DRIVER_TS=0
  local DETAIL_SNAPSHOT_QDISC=0 DETAIL_SNAPSHOT_BACKLOG=0 DETAIL_SNAPSHOT_QDISC_VALID=0 DETAIL_SNAPSHOT_QDISC_POLICY=unknown DETAIL_SNAPSHOT_QDISC_ID=none DETAIL_SNAPSHOT_QDISC_TS=0
  local DETAIL_SNAPSHOT_LISTEN=0 DETAIL_SNAPSHOT_LISTEN_VALID=0 DETAIL_SNAPSHOT_LISTEN_TS=0
  DETAIL_EVENT_NEW=0
  [ -r "$DETAIL_FILE" ] || { _detail_invalidate; return 0; }
  # The worker owns this mode-0600, atomically replaced file in WORKDIR.
  source "$DETAIL_FILE" || { _detail_invalidate; return 0; }
  if [ "$DETAIL_SNAPSHOT_DEV" != "$DEV" ] || [ "$DETAIL_SNAPSHOT_GENERATION" != "$CONTROLLER_GENERATION" ]; then _detail_invalidate; return 0; fi
  for key in DETAIL_SNAPSHOT_STAMP DETAIL_SNAPSHOT_DRIVER DETAIL_SNAPSHOT_DRIVER_TS DETAIL_SNAPSHOT_QDISC DETAIL_SNAPSHOT_BACKLOG DETAIL_SNAPSHOT_QDISC_TS DETAIL_SNAPSHOT_LISTEN DETAIL_SNAPSHOT_LISTEN_TS; do
    _detail_value_valid "${!key}" || { _detail_invalidate; return 0; }
  done
  ttl=$(( ${DETAIL_INTERVAL:-10} * 3000 + 10000 ))
  if [ "$now" -lt "$DETAIL_SNAPSHOT_STAMP" ] || [ $(( now - DETAIL_SNAPSHOT_STAMP )) -gt "$ttl" ]; then
    _detail_invalidate; return 0
  fi
  CURRENT_DRIVER_VALID="$DETAIL_SNAPSHOT_DRIVER_VALID"
  CURRENT_QDISC_VALID="$DETAIL_SNAPSHOT_QDISC_VALID"
  CURRENT_QDISC_BACKLOG="$DETAIL_SNAPSHOT_BACKLOG"
  CURRENT_QDISC_POLICY="$DETAIL_SNAPSHOT_QDISC_POLICY"
  CURRENT_DETAIL_VALID=0
  [ "$CURRENT_QDISC_VALID" = 1 ] && [ "$DETAIL_SNAPSHOT_LISTEN_VALID" = 1 ] && CURRENT_DETAIL_VALID=1
  [ "${DETAIL_APPLIED_STAMP:-0}" != "$DETAIL_SNAPSHOT_STAMP" ] || return 0
  DETAIL_EVENT_NEW=1
  DETAIL_EVENT_DRIVER_DELTA=0; DETAIL_EVENT_DRIVER_MS=0
  DETAIL_EVENT_QDISC_DELTA=0; DETAIL_EVENT_QDISC_MS=0
  DETAIL_EVENT_LISTEN_DELTA=0; DETAIL_EVENT_LISTEN_MS=0
  DETAIL_EVENT_STAMP_MS="$DETAIL_SNAPSHOT_STAMP"
  DETAIL_EVENT_MS=0
  [ "${DETAIL_APPLIED_STAMP:-0}" -eq 0 ] || DETAIL_EVENT_MS=$(( DETAIL_SNAPSHOT_STAMP - DETAIL_APPLIED_STAMP ))
  CURRENT_DRIVER_DROPS=0; CURRENT_QDISC_DROPS=0; CURRENT_LISTEN_DROPS=0; CURRENT_QDISC_AQM_DROPS=0
  if [ "$CURRENT_DRIVER_VALID" = 1 ] && [ "${DETAIL_PREV_DRIVER_VALID:-0}" = 1 ] && [ "$DETAIL_SNAPSHOT_DRIVER_ID" = "${DETAIL_PREV_DRIVER_ID:-none}" ]; then
    dt=$(( DETAIL_SNAPSHOT_DRIVER_TS - DETAIL_PREV_DRIVER_TS )); delta=$(( DETAIL_SNAPSHOT_DRIVER - DETAIL_PREV_DRIVER ))
    if [ "$delta" -lt 0 ]; then CURRENT_RESET=1
    elif [ "$dt" -gt 0 ]; then
      DETAIL_EVENT_DRIVER_DELTA="$delta"; DETAIL_EVENT_DRIVER_MS="$dt"
      CURRENT_DRIVER_DROPS=$(( (delta * 1000 + dt - 1) / dt ))
    fi
  fi
  if [ "$CURRENT_QDISC_VALID" = 1 ] && [ "${DETAIL_PREV_QDISC_VALID:-0}" = 1 ] && [ "$DETAIL_SNAPSHOT_QDISC_ID" = "${DETAIL_PREV_QDISC_ID:-none}" ]; then
    dt=$(( DETAIL_SNAPSHOT_QDISC_TS - DETAIL_PREV_QDISC_TS )); delta=$(( DETAIL_SNAPSHOT_QDISC - DETAIL_PREV_QDISC ))
    if [ "$delta" -lt 0 ]; then CURRENT_RESET=1
    elif [ "$dt" -gt 0 ]; then
      DETAIL_EVENT_QDISC_DELTA="$delta"; DETAIL_EVENT_QDISC_MS="$dt"
      if [ "$CURRENT_QDISC_POLICY" = plain ]; then CURRENT_QDISC_DROPS=$(( (delta * 1000 + dt - 1) / dt ))
      else CURRENT_QDISC_AQM_DROPS=$(( (delta * 1000 + dt - 1) / dt )); fi
    fi
  fi
  if [ "$DETAIL_SNAPSHOT_LISTEN_VALID" = 1 ] && [ "${DETAIL_PREV_LISTEN_VALID:-0}" = 1 ]; then
    dt=$(( DETAIL_SNAPSHOT_LISTEN_TS - DETAIL_PREV_LISTEN_TS )); delta=$(( DETAIL_SNAPSHOT_LISTEN - DETAIL_PREV_LISTEN ))
    if [ "$delta" -lt 0 ]; then CURRENT_RESET=1
    elif [ "$dt" -gt 0 ]; then
      DETAIL_EVENT_LISTEN_DELTA="$delta"; DETAIL_EVENT_LISTEN_MS="$dt"
      CURRENT_LISTEN_DROPS=$(( (delta * 1000 + dt - 1) / dt ))
    fi
  fi
  DETAIL_PREV_DRIVER="$DETAIL_SNAPSHOT_DRIVER"; DETAIL_PREV_DRIVER_VALID="$CURRENT_DRIVER_VALID"; DETAIL_PREV_DRIVER_ID="$DETAIL_SNAPSHOT_DRIVER_ID"; DETAIL_PREV_DRIVER_TS="$DETAIL_SNAPSHOT_DRIVER_TS"
  DETAIL_PREV_QDISC="$DETAIL_SNAPSHOT_QDISC"; DETAIL_PREV_QDISC_VALID="$CURRENT_QDISC_VALID"; DETAIL_PREV_QDISC_ID="$DETAIL_SNAPSHOT_QDISC_ID"; DETAIL_PREV_QDISC_TS="$DETAIL_SNAPSHOT_QDISC_TS"
  DETAIL_PREV_LISTEN="$DETAIL_SNAPSHOT_LISTEN"; DETAIL_PREV_LISTEN_VALID="$DETAIL_SNAPSHOT_LISTEN_VALID"; DETAIL_PREV_LISTEN_TS="$DETAIL_SNAPSHOT_LISTEN_TS"
  DETAIL_APPLIED_STAMP="$DETAIL_SNAPSHOT_STAMP"
  return 0
}

launch_diagnostics() {
  [ -x "$DIAG_HELPER" ] || return 0
  if [ -n "$DIAG_PID" ] && kill -0 "$DIAG_PID" 2>/dev/null; then return 0; fi
  [ -z "$DIAG_PID" ] || wait "$DIAG_PID" 2>/dev/null || true
  (
    trap - EXIT INT TERM
    exec 8>&-
    [ "${LOCK_METHOD:-}" != flock ] || exec 9>&-
    export PROC_ROOT SYS_ROOT WORKDIR NIC_ENV_FILE AUTO_ENV_FILE CONTROLLER_GENERATION DEV
    if command -v timeout >/dev/null 2>&1; then
      exec timeout -k 2 30 "$DIAG_HELPER" collect
    else
      exec "$DIAG_HELPER" collect
    fi
  ) >/dev/null 2>&1 &
  DIAG_PID=$!
}
read_diagnostics() {
  local diag="$WORKDIR/diagnostics.env" now="$1" updated
  CURRENT_RTT_VALID=0; DIAG_FLOW_FINGERPRINT=unknown
  DIAG_RTT_US=unknown; DIAG_RTT_VALID=0; DIAG_MONOTONIC_MS=0
  DIAG_DEV=unknown; DIAG_CONTROLLER_GENERATION=unknown
  [ -r "$diag" ] || return 0
  source "$diag" || return 0
  if [ "$DIAG_DEV" != "$DEV" ] || [ "$DIAG_CONTROLLER_GENERATION" != "$CONTROLLER_GENERATION" ]; then DIAG_FLOW_FINGERPRINT=unknown; return 0; fi
  updated="${DIAG_MONOTONIC_MS:-0}"
  case "$updated" in ''|*[!0-9]*) return 0 ;; esac
  [ $(( now - updated )) -le $(( DIAG_INTERVAL * 3000 )) ] && [ "$now" -ge "$updated" ] || return 0
  case "${DIAG_RTT_US:-}" in ''|*[!0-9]*) return 0 ;; esac
  [ "${DIAG_RTT_VALID:-0}" = 1 ] || return 0
  CURRENT_RTT_US="$DIAG_RTT_US"; CURRENT_RTT_VALID=1
}

clamp_value() {
  local value="$1" minimum="$2" maximum="$3"
  [ "$minimum" -le "$maximum" ] || minimum="$maximum"
  [ "$value" -ge "$minimum" ] || value="$minimum"
  [ "$value" -le "$maximum" ] || value="$maximum"
  printf '%s\n' "$value"
}
backlog_cap() {
  local cap
  # An estimate, not a promise about skb truesize or all network allocations.
  cap=$(( MEM_KB * 1024 / 50 / CPU_COUNT / 4096 ))
  clamp_value "$cap" 1 65536
}
calculate_level_parameters() {
  local cap rx candidate
  cap=$(backlog_cap)
  rx="${CURRENT_RX_PPS:-0}"
  # Use RX only. Average RX/queue is not a substitute for a hot CPU reading.
  candidate=$(( rx * 8 / 1000 ))
  ACTIVE_BACKLOG=$(clamp_value "$candidate" 4096 "$cap")
  ACTIVE_BUDGET=600; ACTIVE_BUDGET_USECS=2000; ACTIVE_WEIGHT=64
  ACTIVE_COALESCE=0; ACTIVE_ADAPTIVE_RX=unknown; ACTIVE_ADAPTIVE_TX=unknown
}
read_coalesce() {
  local output
  output=$(bounded ethtool -c "$DEV" 2>/dev/null) || { echo '0 unknown unknown 0'; return; }
  printf '%s\n' "$output" | awk '
    /Adaptive RX:/ {for(i=1;i<=NF;i++){if($i=="RX:")rx=$(i+1);if($i=="TX:")tx=$(i+1)}}
    /^[ \t]*rx-usecs:/ {u=$2;seen=1}
    END{if(seen&&u~/^[0-9]+$/)print u,(rx=="on"||rx=="off"?rx:"unknown"),(tx=="on"||tx=="off"?tx:"unknown"),1;else print "0 unknown unknown 0"}'
}
read_current_parameters() {
  local i value failed=0
  for ((i=0;i<${#SNAPSHOT_KEYS[@]};i++)); do
    [ -e "$PROC_ROOT/sys/${SNAPSHOT_KEYS[$i]//.//}" ] || continue
    value=$(sysctl -n "${SNAPSHOT_KEYS[$i]}" 2>/dev/null) || { failed=1; continue; }
    case "$value" in ''|*[!0-9]*) failed=1; continue ;; esac
    printf -v "${PARAMETER_NAMES[$i]}" '%s' "$value"
  done
  read -r ACTIVE_COALESCE ACTIVE_ADAPTIVE_RX ACTIVE_ADAPTIVE_TX COALESCE_SUPPORTED < <(read_coalesce)
  return "$failed"
}
save_active() {
  local path="$1" tmp="$1.tmp.$$" name
  {
    for name in "${PARAMETER_NAMES[@]}" ACTIVE_COALESCE ACTIVE_ADAPTIVE_RX ACTIVE_ADAPTIVE_TX; do
      printf '%s=%s\n' "$name" "${!name}"
    done
  } > "$tmp" && mv -f "$tmp" "$path"
}
load_active() {
  local path="$1" key value count=0 seen='|' i
  local -a names=() values=()
  [ -r "$path" ] || return 1
  # Validate the complete record before changing any live shell variable.
  while IFS='=' read -r key value; do
    case "$seen" in *"|$key|"*) return 1 ;; esac
    seen="$seen$key|"
    case "$key" in
      ACTIVE_BACKLOG|ACTIVE_BUDGET|ACTIVE_BUDGET_USECS|ACTIVE_WEIGHT|ACTIVE_COALESCE)
        case "$value" in ''|*[!0-9]*) return 1 ;; esac
        [ "${#value}" -le 7 ] || return 1
        value=$(( 10#$value ))
        case "$key" in
          ACTIVE_BACKLOG|ACTIVE_BUDGET|ACTIVE_WEIGHT) [ "$value" -ge 1 ] && [ "$value" -le 1048576 ] || return 1 ;;
          *) [ "$value" -le 1000000 ] || return 1 ;;
        esac ;;
      ACTIVE_ADAPTIVE_RX|ACTIVE_ADAPTIVE_TX)
        case "$value" in on|off|unknown) ;; *) return 1 ;; esac ;;
      *) return 1 ;;
    esac
    names+=("$key"); values+=("$value"); count=$((count+1))
  done < "$path"
  [ "$count" -eq 7 ] || return 1
  for ((i=0;i<count;i++)); do printf -v "${names[$i]}" '%s' "${values[$i]}"; done
}

restore_written() {
  local j idx current expected failed=0
  for ((j=${#APPLIED_INDICES[@]}-1;j>=0;j--)); do
    idx="${APPLIED_INDICES[$j]}"
    current=$(sysctl -n "${SNAPSHOT_KEYS[$idx]}" 2>/dev/null) || { failed=1; continue; }
    [ "$current" != "${OLD_VALUES[$idx]}" ] || continue
    expected="${ATTEMPTED_VALUES[$idx]}"
    if [ "$current" != "$expected" ]; then ACTUATOR_CONFLICT=1; failed=1; continue; fi
    sysctl -q -w "${SNAPSHOT_KEYS[$idx]}=${OLD_VALUES[$idx]}" >/dev/null 2>&1 || failed=1
    [ "$(sysctl -n "${SNAPSHOT_KEYS[$idx]}" 2>/dev/null)" = "${OLD_VALUES[$idx]}" ] || failed=1
  done
  return "$failed"
}
apply_parameter_group() {
  local group="${1:-all}" expected_previous="${2:-}" i key old actual value failed=0
  local old_usec=0 old_rx=unknown old_tx=unknown supported=0
  local -a OLD_VALUES=() APPLIED_INDICES=() ATTEMPTED_VALUES=() args=()
  ACTUATOR_CHANGED=0; ACTUATOR_ROLLBACK_FAILED=0; ACTUATOR_CONFLICT=0
  case "$group" in all|rx_backlog|napi_budget|rx_coalesce) ;; *) return 1 ;; esac
  # Validate the complete requested group before the first mutation.
  for ((i=0;i<${#SNAPSHOT_KEYS[@]};i++)); do
    _group_wants_index "$group" "$i" || continue
    value="${PARAMETER_NAMES[$i]}"; value="${!value}"
    case "$value" in ''|*[!0-9]*) return 1 ;; esac
  done
  for ((i=0;i<${#SNAPSHOT_KEYS[@]};i++)); do
    _group_wants_index "$group" "$i" || continue
    key="${SNAPSHOT_KEYS[$i]}"; value="${PARAMETER_NAMES[$i]}"; value="${!value}"
    [ -e "$PROC_ROOT/sys/${key//.//}" ] || continue
    old=$(sysctl -n "$key" 2>/dev/null || true)
    case "$old" in ''|*[!0-9]*) failed=1; break ;; esac
    if [ -n "$expected_previous" ] && [ "$old" != "$expected_previous" ]; then ACTUATOR_CONFLICT=1; failed=1; break; fi
    [ "$old" != "$value" ] || continue
    [ -w "$PROC_ROOT/sys/${key//.//}" ] || { failed=1; break; }
    OLD_VALUES[$i]="$old"; ATTEMPTED_VALUES[$i]="$value"; APPLIED_INDICES+=("$i")
    if ! sysctl -q -w "$key=$value" >/dev/null 2>&1; then
      actual=$(sysctl -n "$key" 2>/dev/null || true)
      if [ "$key" = net.core.netdev_budget_usecs ] && [ "$actual" = "$old" ]; then
        printf -v "${PARAMETER_NAMES[$i]}" '%s' "$actual"; continue
      fi
      failed=1; break
    fi
    actual=$(sysctl -n "$key" 2>/dev/null || true)
    if [ "$actual" != "$value" ]; then failed=1; break; fi
    ACTUATOR_CHANGED=1
  done
  if [ "$failed" -ne 0 ]; then
    restore_written || ACTUATOR_ROLLBACK_FAILED=1
    read_current_parameters || true
    return 1
  fi
  if [ "$group" = rx_coalesce ] && [ "${AUTO_NIC_TUNING:-1}" != 1 ]; then return 1; fi
  if { [ "$group" = all ] || [ "$group" = rx_coalesce ]; } && [ "${AUTO_NIC_TUNING:-1}" = 1 ] && [ "$COALESCE_SUPPORTED" = 1 ]; then
    read -r old_usec old_rx old_tx supported < <(read_coalesce)
    if [ "$group" = rx_coalesce ] && { [ "$supported" != 1 ] || { [ -n "$expected_previous" ] && [ "$old_usec" != "$expected_previous" ]; } || [ "$old_rx" != "$ACTIVE_ADAPTIVE_RX" ] || [ "$old_tx" != "$ACTIVE_ADAPTIVE_TX" ]; }; then
      ACTUATOR_CONFLICT=1; return 1
    fi
    if [ "$supported" = 1 ] && { [ "$old_usec" != "$ACTIVE_COALESCE" ] || [ "$old_rx" != "$ACTIVE_ADAPTIVE_RX" ] || [ "$old_tx" != "$ACTIVE_ADAPTIVE_TX" ]; }; then
      args=(rx-usecs "$ACTIVE_COALESCE")
      case "$ACTIVE_ADAPTIVE_RX" in on|off) args+=(adaptive-rx "$ACTIVE_ADAPTIVE_RX") ;; esac
      case "$ACTIVE_ADAPTIVE_TX" in on|off) args+=(adaptive-tx "$ACTIVE_ADAPTIVE_TX") ;; esac
      if ! bounded ethtool -C "$DEV" "${args[@]}" >/dev/null 2>&1; then failed=1
      else
        read -r actual old supported i < <(read_coalesce)
        [ "$actual" = "$ACTIVE_COALESCE" ] || failed=1
        case "$ACTIVE_ADAPTIVE_RX" in on|off) [ "$old" = "$ACTIVE_ADAPTIVE_RX" ] || failed=1 ;; esac
        case "$ACTIVE_ADAPTIVE_TX" in on|off) [ "$supported" = "$ACTIVE_ADAPTIVE_TX" ] || failed=1 ;; esac
      fi
      if [ "$failed" -ne 0 ]; then
        read -r actual old supported i < <(read_coalesce)
        if [ "$i" = 1 ] && { [ "$actual" = "$ACTIVE_COALESCE" ] || [ "$actual" = "$old_usec" ]; } && { [ "$old" = "$ACTIVE_ADAPTIVE_RX" ] || [ "$old" = "$old_rx" ]; } && { [ "$supported" = "$ACTIVE_ADAPTIVE_TX" ] || [ "$supported" = "$old_tx" ]; }; then
          args=(rx-usecs "$old_usec")
          case "$old_rx" in on|off) args+=(adaptive-rx "$old_rx") ;; esac
          case "$old_tx" in on|off) args+=(adaptive-tx "$old_tx") ;; esac
          bounded ethtool -C "$DEV" "${args[@]}" >/dev/null 2>&1 || ACTUATOR_ROLLBACK_FAILED=1
          read -r actual old supported i < <(read_coalesce)
          [ "$i:$actual:$old:$supported" = "1:$old_usec:$old_rx:$old_tx" ] || ACTUATOR_ROLLBACK_FAILED=1
        else ACTUATOR_CONFLICT=1; ACTUATOR_ROLLBACK_FAILED=1; fi
        restore_written || ACTUATOR_ROLLBACK_FAILED=1
        read_current_parameters || true
        return 1
      fi
      ACTUATOR_CHANGED=1
    fi
  fi
  return 0
}
refresh_window_rates() {
  local elapsed="${CURRENT_ELAPSED_MS:-1000}"
  [ "$elapsed" -gt 0 ] || elapsed=1000
  CURRENT_UDP_RCV_RATE=$(( (CURRENT_UDP_RCVBUF * 1000 + elapsed - 1) / elapsed ))
  CURRENT_UDP_SEND_RATE=$(( (CURRENT_UDP_SNDBUF * 1000 + elapsed - 1) / elapsed ))
  CURRENT_SOFTNET_RATE=$(( (CURRENT_SOFT_DROPS * 1000 + elapsed - 1) / elapsed ))
  CURRENT_SQUEEZE_RATE=$(( (CURRENT_SQUEEZE * 1000 + elapsed - 1) / elapsed ))
}
remember_window() {
  refresh_window_rates
  # An EWMA of measured load and local error events, not application goodput.
  if [ "$HISTORY_SAMPLES" -eq 0 ]; then
    HISTORY_ERROR="$CURRENT_ERROR_RATE"; HISTORY_RX="$CURRENT_RX_BPS"; HISTORY_TX="$CURRENT_TX_BPS"
    HISTORY_RX_PPS="$CURRENT_RX_PPS"; HISTORY_TX_PPS="$CURRENT_TX_PPS"
    HISTORY_KERNEL=$(( CURRENT_SOFTIRQ + CURRENT_HARDIRQ )); HISTORY_SQUEEZE="$CURRENT_SQUEEZE_RATE"
    HISTORY_UDP_SEND="$CURRENT_UDP_SEND_RATE"; HISTORY_RETRANS="$CURRENT_RETRANS_BP"
    HISTORY_LISTEN="$CURRENT_LISTEN_DROPS"; HISTORY_QDISC="$CURRENT_QDISC_DROPS"
    HISTORY_UDP_RCV="$CURRENT_UDP_RCV_RATE"; HISTORY_SOFTNET="$CURRENT_SOFTNET_RATE"; HISTORY_DRIVER="$CURRENT_DRIVER_DROPS"
  else
    HISTORY_ERROR=$(( (HISTORY_ERROR * 3 + CURRENT_ERROR_RATE) / 4 ))
    HISTORY_RX=$(( (HISTORY_RX * 3 + CURRENT_RX_BPS) / 4 ))
    HISTORY_TX=$(( (HISTORY_TX * 3 + CURRENT_TX_BPS) / 4 ))
    HISTORY_RX_PPS=$(( (HISTORY_RX_PPS * 3 + CURRENT_RX_PPS) / 4 )); HISTORY_TX_PPS=$(( (HISTORY_TX_PPS * 3 + CURRENT_TX_PPS) / 4 ))
    HISTORY_KERNEL=$(( (HISTORY_KERNEL * 3 + CURRENT_SOFTIRQ + CURRENT_HARDIRQ) / 4 )); HISTORY_SQUEEZE=$(( (HISTORY_SQUEEZE * 3 + CURRENT_SQUEEZE_RATE) / 4 ))
    HISTORY_UDP_SEND=$(( (HISTORY_UDP_SEND * 3 + CURRENT_UDP_SEND_RATE) / 4 )); HISTORY_RETRANS=$(( (HISTORY_RETRANS * 3 + CURRENT_RETRANS_BP) / 4 ))
    HISTORY_LISTEN=$(( (HISTORY_LISTEN * 3 + CURRENT_LISTEN_DROPS) / 4 )); HISTORY_QDISC=$(( (HISTORY_QDISC * 3 + CURRENT_QDISC_DROPS) / 4 ))
    HISTORY_UDP_RCV=$(( (HISTORY_UDP_RCV * 3 + CURRENT_UDP_RCV_RATE) / 4 )); HISTORY_SOFTNET=$(( (HISTORY_SOFTNET * 3 + CURRENT_SOFTNET_RATE) / 4 )); HISTORY_DRIVER=$(( (HISTORY_DRIVER * 3 + CURRENT_DRIVER_DROPS) / 4 ))
  fi
  HISTORY_SAMPLES=$(( HISTORY_SAMPLES + 1 ))
}
rollback_trial() {
  local reason="$1" current status desired
  if ! _read_trial_meta || [ "$META_CONTEXT" != "$(_controller_context)" ]; then
    TRIAL_STATUS=restore_failed; LAST_REASON=recovery_context_unavailable; CURRENT_COOLDOWN=3600; return 1
  fi
  current=$(_trial_current_value); status=$?
  if [ "$status" = 2 ]; then TRIAL_STATUS=restore_failed; LAST_REASON=rollback_failed; CURRENT_COOLDOWN=3600; return 1; fi
  if [ "$status" = 3 ] || { [ "$current" != "$META_EXPECTED" ] && [ "$current" != "$META_ORIGINAL" ]; }; then
    # Another owner changed this key/mode. Never overwrite their value.
    read_current_parameters || true
    _clear_trial_journal || return 1
    TRIAL_ACTIVE=0; TRIAL_STATUS=external_change; LAST_REASON=external_parameters_changed
    HISTORY_SAMPLES=0; CURRENT_COOLDOWN="$COOLDOWN_SECONDS"; return 0
  fi
  if [ "$current" = "$META_EXPECTED" ] && [ "$current" != "$META_ORIGINAL" ]; then
    desired="$META_ORIGINAL"
    read_current_parameters || { TRIAL_STATUS=restore_failed; LAST_REASON=rollback_failed; return 1; }
    printf -v "$META_NAME" '%s' "$desired"
    if ! apply_parameter_group "$META_GROUP" "$META_EXPECTED"; then
      TRIAL_STATUS=restore_failed; LAST_REASON=rollback_failed; CURRENT_COOLDOWN=3600; return 1
    fi
    current=$(_trial_current_value) || { TRIAL_STATUS=restore_failed; LAST_REASON=rollback_failed; return 1; }
    [ "$current" = "$META_ORIGINAL" ] || { TRIAL_STATUS=restore_failed; LAST_REASON=rollback_failed; return 1; }
  fi
  _clear_trial_journal || return 1
  read_current_parameters || true
  TRIAL_ACTIVE=0; TRIAL_STATUS=restored; LAST_REASON="$reason"; CURRENT_COOLDOWN="$COOLDOWN_SECONDS"
}
begin_trial() {
  local reason="$1" cap now name original i changed=0
  local -a cached=()
  [ "$TRIAL_ACTIVE" -eq 0 ] || return 1
  [ ! -e "$PAUSE_FILE" ] || return 1
  [ ! -e "$PENDING_FILE" ] && [ ! -e "$PENDING_META_FILE" ] || return 1
  [ "$reason" != rx_coalesce ] || [ "${AUTO_NIC_TUNING:-1}" = 1 ] || return 1
  for name in "${PARAMETER_NAMES[@]}" ACTIVE_COALESCE ACTIVE_ADAPTIVE_RX ACTIVE_ADAPTIVE_TX; do cached+=("${!name}"); done
  read_current_parameters || { LAST_REASON=metrics_unavailable; return 1; }
  i=0
  for name in "${PARAMETER_NAMES[@]}" ACTIVE_COALESCE ACTIVE_ADAPTIVE_RX ACTIVE_ADAPTIVE_TX; do
    [ "${!name}" = "${cached[$i]}" ] || changed=1
    i=$((i+1))
  done
  if [ "$changed" = 1 ]; then HISTORY_SAMPLES=0; LAST_REASON=external_parameters_changed; return 1; fi
  [ "$HISTORY_SAMPLES" -ge 5 ] && [ "$CURRENT_DETAIL_VALID" = 1 ] || return 1
  now=$(monotonic_millis)
  [ "$LAST_REJECTED_GROUP" != "$reason" ] || [ $(( now - LAST_REJECTED_AT )) -ge 600000 ] || return 1
  BASE_ERROR="$HISTORY_ERROR"; BASE_RX="$HISTORY_RX"; BASE_TX="$HISTORY_TX"
  BASE_RTT=0; [ "$CURRENT_RTT_VALID" = 1 ] && BASE_RTT="$CURRENT_RTT_US"
  BASE_FLOW_FINGERPRINT="${DIAG_FLOW_FINGERPRINT:-unknown}"
  BASE_DIAG_MS="${DIAG_MONOTONIC_MS:-0}"
  BASE_RX_PPS="$HISTORY_RX_PPS"; BASE_TX_PPS="$HISTORY_TX_PPS"
  BASE_KERNEL="$HISTORY_KERNEL"; BASE_SQUEEZE="$HISTORY_SQUEEZE"
  BASE_UDP_SEND="$HISTORY_UDP_SEND"; BASE_RETRANS="$HISTORY_RETRANS"
  BASE_LISTEN="$HISTORY_LISTEN"; BASE_QDISC="$HISTORY_QDISC"
  BASE_UDP_RCV="$HISTORY_UDP_RCV"; BASE_SOFTNET="$HISTORY_SOFTNET"; BASE_DRIVER="$HISTORY_DRIVER"
  BASE_BACKLOG="$CURRENT_QDISC_BACKLOG"
  BASE_DRIVER_VALID="$CURRENT_DRIVER_VALID"
  BASE_DRIVER_ID="${DETAIL_PREV_DRIVER_ID:-none}"
  BASE_QDISC_ID="${DETAIL_PREV_QDISC_ID:-none}"
  TRIAL_DETAIL_SEEN=0
  name=$(_group_name "$reason") || return 1
  original="${!name}"
  save_active "$PENDING_FILE" || return 1
  JOURNAL_OWNED=1
  case "$reason" in
    rx_backlog)
      cap=$(backlog_cap)
      [ "$ACTIVE_BACKLOG" -lt "$cap" ] || { _clear_trial_journal; return 1; }
      ACTIVE_BACKLOG=$(clamp_value $(( ACTIVE_BACKLOG + ACTIVE_BACKLOG / 4 + 1 )) 1 "$cap") ;;
    napi_budget)
      [ "$ACTIVE_BUDGET" -lt 2048 ] || { _clear_trial_journal; return 1; }
      ACTIVE_BUDGET=$(clamp_value $(( ACTIVE_BUDGET + ACTIVE_BUDGET / 4 + 1 )) 1 2048) ;;
    rx_coalesce)
      if [ "$COALESCE_SUPPORTED" != 1 ] || [ "$ACTIVE_ADAPTIVE_RX" = on ]; then _clear_trial_journal; return 1; fi
      [ "$ACTIVE_COALESCE" -lt 32 ] || { _clear_trial_journal; return 1; }
      ACTIVE_COALESCE=$(clamp_value $(( ACTIVE_COALESCE + 4 )) 1 32) ;;
    *) _clear_trial_journal; return 1 ;;
  esac
  if ! _write_trial_meta "$reason" "$original"; then
    _clear_trial_journal || true
    read_current_parameters || true
    return 1
  fi
  if ! apply_parameter_group "$reason" "$original"; then
    # The actuator already attempted transactional rollback; retain the
    # journal until the original complete group has been confirmed restored.
    rollback_trial actuator_rollback || return 1
    return 1
  fi
  if [ "$ACTUATOR_CHANGED" -ne 1 ]; then
    _clear_trial_journal; LAST_REASON=actuator_unsupported; return 1
  fi
  TRIAL_GROUP="$reason"; TRIAL_ACTIVE=1; TRIAL_STARTED=$(monotonic_millis)
  TRIAL_FIRST_WINDOW=1
  TRIAL_SAMPLES=0; TRIAL_ERROR_SUM=0; TRIAL_RX_SUM=0; TRIAL_TX_SUM=0
  TRIAL_ELAPSED_MS=0; TRIAL_RX_PPS_SUM=0; TRIAL_TX_PPS_SUM=0; TRIAL_KERNEL_SUM=0; TRIAL_SQUEEZE_SUM=0
  TRIAL_RTT_SEEN=0
  TRIAL_STATUS=observing; VERIFICATION_SCOPE=local_only; LAST_REASON=trial_started
  return 0
}
metric_regressed() {
  local current="$1" baseline="$2" tolerance
  tolerance=$(( baseline + baseline / 4 ))
  [ "$baseline" -eq 0 ] || tolerance=$(( tolerance + 1 ))
  [ "$current" -gt "$tolerance" ]
}
evaluate_trial() {
  local now="${1:-$(monotonic_millis)}" avg_error avg_rx avg_tx total_base total_now avg_rx_pps avg_tx_pps avg_kernel avg_squeeze elapsed improved=0 context_status=0
  [ "$TRIAL_ACTIVE" -eq 1 ] || return 0
  _trial_parameters_match || context_status=$?
  if [ "$context_status" = 2 ]; then rollback_trial trial_parameters_unobservable; return; fi
  if [ "$context_status" = 3 ]; then rollback_trial external_parameters_changed; return; fi
  refresh_window_rates
  if [ "$CURRENT_DETAIL_VALID" != 1 ] || { [ "${BASE_DRIVER_VALID:-0}" = 1 ] && [ "$CURRENT_DRIVER_VALID" != 1 ]; }; then
    rollback_trial trial_detail_unavailable; return
  fi
  if { [ "${BASE_DRIVER_ID:-none}" != none ] && [ "${DETAIL_PREV_DRIVER_ID:-none}" != "$BASE_DRIVER_ID" ]; } || { [ "${BASE_QDISC_ID:-none}" != none ] && [ "${DETAIL_PREV_QDISC_ID:-none}" != "$BASE_QDISC_ID" ]; }; then
    rollback_trial trial_counter_context_changed; return
  fi
  if [ "${DETAIL_EVENT_NEW:-0}" = 1 ] && [ "${DETAIL_EVENT_STAMP_MS:-0}" -gt "$TRIAL_STARTED" ] && [ "${DETAIL_EVENT_QDISC_MS:-0}" -gt 0 ] && [ "${DETAIL_EVENT_LISTEN_MS:-0}" -gt 0 ]; then
    if [ $(( ${DETAIL_PREV_QDISC_TS:-0} - DETAIL_EVENT_QDISC_MS )) -ge "$TRIAL_STARTED" ] && [ $(( ${DETAIL_PREV_LISTEN_TS:-0} - DETAIL_EVENT_LISTEN_MS )) -ge "$TRIAL_STARTED" ]; then
      if [ "${BASE_DRIVER_VALID:-0}" != 1 ] || { [ "${DETAIL_EVENT_DRIVER_MS:-0}" -gt 0 ] && [ $(( ${DETAIL_PREV_DRIVER_TS:-0} - DETAIL_EVENT_DRIVER_MS )) -ge "$TRIAL_STARTED" ]; }; then TRIAL_DETAIL_SEEN=1; fi
    fi
  fi
  if [ "$CURRENT_METRICS_VALID" != 1 ] || [ "$CURRENT_RESET" != 0 ] || [ "$CURRENT_STEAL" -ge "$STEAL_HIGH" ]; then
    rollback_trial trial_invalid_sample; return
  fi
  if [ "$BASE_FLOW_FINGERPRINT" != unknown ] && [ "${DIAG_FLOW_FINGERPRINT:-unknown}" != unknown ] && [ "$BASE_FLOW_FINGERPRINT" != "$DIAG_FLOW_FINGERPRINT" ]; then
    rollback_trial trial_connections_changed; return
  fi
  # Do not attribute a window spanning parameter application to the new values.
  if [ "${TRIAL_FIRST_WINDOW:-0}" = 1 ]; then
    TRIAL_FIRST_WINDOW=0
    if [ "${CURRENT_SAMPLE_START_MS:-0}" -gt 0 ] && [ "$CURRENT_SAMPLE_START_MS" -lt "$TRIAL_STARTED" ]; then return 0; fi
  fi
  # Protect each category independently; an improved max must not hide another regression.
  if metric_regressed "$CURRENT_UDP_RCV_RATE" "$BASE_UDP_RCV" || metric_regressed "$CURRENT_SOFTNET_RATE" "$BASE_SOFTNET" || metric_regressed "$CURRENT_DRIVER_DROPS" "$BASE_DRIVER"; then
    LAST_REJECTED_GROUP="$TRIAL_GROUP"; LAST_REJECTED_AT="$now"
    rollback_trial trial_error_regression; return
  fi
  if metric_regressed "$CURRENT_UDP_SEND_RATE" "$BASE_UDP_SEND" || [ "$CURRENT_RETRANS_BP" -gt $(( BASE_RETRANS + 50 )) ] || metric_regressed "$CURRENT_LISTEN_DROPS" "$BASE_LISTEN" || metric_regressed "$CURRENT_QDISC_DROPS" "$BASE_QDISC"; then
    LAST_REJECTED_GROUP="$TRIAL_GROUP"; LAST_REJECTED_AT="$now"
    rollback_trial trial_error_regression; return
  fi
  if [ "$BASE_RTT" -gt 0 ] && [ "$CURRENT_RTT_VALID" = 1 ] && [ "${DIAG_FLOW_FINGERPRINT:-unknown}" = "$BASE_FLOW_FINGERPRINT" ] && [ "$BASE_FLOW_FINGERPRINT" != unknown ]; then
    if [ "${DIAG_MONOTONIC_MS:-0}" -gt "$TRIAL_STARTED" ]; then TRIAL_RTT_SEEN=1; fi
    if [ "$CURRENT_RTT_US" -gt $(( BASE_RTT + BASE_RTT / 10 + 5000 )) ]; then
      LAST_REJECTED_GROUP="$TRIAL_GROUP"; LAST_REJECTED_AT="$now"
      rollback_trial trial_latency_regression; return
    fi
  fi
  if [ "$CURRENT_QDISC_VALID" != 1 ] || [ "$CURRENT_QDISC_BACKLOG" -gt $(( BASE_BACKLOG + 65536 )) ]; then
    LAST_REJECTED_GROUP="$TRIAL_GROUP"; LAST_REJECTED_AT="$now"
    rollback_trial trial_queue_regression; return
  fi
  TRIAL_SAMPLES=$(( TRIAL_SAMPLES + 1 ))
  elapsed="$CURRENT_ELAPSED_MS"
  TRIAL_ELAPSED_MS=$(( TRIAL_ELAPSED_MS + elapsed ))
  TRIAL_ERROR_SUM=$(( TRIAL_ERROR_SUM + CURRENT_ERROR_RATE * elapsed ))
  TRIAL_RX_SUM=$(( TRIAL_RX_SUM + CURRENT_RX_BPS * elapsed )); TRIAL_TX_SUM=$(( TRIAL_TX_SUM + CURRENT_TX_BPS * elapsed ))
  TRIAL_RX_PPS_SUM=$(( TRIAL_RX_PPS_SUM + CURRENT_RX_PPS * elapsed )); TRIAL_TX_PPS_SUM=$(( TRIAL_TX_PPS_SUM + CURRENT_TX_PPS * elapsed ))
  TRIAL_KERNEL_SUM=$(( TRIAL_KERNEL_SUM + (CURRENT_SOFTIRQ + CURRENT_HARDIRQ) * elapsed )); TRIAL_SQUEEZE_SUM=$(( TRIAL_SQUEEZE_SUM + CURRENT_SQUEEZE_RATE * elapsed ))
  [ $(( now - TRIAL_STARTED )) -ge $(( TRIAL_SECONDS * 1000 )) ] || return 0
  [ "$TRIAL_ELAPSED_MS" -gt 0 ] || { rollback_trial trial_invalid_sample; return; }
  avg_error=$(( TRIAL_ERROR_SUM / TRIAL_ELAPSED_MS ))
  avg_rx=$(( TRIAL_RX_SUM / TRIAL_ELAPSED_MS )); avg_tx=$(( TRIAL_TX_SUM / TRIAL_ELAPSED_MS ))
  avg_rx_pps=$(( TRIAL_RX_PPS_SUM / TRIAL_ELAPSED_MS )); avg_tx_pps=$(( TRIAL_TX_PPS_SUM / TRIAL_ELAPSED_MS ))
  avg_kernel=$(( TRIAL_KERNEL_SUM / TRIAL_ELAPSED_MS )); avg_squeeze=$(( TRIAL_SQUEEZE_SUM / TRIAL_ELAPSED_MS ))
  if { [ "$BASE_RX_PPS" -gt 0 ] && { [ "$avg_rx_pps" -lt $(( BASE_RX_PPS * 80 / 100 )) ] || [ "$avg_rx_pps" -gt $(( BASE_RX_PPS * 125 / 100 )) ]; }; } || { [ "$BASE_TX_PPS" -gt 0 ] && { [ "$avg_tx_pps" -lt $(( BASE_TX_PPS * 80 / 100 )) ] || [ "$avg_tx_pps" -gt $(( BASE_TX_PPS * 125 / 100 )) ]; }; }; then
    rollback_trial trial_packet_mix_changed; return
  fi
  total_base=$(( BASE_RX + BASE_TX )); total_now=$(( avg_rx + avg_tx ))
  if [ "$total_base" -le 0 ] || [ "$avg_rx" -lt $(( BASE_RX * 80 / 100 )) ] || [ "$avg_rx" -gt $(( BASE_RX * 125 / 100 )) ] || [ "$total_now" -gt $(( total_base * 125 / 100 )) ]; then
    rollback_trial trial_load_changed; return
  fi
  if [ "$BASE_TX" -gt 100000 ] && [ "$avg_tx" -lt $(( BASE_TX * 95 / 100 )) ]; then
    LAST_REJECTED_GROUP="$TRIAL_GROUP"; LAST_REJECTED_AT="$now"
    rollback_trial trial_throughput_regression; return
  fi
  if [ "$BASE_ERROR" -gt 0 ] && [ "$avg_error" -lt "$BASE_ERROR" ] && [ "$avg_error" -le $(( BASE_ERROR * 80 / 100 )) ]; then improved=1; fi
  if [ "$avg_error" -le "$BASE_ERROR" ]; then
    if [ "$TRIAL_GROUP" = rx_coalesce ] && [ "$BASE_KERNEL" -ge 10 ] && [ "$avg_kernel" -le $(( BASE_KERNEL * 80 / 100 )) ]; then improved=1; fi
    if [ "$TRIAL_GROUP" = napi_budget ] && [ "$BASE_SQUEEZE" -gt 0 ] && [ "$avg_squeeze" -lt "$BASE_SQUEEZE" ] && [ "$avg_kernel" -le $(( BASE_KERNEL + 5 )) ]; then improved=1; fi
  fi
  if [ "${TRIAL_DETAIL_SEEN:-0}" != 1 ]; then rollback_trial trial_detail_unobserved; return; fi
  if [ "$BASE_RTT" -gt 0 ] && [ "$TRIAL_RTT_SEEN" -ne 1 ]; then rollback_trial trial_latency_unobserved; return; fi
  if [ "$improved" -eq 1 ]; then
    if save_active "$BEST_FILE"; then
      _clear_trial_journal || { rollback_trial trial_state_write_failed; return; }; TRIAL_ACTIVE=0; TRIAL_STATUS=local_improvement
      VERIFICATION_SCOPE=local_only; LAST_REASON=trial_local_improved
      CURRENT_COOLDOWN="$COOLDOWN_SECONDS"; HISTORY_SAMPLES=0
    else
      rollback_trial trial_state_write_failed
    fi
  else
    LAST_REJECTED_GROUP="$TRIAL_GROUP"; LAST_REJECTED_AT="$now"
    rollback_trial trial_no_improvement
  fi
}

write_state() {
  local level="${1:-2}" reason="${2:-$LAST_REASON}" status="${3:-running}" tmp="$STATE_FILE.tmp.$$" name
  {
    printf 'STATUS=%q\nLEVEL=%q\nREASON=%q\n' "$status" "$level" "$reason"
    printf 'PPS=%q\nRX_PPS=%q\nTX_PPS=%q\nRX_BPS=%q\nTX_BPS=%q\n' "$CURRENT_PPS" "$CURRENT_RX_PPS" "$CURRENT_TX_PPS" "$CURRENT_RX_BPS" "$CURRENT_TX_BPS"
    printf 'SOFTIRQ_PCT=%q\nHARDIRQ_PCT=%q\nSTEAL_PCT=%q\nCPU_BUSY_PCT=%q\n' "$CURRENT_SOFTIRQ" "$CURRENT_HARDIRQ" "$CURRENT_STEAL" "$CURRENT_CPU_BUSY"
    # Compatibility DROP_DELTA now counts only softnet drops in this sample.
    printf 'DROP_DELTA=%q\nSQUEEZE_DELTA=%q\nDRIVER_DROP_RATE=%q\n' "$CURRENT_SOFT_DROPS" "$CURRENT_SQUEEZE" "$CURRENT_DRIVER_DROPS"
    printf 'UDP_RCVBUF_DELTA=%q\nUDP_SNDBUF_DELTA=%q\nUDP_ERROR_DELTA=%q\n' "$CURRENT_UDP_RCVBUF" "$CURRENT_UDP_SNDBUF" "$CURRENT_UDP_ERRORS"
    printf 'TCP_RETRANS_DELTA=%q\nTCP_RETRANS_BP=%q\n' "$CURRENT_RETRANS" "$CURRENT_RETRANS_BP"
    printf 'LISTEN_DROP_RATE=%q\nQDISC_DROP_RATE=%q\nQDISC_BACKLOG_BYTES=%q\n' "$CURRENT_LISTEN_DROPS" "$CURRENT_QDISC_DROPS" "$CURRENT_QDISC_BACKLOG"
    printf 'QDISC_POLICY=%q\nQDISC_AQM_DROP_RATE=%q\n' "${CURRENT_QDISC_POLICY:-unknown}" "${CURRENT_QDISC_AQM_DROPS:-0}"
    printf 'METRICS_VALID=%q\nDETAIL_VALID=%q\nDRIVER_VALID=%q\nQDISC_VALID=%q\n' "$CURRENT_METRICS_VALID" "$CURRENT_DETAIL_VALID" "$CURRENT_DRIVER_VALID" "$CURRENT_QDISC_VALID"
    printf 'PRESSURE_SCORE=%q\nMACHINE=%q\n' "$CURRENT_PRESSURE_SCORE" "${CPU_COUNT}cpu/${PHYSICAL_COUNT}core/${MEM_KB}KiB/${NUMA_COUNT}numa/${RX_QUEUES}rxq"
    for name in "${PARAMETER_NAMES[@]}" ACTIVE_COALESCE ACTIVE_ADAPTIVE_RX ACTIVE_ADAPTIVE_TX TRIAL_STATUS TRIAL_GROUP VERIFICATION_SCOPE; do printf '%s=%q\n' "$name" "${!name}"; done
    printf 'COOLDOWN_REMAINING=%q\nSAMPLE_SECONDS=%q\nUPDATED_AT=%q\n' "$CURRENT_COOLDOWN" "$INTERVAL" "$(date +%F_%T)"
  } > "$tmp" && mv -f "$tmp" "$STATE_FILE"
}
append_metric() {
  local reason="${1:-$LAST_REASON}" now="${2:-0}" tmp="$METRICS_LOG.tmp.$$"
  [ $(( now - ${LAST_LOG_TS:-0} )) -ge 5000 ] || return 0
  LAST_LOG_TS="$now"
  printf '%s rx_pps=%s tx_pps=%s rx_bps=%s tx_bps=%s softirq=%s irq=%s steal=%s softnet=%s driver_rate=%s udp_rx=%s udp_tx=%s retrans_bp=%s qdisc_bytes=%s trial=%s scope=%s reason=%s\n' \
    "$(date +%F_%T)" "$CURRENT_RX_PPS" "$CURRENT_TX_PPS" "$CURRENT_RX_BPS" "$CURRENT_TX_BPS" "$CURRENT_SOFTIRQ" "$CURRENT_HARDIRQ" "$CURRENT_STEAL" "$CURRENT_SOFT_DROPS" "$CURRENT_DRIVER_DROPS" "$CURRENT_UDP_RCVBUF" "$CURRENT_UDP_SNDBUF" "$CURRENT_RETRANS_BP" "$CURRENT_QDISC_BACKLOG" "$TRIAL_STATUS" "$VERIFICATION_SCOPE" "$reason" >> "$METRICS_LOG"
  LOG_WINDOWS=$(( ${LOG_WINDOWS:-0} + 1 ))
  if [ "$LOG_WINDOWS" -ge 120 ]; then
    tail -n 10000 "$METRICS_LOG" > "$tmp" && mv -f "$tmp" "$METRICS_LOG"
    LOG_WINDOWS=0
  fi
}
release_lock() {
  local token= owner=
  [ -r "$LOCK_DIR/pid" ] && read -r owner < "$LOCK_DIR/pid" || return 0
  [ "$owner" = "$$" ] || return 0
  [ -r "$LOCK_DIR/token" ] && read -r token < "$LOCK_DIR/token" || return 0
  [ "$token" = "${LOCK_OWNER_TOKEN:-}" ] && [ -n "$token" ] || return 0
  if [ -n "$DIAG_PID" ]; then kill "$DIAG_PID" 2>/dev/null || true; wait "$DIAG_PID" 2>/dev/null || true; fi
  if declare -F stop_detail_worker >/dev/null; then stop_detail_worker; fi
  if [ -e "$PENDING_META_FILE" ] && { [ "$TRIAL_ACTIVE" -eq 1 ] || [ "${JOURNAL_OWNED:-0}" = 1 ]; }; then
    rollback_trial trial_interrupted || true
  elif [ "${JOURNAL_OWNED:-0}" = 1 ] && [ "$TRIAL_ACTIVE" -eq 0 ]; then
    # This process created the baseline but was interrupted before it wrote metadata/applied anything.
    rm -f "$PENDING_FILE"
  fi
  rm -f "$CPU_PREV_FILE" "$CPU_NOW_FILE"
  rm -rf "$LOCK_DIR"
  if [ "${LOCK_METHOD:-}" = flock ]; then flock -u 9; exec 9>&-; fi
}
_wait_config_guard() {
  local seconds attempts
  seconds=$(uint "${NTC_CONFIG_WAIT_SECONDS:-30}" 30 60)
  attempts=$(( seconds * 10 ))
  while ! flock -n -s 8; do
    [ "$attempts" -gt 0 ] || return 1
    # BusyBox flock lacks -w. Poll only during startup, with a finite bound.
    command sleep 0.1 || return 1
    attempts=$(( attempts - 1 ))
  done
  return 0
}

acquire_lock() {
  local start= config_guard=0
  LOCK_METHOD=mkdir
  if command -v flock >/dev/null 2>&1; then
    if [ "${NTC_CONFIG_LOCK_HELD:-0}" = 1 ]; then
      case "${1:-loop}" in calibrate|level-2) : ;; *) return 1 ;; esac
      # The installer supplies its inherited exclusive configuration fd8.
      [ -e "$PROC_ROOT/self/fd/8" ] || [ -e /proc/self/fd/8 ] || return 1
    else
      exec 8>"$WORKDIR/configuration.lock" || return 1
      if [ "${1:-loop}" = loop ]; then
        # systemd may start this process before its installer releases fd8.
        # Wait for the configuration transaction to finish before reading it.
        if ! _wait_config_guard; then exec 8>&-; return 1; fi
      elif ! flock -n -s 8; then exec 8>&-; return 1; fi
      config_guard=1
    fi
  fi
  if command -v flock >/dev/null 2>&1; then
    if ! exec 9>"$LOCK_FILE"; then [ "$config_guard" != 1 ] || exec 8>&-; return 1; fi
    if ! flock -n 9; then exec 9>&-; [ "$config_guard" != 1 ] || exec 8>&-; echo '控制器锁正在使用。' >&2; return 1; fi
    LOCK_METHOD=flock
  fi
  if _existing_lock_busy; then
    [ "$LOCK_METHOD" != flock ] || { flock -u 9; exec 9>&-; }
    [ "$config_guard" != 1 ] || exec 8>&-
    echo '控制器锁仍有活动所有者或正在初始化。' >&2; return 1
  fi
  if [ -d "$LOCK_DIR" ]; then
    # Without flock there is no atomic compare-and-remove for a directory.
    # Keep stale locks for explicit cleanup rather than race another creator.
    if [ "$LOCK_METHOD" != flock ]; then
      echo '旧目录锁需要清理；未取得独占锁。' >&2
      return 1
    fi
    if ! rm -rf "$LOCK_DIR"; then flock -u 9; exec 9>&-; [ "$config_guard" != 1 ] || exec 8>&-; return 1; fi
  fi
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    [ "$LOCK_METHOD" != flock ] || { flock -u 9; exec 9>&-; }
    [ "$config_guard" != 1 ] || exec 8>&-
    return 1
  fi
  start=$(_process_start "$$" 2>/dev/null || true)
  LOCK_OWNER_TOKEN="$$:${start:-unknown}:${RANDOM}:${RANDOM}"
  if ! { printf '%s\n' "$$" > "$LOCK_DIR/pid" && printf '%s\n' "$start" > "$LOCK_DIR/start" && printf '%s\n' "$LOCK_OWNER_TOKEN" > "$LOCK_DIR/token"; }; then
    rm -rf "$LOCK_DIR"
    [ "$LOCK_METHOD" != flock ] || { flock -u 9; exec 9>&-; }
    [ "$config_guard" != 1 ] || exec 8>&-
    return 1
  fi
  trap release_lock EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  [ "$config_guard" != 1 ] || exec 8>&-
  return 0
}
calibrate() {
  if [ -e "$WORKDIR/sysctl-boot-pending" ]; then
    TRIAL_STATUS=restore_failed; LAST_REASON=rollback_pending
    write_state 2 rollback_pending failed
    return 1
  fi
  calculate_level_parameters 2
  read_current_parameters || { write_state 2 metrics_unavailable failed; return 1; }
  # Startup is observational. Historical BEST records must not replay over
  # another NIC, another host, or an administrator's current configuration.
  if [ -e "$PAUSE_FILE" ]; then
    TRIAL_STATUS=paused; VERIFICATION_SCOPE=unverified
    write_state 2 user_paused paused
    return 0
  fi
  if [ -e "$PENDING_FILE" ] || [ -e "$PENDING_META_FILE" ]; then
    rollback_trial trial_recovered || { write_state 2 "$LAST_REASON" failed; return 1; }
  fi
  save_active "$BASELINE_FILE" || return 1
  [ -e "$BEST_FILE" ] || save_active "$BEST_FILE" || return 1
  TRIAL_STATUS=baseline; VERIFICATION_SCOPE=unverified
  write_state 2 calibrated
}
take_sample() {
  local rx=-1 tx=-1 rb=-1 tb=-1 sd=0 sq=0 sv=0 rt=0 out=0 ui=0 ur=0 us=0 pv=0 ts valid=1
  rx=$(read_counter "$SYS_ROOT/class/net/$DEV/statistics/rx_packets") || valid=0
  tx=$(read_counter "$SYS_ROOT/class/net/$DEV/statistics/tx_packets") || valid=0
  rb=$(read_counter "$SYS_ROOT/class/net/$DEV/statistics/rx_bytes") || valid=0
  tb=$(read_counter "$SYS_ROOT/class/net/$DEV/statistics/tx_bytes") || valid=0
  read -r sd sq sv < <(softnet_totals)
  read -r rt out ui ur us pv < <(protocol_counters)
  [ "$sv" = 1 ] && [ "$pv" = 1 ] || valid=0
  ts=$(monotonic_millis)
  SAMPLE=("$rx" "$tx" "$rb" "$tb" "$sd" "$sq" "$rt" "$out" "$ui" "$ur" "$us" "$ts" "$valid")
}
collect_window() {
  local elapsed i cpu_valid=0 sd_rate udp_rate
  local -a delta=()
  take_sample
  elapsed=$(( SAMPLE[11] - PREVIOUS_SAMPLE[11] )); [ "$elapsed" -gt 0 ] || elapsed=$(( INTERVAL * 1000 ))
  CURRENT_METRICS_VALID=1; CURRENT_RESET=0; CURRENT_ELAPSED_MS="$elapsed"
  CURRENT_SAMPLE_START_MS="${PREVIOUS_SAMPLE[11]}"
  [ "${SAMPLE[12]}" = 1 ] && [ "${PREVIOUS_SAMPLE[12]}" = 1 ] || CURRENT_METRICS_VALID=0
  for ((i=0;i<11;i++)); do
    delta[$i]=$(( SAMPLE[i] - PREVIOUS_SAMPLE[i] ))
    [ "${delta[$i]}" -ge 0 ] || { delta[$i]=0; CURRENT_RESET=1; }
  done
  cpu_snapshot > "$CPU_NOW_FILE"
  read -r CURRENT_SOFTIRQ CURRENT_STEAL CURRENT_HARDIRQ CURRENT_CPU_BUSY cpu_valid < <(cpu_window_pressure "$CPU_PREV_FILE" "$CPU_NOW_FILE")
  [ "$cpu_valid" = 1 ] || CURRENT_METRICS_VALID=0
  mv -f "$CPU_NOW_FILE" "$CPU_PREV_FILE"
  CURRENT_RX_PPS=$(( delta[0] * 1000 / elapsed )); CURRENT_TX_PPS=$(( delta[1] * 1000 / elapsed ))
  CURRENT_PPS=$(( CURRENT_RX_PPS + CURRENT_TX_PPS ))
  CURRENT_RX_BPS=$(( delta[2] * 8000 / elapsed )); CURRENT_TX_BPS=$(( delta[3] * 8000 / elapsed ))
  CURRENT_SOFT_DROPS="${delta[4]}"; CURRENT_SQUEEZE="${delta[5]}"; CURRENT_DROPS="$CURRENT_SOFT_DROPS"
  CURRENT_RETRANS="${delta[6]}"; CURRENT_RETRANS_BP=0
  if [ "${delta[7]}" -gt 0 ]; then CURRENT_RETRANS_BP=$(( delta[6] * 10000 / delta[7] )); elif [ "${delta[6]}" -gt 0 ]; then CURRENT_RETRANS_BP=10000; fi
  CURRENT_UDP_ERRORS="${delta[8]}"; CURRENT_UDP_RCVBUF="${delta[9]}"; CURRENT_UDP_SNDBUF="${delta[10]}"
  # A maximum of local pressure signals, not a sum of unique lost packets.
  sd_rate=$(( (delta[4] * 1000 + elapsed - 1) / elapsed )); udp_rate="$CURRENT_UDP_ERRORS"
  [ "$CURRENT_UDP_RCVBUF" -le "$udp_rate" ] || udp_rate="$CURRENT_UDP_RCVBUF"
  udp_rate=$(( (udp_rate * 1000 + elapsed - 1) / elapsed ))
  CURRENT_ERROR_RATE="$sd_rate"
  [ "$CURRENT_DRIVER_DROPS" -le "$CURRENT_ERROR_RATE" ] || CURRENT_ERROR_RATE="$CURRENT_DRIVER_DROPS"
  [ "$udp_rate" -le "$CURRENT_ERROR_RATE" ] || CURRENT_ERROR_RATE="$udp_rate"
  CURRENT_PRESSURE_SCORE=0
  [ "$CURRENT_ERROR_RATE" -eq 0 ] || CURRENT_PRESSURE_SCORE=$(( CURRENT_PRESSURE_SCORE + 4 ))
  [ "$CURRENT_SQUEEZE" -eq 0 ] || CURRENT_PRESSURE_SCORE=$(( CURRENT_PRESSURE_SCORE + 3 ))
  [ "$CURRENT_SOFTIRQ" -lt "$SOFTIRQ_HIGH" ] || CURRENT_PRESSURE_SCORE=$(( CURRENT_PRESSURE_SCORE + 3 ))
  PREVIOUS_SAMPLE=("${SAMPLE[@]}")
}
controller_loop() {
  local now started last_detail=0 last_diag=0 pressure=0 reason group="" last_tick
  [[ "$DEV" =~ ^[a-zA-Z0-9_.:-]+$ ]] || { echo '无效网卡名称。' >&2; return 1; }
  calibrate || return 1
  take_sample; PREVIOUS_SAMPLE=("${SAMPLE[@]}"); cpu_snapshot > "$CPU_PREV_FILE"
  started=$(monotonic_millis); last_tick="$started"
  while sleep "$INTERVAL"; do
    collect_window; now="${SAMPLE[11]}"
    CURRENT_COOLDOWN=$(( CURRENT_COOLDOWN - (now - last_tick) / 1000 )); [ "$CURRENT_COOLDOWN" -ge 0 ] || CURRENT_COOLDOWN=0
    last_tick="$now"
    if [ $(( now - last_detail )) -ge $(( DETAIL_INTERVAL * 1000 )) ]; then launch_details "$now"; last_detail="$now"; fi
    read_detail_snapshot "$now"
    # Include freshly consumed driver pressure in this control window.
    [ "$CURRENT_DRIVER_DROPS" -le "$CURRENT_ERROR_RATE" ] || CURRENT_ERROR_RATE="$CURRENT_DRIVER_DROPS"
    if [ $(( now - last_diag )) -ge $(( DIAG_INTERVAL * 1000 )) ]; then launch_diagnostics; last_diag="$now"; fi
    read_diagnostics "$now"
    reason=steady; group=""
    if [ -e "$PAUSE_FILE" ]; then
      if [ "$TRIAL_ACTIVE" = 1 ] && ! rollback_trial trial_paused; then
        write_state 2 "$LAST_REASON" failed
        return 1
      fi
      pressure=0; HISTORY_SAMPLES=0; write_state 2 user_paused paused; continue
    fi
    if [ "$TRIAL_ACTIVE" = 0 ] && { [ -e "$PENDING_FILE" ] || [ -e "$PENDING_META_FILE" ]; }; then
      rollback_trial trial_recovered || { write_state 2 "$LAST_REASON" failed; return 1; }
      HISTORY_SAMPLES=0; pressure=0; write_state 2 "$LAST_REASON"; continue
    fi
    if [ "$CURRENT_METRICS_VALID" != 1 ] || [ "$CURRENT_RESET" != 0 ]; then
      if [ "$TRIAL_ACTIVE" -eq 1 ]; then rollback_trial trial_invalid_sample || return 1; fi
      pressure=0; HISTORY_SAMPLES=0; started="$now"
      reason=metrics_unavailable; [ "$CURRENT_RESET" -eq 0 ] || reason=counter_reset
    elif [ "$CURRENT_STEAL" -ge "$STEAL_HIGH" ]; then
      [ "$TRIAL_ACTIVE" -ne 1 ] || rollback_trial host_steal_pressure || return 1
      pressure=0; HISTORY_SAMPLES=0; reason=host_steal_pressure
    elif [ "$TRIAL_ACTIVE" -eq 1 ]; then
      evaluate_trial "$now" || return 1; reason="$LAST_REASON"
    elif [ $(( now - started )) -lt $(( WARMUP_SECONDS * 1000 )) ]; then
      remember_window; reason=learning_baseline
    elif [ "$CURRENT_COOLDOWN" -gt 0 ]; then
      remember_window; reason=cooldown_hold
    else
      if [ "$CURRENT_UDP_RCVBUF" -gt 0 ] || [ "$CURRENT_UDP_SNDBUF" -gt 0 ] || [ "$CURRENT_LISTEN_DROPS" -gt 0 ]; then
        reason=application_socket_pressure
      elif [ "$CURRENT_QDISC_DROPS" -gt 0 ] || [ "$CURRENT_QDISC_BACKLOG" -gt 262144 ]; then
        reason=egress_queue_pressure
      elif [ "$CURRENT_SOFT_DROPS" -gt 0 ]; then
        group=rx_backlog; reason=pressure_detected
      elif [ "$CURRENT_DRIVER_DROPS" -gt 0 ]; then
        reason=nic_receive_pressure
        [ "$CURRENT_SOFTIRQ" -lt "$SOFTIRQ_HIGH" ] || group=rx_coalesce
      elif [ "$CURRENT_SQUEEZE" -gt 0 ] && [ "$CURRENT_SOFTIRQ" -lt "$SOFTIRQ_HIGH" ]; then
        group=napi_budget; reason=pressure_detected
      elif [ "$CURRENT_SOFTIRQ" -ge "$SOFTIRQ_HIGH" ]; then
        group=rx_coalesce; reason=pressure_detected
      elif [ "$CURRENT_RETRANS_BP" -ge 50 ]; then
        reason=retransmission_observed
      fi
      if [ -n "$group" ]; then
        pressure=$(( pressure + 1 ))
        if [ "$pressure" -ge "$UP_WINDOWS" ]; then
          if begin_trial "$group"; then reason=trial_started; else reason=bounded_hold; fi
          pressure=0
        fi
      else
        pressure=0
      fi
      [ "$TRIAL_ACTIVE" -eq 1 ] || remember_window
    fi
    LAST_REASON="$reason"
    if [ "$TRIAL_STATUS" = restore_failed ]; then write_state 2 rollback_failed failed; return 1; fi
    write_state 2 "$reason"
    append_metric "$reason" "$now"
  done
}

_controller_context() {
  local boot=unknown netns=unknown index=unknown
  [ ! -r "$PROC_ROOT/sys/kernel/random/boot_id" ] || read -r boot < "$PROC_ROOT/sys/kernel/random/boot_id"
  netns=$(readlink "$PROC_ROOT/self/ns/net" 2>/dev/null || echo unknown)
  [ ! -r "$SYS_ROOT/class/net/$DEV/ifindex" ] || read -r index < "$SYS_ROOT/class/net/$DEV/ifindex"
  printf '%s|%s|%s|%s\n' "$DEV" "$boot" "$netns" "$index"
}

_group_name() {
  case "$1" in rx_backlog) echo ACTIVE_BACKLOG ;; napi_budget) echo ACTIVE_BUDGET ;; rx_coalesce) echo ACTIVE_COALESCE ;; *) return 1 ;; esac
}

_group_wants_index() {
  case "$1:$2" in all:*|rx_backlog:0|napi_budget:1) return 0 ;; *) return 1 ;; esac
}

_write_trial_meta() {
  local group="$1" original="$2" name tmp="$PENDING_META_FILE.tmp.$$"
  name=$(_group_name "$group") || return 1
  {
    printf 'META_VERSION=1\nMETA_GROUP=%s\nMETA_CONTEXT=%s\nMETA_NAME=%s\n' "$group" "$(_controller_context)" "$name"
    printf 'META_ORIGINAL=%s\nMETA_EXPECTED=%s\nMETA_RX=%s\nMETA_TX=%s\n' "$original" "${!name}" "$ACTIVE_ADAPTIVE_RX" "$ACTIVE_ADAPTIVE_TX"
  } > "$tmp" && mv -f "$tmp" "$PENDING_META_FILE"
}

_read_trial_meta() {
  local key value count=0 seen='|' i expected
  local -a names=() values=()
  [ -r "$PENDING_META_FILE" ] || return 1
  while IFS='=' read -r key value; do
    case "$seen" in *"|$key|"*) return 1 ;; esac
    seen="$seen$key|"
    case "$key" in
      META_VERSION) [ "$value" = 1 ] || return 1 ;;
      META_GROUP) case "$value" in rx_backlog|napi_budget|rx_coalesce) ;; *) return 1 ;; esac ;;
      META_CONTEXT) [ -n "$value" ] && [ "${#value}" -le 512 ] || return 1 ;;
      META_NAME) case "$value" in ACTIVE_BACKLOG|ACTIVE_BUDGET|ACTIVE_COALESCE) ;; *) return 1 ;; esac ;;
      META_ORIGINAL|META_EXPECTED) case "$value" in ''|*[!0-9]*) return 1 ;; esac; [ "${#value}" -le 7 ] || return 1 ;;
      META_RX|META_TX) case "$value" in on|off|unknown) ;; *) return 1 ;; esac ;;
      *) return 1 ;;
    esac
    names+=("$key"); values+=("$value"); count=$((count+1))
  done < "$PENDING_META_FILE"
  [ "$count" -eq 8 ] || return 1
  for ((i=0;i<count;i++)); do printf -v "${names[$i]}" '%s' "${values[$i]}"; done
  expected=$(_group_name "$META_GROUP") || return 1
  [ "$META_NAME" = "$expected" ]
}

_clear_trial_journal() {
  rm -f "$PENDING_META_FILE" "$PENDING_FILE" || return 1
  JOURNAL_OWNED=0
}

_trial_current_value() {
  local key value supported rx tx
  if [ "$META_GROUP" = rx_coalesce ]; then
    read -r value rx tx supported < <(read_coalesce)
    [ "$supported" = 1 ] || return 2
    [ "$rx" = "$META_RX" ] && [ "$tx" = "$META_TX" ] || return 3
  else
    case "$META_GROUP" in rx_backlog) key=net.core.netdev_max_backlog ;; napi_budget) key=net.core.netdev_budget ;; *) return 2 ;; esac
    [ -e "$PROC_ROOT/sys/${key//.//}" ] || return 2
    value=$(sysctl -n "$key" 2>/dev/null) || return 2
    case "$value" in ''|*[!0-9]*) return 2 ;; esac
  fi
  printf '%s\n' "$value"
}

_trial_parameters_match() {
  local key name expected actual i current status=0
  local -a originals=()
  _read_trial_meta || return 2
  [ "$META_CONTEXT" = "$(_controller_context)" ] || return 3
  load_active "$PENDING_FILE" || return 2
  for name in "${PARAMETER_NAMES[@]}"; do originals+=("${!name}"); done
  for ((i=0;i<${#SNAPSHOT_KEYS[@]};i++)); do
    key="${SNAPSHOT_KEYS[$i]}"; name="${PARAMETER_NAMES[$i]}"; expected="${originals[$i]}"
    [ "$name" != "$META_NAME" ] || expected="$META_EXPECTED"
    [ -e "$PROC_ROOT/sys/${key//.//}" ] || continue
    actual=$(sysctl -n "$key" 2>/dev/null) || return 2
    case "$actual" in ''|*[!0-9]*) return 2 ;; esac
    printf -v "$name" '%s' "$actual"
    [ "$actual" = "$expected" ] || status=3
  done
  if [ "$META_GROUP" = rx_coalesce ]; then
    current=$(_trial_current_value) || return $?
    ACTIVE_COALESCE="$current"
    [ "$current" = "$META_EXPECTED" ] || status=3
  fi
  return "$status"
}

_process_start() {
  local pid="$1" line tail
  local -a fields=()
  [ -r "$PROC_ROOT/$pid/stat" ] || return 1
  read -r line < "$PROC_ROOT/$pid/stat" || return 1
  tail="${line##*) }"; [ "$tail" != "$line" ] || return 1
  read -ra fields <<< "$tail"
  case "${fields[19]:-}" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "${fields[19]}"
}

_existing_lock_busy() {
  local owner= start= actual= cmdline= born now
  [ -d "$LOCK_DIR" ] || return 1
  if [ -r "$LOCK_DIR/pid" ]; then
    read -r owner < "$LOCK_DIR/pid" || true
    case "$owner" in ''|*[!0-9]*) owner= ;; esac
  fi
  if [ -n "$owner" ]; then
    if kill -0 "$owner" 2>/dev/null; then
      if [ -r "$LOCK_DIR/start" ]; then
        read -r start < "$LOCK_DIR/start" || true
        actual=$(_process_start "$owner" 2>/dev/null || true)
        [ -z "$start" ] || [ -z "$actual" ] || [ "$start" = "$actual" ] || return 1
      fi
      # An unreadable/empty cmdline is not evidence that a live lock is stale.
      [ -r "$PROC_ROOT/$owner/cmdline" ] || return 0
      cmdline=$(tr '\0' ' ' < "$PROC_ROOT/$owner/cmdline" 2>/dev/null || true)
      [ -n "$cmdline" ] || return 0
      case "$cmdline" in *live-relay-auto-controller.sh*) return 0 ;; esac
      [ -z "$start" ] || return 0
    fi
    return 1
  fi
  # A creator can be between mkdir and publishing its PID. Leave a grace period.
  born=$(stat -c %Y "$LOCK_DIR" 2>/dev/null || true); now=$(date +%s)
  case "$born" in ''|*[!0-9]*) return 0 ;; esac
  [ $(( now - born )) -lt 30 ]
}

if [ "${NTC_SOURCE_ONLY:-0}" != 1 ]; then
  case "${1:-loop}" in
    loop) acquire_lock "${1:-loop}" && controller_loop ;;
    calibrate) acquire_lock "${1:-loop}" && calibrate ;;
    level-2) acquire_lock "${1:-loop}" && calibrate ;;
    status) [ ! -f "$STATE_FILE" ] || cat "$STATE_FILE" ;;
    *) echo "usage: $0 {loop|calibrate|level-2|status}"; exit 2 ;;
  esac
fi
EOF_AUTO
  chmod 0755 "$AUTO_HELPER"
}

build_auto_service() {
  local nofile
  nofile=$(effective_nofile_limit)
  cat > "$AUTO_SERVICE" <<EOF_AUTOSERVICE || return 1
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
LimitNOFILE=$nofile
TasksMax=128

[Install]
WantedBy=multi-user.target
EOF_AUTOSERVICE
}

write_auto_env() {
  local nic="$1" cpus physical memory_kb auto_nic=1 name value
  cpus=$(online_cpu_count); physical=$(physical_core_count); memory_kb=$(mem_total_kb)
  case "$physical" in ''|*[!0-9]*|0) physical="$cpus" ;; esac
  [ "$physical" -le "$cpus" ] || physical="$cpus"
  is_container && auto_nic=0
  {
    printf 'TUNER_VERSION=%q\n' "$VERSION"
    printf 'DEV=%q\nWORKDIR=%q\nDIAG_HELPER=%q\n' "$nic" "$WORKDIR" "$DIAG_HELPER"
    printf 'DATA_PLANE=%q\nONLINE_CPUS=%q\nPHYSICAL_CORES=%q\n' "$(detect_data_plane)" "$cpus" "$physical"
    printf 'MEMORY_KB=%q\nMEMORY_GB=%q\nNUMA_NODES=%q\n' "$memory_kb" "$(( (memory_kb + 1048575) / 1048576 ))" "$(numa_node_count)"
    printf 'RX_QUEUE_COUNT=%q\nNIC_DRIVER=%q\nNIC_SPEED_MBPS=%q\n' "$(nic_rx_queue_count "$nic")" "$(nic_driver_name "$nic")" "$(nic_speed_mbps "$nic")"
    printf 'AUTO_NIC_TUNING=%q\n' "$auto_nic"
    for name in AUTO_INTERVAL AUTO_DETAIL_INTERVAL AUTO_DIAG_INTERVAL AUTO_UP_WINDOWS AUTO_COOLDOWN_SECONDS AUTO_WARMUP_SECONDS AUTO_TRIAL_SECONDS SOFTIRQ_HIGH STEAL_HIGH; do
      case "$name" in
        AUTO_INTERVAL) value="${AUTO_INTERVAL:-1}" ;;
        AUTO_DETAIL_INTERVAL) value="${AUTO_DETAIL_INTERVAL:-10}" ;;
        AUTO_DIAG_INTERVAL) value="${AUTO_DIAG_INTERVAL:-30}" ;;
        AUTO_UP_WINDOWS) value="${AUTO_UP_WINDOWS:-3}" ;;
        AUTO_COOLDOWN_SECONDS) value="${AUTO_COOLDOWN_SECONDS:-120}" ;;
        AUTO_WARMUP_SECONDS) value="${AUTO_WARMUP_SECONDS:-15}" ;;
        AUTO_TRIAL_SECONDS) value="${AUTO_TRIAL_SECONDS:-30}" ;;
        SOFTIRQ_HIGH) value="${SOFTIRQ_HIGH:-70}" ;;
        STEAL_HIGH) value="${STEAL_HIGH:-5}" ;;
      esac
      printf '%s=%q\n' "$name" "$value"
    done
    for name in PROXY_PID PROXY_SERVICES MTU_PROBE_HOST MTU_PROBE_PAYLOAD; do
      printf '%s=%q\n' "$name" "${!name:-}"
    done
  } > "$AUTO_ENV_FILE"
}

remove_hia_baseline() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now hia-baseline.service >/dev/null 2>&1 || true
  fi
  rm -f "$HIA_SERVICE" "$HIA_HELPER" "$HIA_SYSCTL_FILE"
}

process_start_time() {
  local pid="$1" line rest
  [ -r "${PROC_ROOT:-/proc}/$pid/stat" ] || return 1
  IFS= read -r line < "${PROC_ROOT:-/proc}/$pid/stat" || return 1
  rest="${line##*) }"
  [ "$rest" != "$line" ] || return 1
  awk '{print $20}' <<< "$rest"
}

stop_auto_controller_for_reconfigure() {
  (
    local lock_dir="$WORKDIR/controller.lock" owner="" started="" actual="" cmdline attempts=0
    if command -v systemctl >/dev/null 2>&1 && systemctl show-environment >/dev/null 2>&1; then
      if ! systemctl stop live-relay-auto-controller.service >/dev/null 2>&1; then
        # systemd returns nonzero for a not-yet-installed unit on first setup.
        if systemctl cat live-relay-auto-controller.service >/dev/null 2>&1; then
          err "无法停止旧控制器，未开始配置。"; return 1
        fi
      fi
      if systemctl is-active --quiet live-relay-auto-controller.service; then return 1; fi
    fi
    if [ -r "$lock_dir/pid" ]; then
      read -r owner < "$lock_dir/pid" || true
      case "$owner" in ''|*[!0-9]*) owner="" ;; esac
      [ ! -r "$lock_dir/start" ] || read -r started < "$lock_dir/start" || true
      if [ -n "$owner" ] && kill -0 "$owner" 2>/dev/null; then
        actual=$(process_start_time "$owner" || true)
        # Never signal a reused PID or an unidentifiable live process.
        if [ -n "$started" ] && [ -n "$actual" ] && [ "$started" != "$actual" ]; then owner=""
        else
          cmdline=$(tr '\0' ' ' < "${PROC_ROOT:-/proc}/$owner/cmdline" 2>/dev/null || true)
          case "$cmdline" in
            *live-relay-auto-controller.sh*)
              kill -TERM "$owner" >/dev/null 2>&1 || true
              while kill -0 "$owner" >/dev/null 2>&1 && [ "$attempts" -lt 50 ]; do
                sleep 0.1; attempts=$(( attempts + 1 ))
              done
              if kill -0 "$owner" >/dev/null 2>&1; then
                err "旧控制器仍在退出，保留恢复记录；请稍后重试。"; return 1
              fi
              ;;
            *) err "控制器锁的进程身份无法确认，未修改配置。"; return 1 ;;
          esac
        fi
      fi
    fi
    command -v flock >/dev/null 2>&1 || { [ ! -d "$lock_dir" ] || return 1; return 0; }
    exec 7>"$WORKDIR/controller.flock" || return 1
    flock -n 7 || { err "控制器仍持有锁，未修改配置。"; return 1; }
    # The controller's flock now excludes a concurrent new owner.
    rm -rf "$lock_dir" || return 1
    rm -f "$WORKDIR/cpu-window.prev" "$WORKDIR/cpu-window.now" || return 1
  )
}

capture_runtime_at() {
  local SNAPSHOT_DIR="$1"
  capture_original_runtime "$2"
}

restore_runtime_at() {
  local SNAPSHOT_DIR="$1"
  restore_original_runtime
}

backup_installation_files() {
  local destination="$1" name path index=0
  mkdir -p "$destination/files" || return 1
  for name in SYSCTL_FILE SYSCTL_HELPER SYSCTL_SERVICE NIC_ENV_FILE NIC_HELPER NIC_SERVICE AUTO_ENV_FILE AUTO_HELPER AUTO_SERVICE DIAG_HELPER LIMITS_FILE SYSTEMD_LIMIT_FILE STATE_FILE AUTO_STATE_FILE SYSCTL_STATE_FILE; do
    path="${!name}"
    printf '%s\n' "$path" > "$destination/files/$index.path" || return 1
    if [ -e "$path" ] || [ -L "$path" ]; then
      cp -Pp "$path" "$destination/files/$index.original" || return 1
    else
      : > "$destination/files/$index.absent" || return 1
    fi
    index=$(( index + 1 ))
  done
  for name in best-parameters.env baseline-parameters.env pending-parameters.env pending-parameters.env.meta flow-limit.before flow-limit.owned; do
    path="$WORKDIR/$name"
    printf '%s\n' "$path" > "$destination/files/$index.path" || return 1
    if [ -f "$path" ]; then cp -p "$path" "$destination/files/$index.original" || return 1
    else : > "$destination/files/$index.absent" || return 1; fi
    index=$(( index + 1 ))
  done
}

restore_installation_files() {
  local destination="$1" record path temporary failed=0
  for record in "$destination"/files/*.path; do
    [ -f "$record" ] || continue
    IFS= read -r path < "$record" || { failed=1; continue; }
    if [ -f "${record%.path}.absent" ]; then
      rm -f "$path" || failed=1
    else
      mkdir -p "$(dirname "$path")" || { failed=1; continue; }
      temporary="$path.restore.$$"
      cp -Pp "${record%.path}.original" "$temporary" && mv -f "$temporary" "$path" || failed=1
    fi
  done
  return "$failed"
}

configuration_paths_safe() {
  local name path
  for name in SYSCTL_FILE SYSCTL_HELPER SYSCTL_SERVICE NIC_ENV_FILE NIC_HELPER NIC_SERVICE AUTO_ENV_FILE AUTO_HELPER AUTO_SERVICE DIAG_HELPER LIMITS_FILE SYSTEMD_LIMIT_FILE STATE_FILE AUTO_STATE_FILE SYSCTL_STATE_FILE; do
    path="${!name}"
    [ ! -L "$path" ] || { err "受管理路径是符号链接，保留原文件：$path"; return 1; }
  done
}

restore_installation_snapshot() {
  local destination="$1" stage previous
  [ -d "$destination/original-snapshot" ] || return 0
  stage=$(mktemp -d "$SNAPSHOT_DIR.restore.XXXXXX") || return 1
  cp -Rp "$destination/original-snapshot/." "$stage/" || { rm -rf "$stage"; return 1; }
  previous="$destination/failed-original-snapshot"
  if [ -e "$SNAPSHOT_DIR" ]; then mv "$SNAPSHOT_DIR" "$previous" || return 1; fi
  if ! mv "$stage" "$SNAPSHOT_DIR"; then
    [ ! -d "$previous" ] || mv "$previous" "$SNAPSHOT_DIR" || true
    return 1
  fi
}

rollback_configuration_transaction() {
  # Installation-local variables are dynamically scoped; this also runs from
  # the signal trap while the configuration lock remains held.
  local failed=0 i unit
  trap '' HUP INT TERM
  stop_auto_controller_for_reconfigure || {
    write_operation_result recovery_failed "$txn" "控制器未确认停止，暂未覆盖配置" || true
    err "控制器尚未停止，未并发覆盖配置；备份：$txn"; return 1;
  }
  if [ "$files_saved" = 1 ]; then
    if [ "$systemd_available" = 1 ]; then
      for ((i=0;i<${#units[@]};i++)); do
        unit="${units[$i]}"
        # Disable new links while their unit files still exist.
        if [ "${old_enabled[$i]}" = 0 ] && systemctl is-enabled --quiet "$unit" >/dev/null 2>&1; then
          systemctl disable "$unit" >/dev/null 2>&1 || failed=1
        fi
        if { [ "$unit" = live-relay-nic-tuning.service ] || { [ "$unit" != live-relay-auto-controller.service ] && [ "${old_active[$i]}" = 0 ]; }; } && systemctl is-active --quiet "$unit"; then
          systemctl stop "$unit" >/dev/null 2>&1 || failed=1
        fi
      done
    fi
    restore_installation_files "$txn" || failed=1
    restore_installation_snapshot "$txn" || failed=1
    if [ "$systemd_available" = 1 ] && [ "$failed" = 0 ]; then
      systemctl daemon-reload || failed=1
      for ((i=1;i<${#units[@]};i++)); do
        if [ "$failed" = 0 ] && [ "${old_active[$i]}" = 1 ] && ! systemctl is-active --quiet "${units[$i]}" >/dev/null 2>&1; then
          if [ "${units[$i]}" = live-relay-sysctl.service ]; then
            # Its ExecStart takes this same configuration lock. Do not replay
            # a profile over the exact kernel-state restoration below.
            failed=1
          else systemctl start "${units[$i]}" >/dev/null 2>&1 || failed=1; fi
        fi
      done
    fi
    # Old oneshot ExecStart may replay saved configuration; restore the exact
    # immediate kernel/NIC state after those units have settled.
    if [ -r "$SYSCTL_TRANSACTION_JOURNAL" ]; then restore_sysctl_values "$SYSCTL_TRANSACTION_JOURNAL" || failed=1; fi
    if [ -f "$txn/runtime-old/runtime.env" ]; then restore_runtime_at "$txn/runtime-old" || failed=1; fi
    if [ -f "$txn/runtime/runtime.env" ]; then restore_runtime_at "$txn/runtime" || failed=1; fi
  fi
  if [ "$systemd_available" = 1 ]; then
    for ((i=0;i<${#units[@]};i++)); do
      if [ "${old_enabled[$i]}" = 1 ]; then systemctl enable "${units[$i]}" >/dev/null 2>&1 || failed=1; fi
    done
    # A controller must never resume on a partially recovered configuration.
    if [ "${old_active[0]}" = 1 ] && [ "$failed" = 0 ]; then
      systemctl start live-relay-auto-controller.service >/dev/null 2>&1 || failed=1
    fi
  fi
  if [ "$failed" = 0 ]; then
    write_operation_result failed_restored "$txn" "操作未完成，已恢复操作前配置" || warn "无法更新操作状态。"
    warn "已恢复操作前配置，诊断记录保留在 $txn。"
  else
    write_operation_result recovery_failed "$txn" "部分恢复尚未确认" || true
    err "有恢复项尚未确认，控制器保持停止；完整备份保留在 $txn。"
  fi
  return "$failed"
}

install_auto_tuning() {
  (
    local operation="${1:-auto}" mode="${2:-2}" nic txn old_nic="" files_saved=0 systemd_available=0 i
    local SYSCTL_TRANSACTION_JOURNAL DEFER_HIA_REMOVAL=1 CONFIGURATION_TRANSACTION_ACTIVE=1
    local -a units=(live-relay-auto-controller.service live-relay-nic-tuning.service live-relay-sysctl.service)
    local -a old_active=(0 0 0) old_enabled=(0 0 0)
    case "$operation" in auto|profile|redetect|calibrate) ;; *) return 1 ;; esac
    if [ "$operation" = calibrate ]; then [ -x "$AUTO_HELPER" ] || { err "自动控制器尚未安装。"; return 1; }; fi
    ensure_base_dirs || return 1
    configuration_paths_safe || return 1
    [ ! -e "$WORKDIR/sysctl-boot-pending" ] || { err "存在未完成的开机 sysctl 恢复记录，请先运行 $SYSCTL_HELPER 完成恢复。"; return 1; }
    ensure_cmd flock || return 1
    command -v flock >/dev/null 2>&1 || { err "缺少 flock，未开始配置。请安装 util-linux。"; return 1; }
    exec 8>"$WORKDIR/configuration.lock" || return 1
    flock -n 8 || { warn "另一项配置操作正在进行。"; return 1; }
    ensure_cmd ethtool || return 1
    ensure_cmd ip || return 1
    ensure_cmd tc || return 1
    ensure_cmd lscpu || true
    nic=$(select_nic_noninteractive || true)
    if [ "$operation" = calibrate ] && [ -r "$AUTO_ENV_FILE" ]; then
      nic=$(bash -c 'source "$1" && printf "%s" "${DEV:-}"' _ "$AUTO_ENV_FILE") || return 1
    fi
    [ -n "$nic" ] || { err "未检测到可用网卡。"; return 1; }
    if command -v systemctl >/dev/null 2>&1 && systemctl show-environment >/dev/null 2>&1; then
      systemd_available=1
      for ((i=0;i<${#units[@]};i++)); do
        if systemctl is-active --quiet "${units[$i]}" >/dev/null 2>&1; then old_active[$i]=1; fi
        if systemctl is-enabled --quiet "${units[$i]}" >/dev/null 2>&1; then old_enabled[$i]=1; fi
      done
    fi
    txn=$(mktemp -d "$WORKDIR/install-transaction.XXXXXX") || return 1
    chmod 0700 "$txn" || return 1
    SYSCTL_TRANSACTION_JOURNAL="$txn/sysctl.before"
    # Publish the real path before any fallible snapshot step. Even an empty
    # journal exists, and diagnostics distinguish it from a completed capture.
    : > "$SYSCTL_TRANSACTION_JOURNAL" || { err "无法创建恢复记录：$SYSCTL_TRANSACTION_JOURNAL"; return 1; }
    printf 'PREPARE phase=not-started journal=%s\n' "$SYSCTL_TRANSACTION_JOURNAL" > "$SYSCTL_TRANSACTION_JOURNAL.log" || return 1
    write_operation_result started "$txn" "正在准备配置" || return 1
    info "正在保存操作前状态并停止旧控制器..."
    trap 'rollback_configuration_transaction || true; exit 130' HUP INT TERM
    if ! stop_auto_controller_for_reconfigure; then
      trap - HUP INT TERM
      [ "${old_active[0]}" != 1 ] || systemctl start live-relay-auto-controller.service >/dev/null 2>&1 || true
      write_operation_result failed_restored "$txn" "未能确认旧控制器停止，未开始修改配置" || true
      return 1
    fi
    if ! backup_installation_files "$txn"; then
      err "无法备份配置，未开始调优。"
      rollback_configuration_transaction || true
      return 1
    fi
    cp -Rp "$SNAPSHOT_DIR" "$txn/original-snapshot" || { rollback_configuration_transaction || true; return 1; }
    files_saved=1
    if ! is_container; then
      if ! capture_runtime_at "$txn/runtime" "$nic"; then
        err "无法保存网卡状态，未开始调优。"
        rollback_configuration_transaction || true
        return 1
      fi
      if [ -f "$SNAPSHOT_DIR/runtime.env" ]; then
        old_nic=$(bash -c 'source "$1" && printf "%s" "${ORIGINAL_NIC:-}"' _ "$SNAPSHOT_DIR/runtime.env") || { rollback_configuration_transaction || true; return 1; }
        if [ -n "$old_nic" ] && [ "$old_nic" != "$nic" ]; then
          capture_runtime_at "$txn/runtime-old" "$old_nic" || { rollback_configuration_transaction || true; return 1; }
        fi
      fi
    fi
    local result=0
    if [ "$operation" != calibrate ] && ! is_container; then
      if [ -n "$old_nic" ] && [ "$old_nic" != "$nic" ]; then
        if [ -e "$WORKDIR/pending-parameters.env" ]; then
          err "存在未完成的旧网卡试调恢复记录，暂不切换网卡。"; result=1
        else
          restore_original_runtime || result=1
          if [ "$result" = 0 ]; then
            rm -rf "$SNAPSHOT_DIR" || result=1
            rm -f "$WORKDIR/best-parameters.env" "$WORKDIR/baseline-parameters.env" || result=1
          fi
        fi
      fi
      if [ "$result" = 0 ]; then capture_original_runtime "$nic" || result=1; fi
    fi
    if [ "$result" = 0 ]; then
    case "$operation" in
      auto) install_auto_tuning_impl "$nic" || result=$? ;;
      profile) apply_profile_impl "$mode" || result=$? ;;
      redetect) redetect_environment_impl "$nic" "$old_nic" || result=$? ;;
      calibrate) NTC_CONFIG_LOCK_HELD=1 "$AUTO_HELPER" calibrate || result=$? ;;
    esac
    fi
    if [ "$result" = 0 ] && [ "$operation" != auto ] && [ "$systemd_available" = 1 ] && [ "${old_active[0]}" = 1 ]; then
      systemctl start live-relay-auto-controller.service >/dev/null 2>&1 || result=1
    fi
    if [ "$result" != 0 ]; then
      err "操作未完整通过，正在恢复操作前配置。"
      rollback_configuration_transaction || true
      return 1
    fi
    write_operation_result applied "$txn" "配置操作已完成" || warn "配置已完成，状态记录更新失败。"
    trap - HUP INT TERM
    case "$operation" in auto|profile) remove_hia_baseline || warn "旧 HIA 文件未能全部清除，请检查权限。" ;; esac
    rm -rf "$txn" || warn "调优已完成，临时备份清理失败：$txn"
    case "$operation" in
      auto) log "全自动调优已启动。" ;;
      redetect) log "已重新检测：$(detect_data_plane) / $nic" ;;
      calibrate) log "立即校准已完成。" ;;
    esac
  )
}

install_auto_tuning_impl() {
  local nic="$1"
  if ! is_container; then
    capture_original_runtime "$nic" || return 1
    apply_performance_power_policy || return 1
  fi
  apply_profile 2 || return 1
  write_auto_env "$nic" || return 1
  build_diagnostics_helper || return 1
  build_auto_controller || return 1
  build_auto_service || return 1
  # Do not implicitly resume a deliberately paused installation.
  NTC_CONFIG_LOCK_HELD=1 "$AUTO_HELPER" calibrate || return 1
  persist_state auto "$nic" || return 1
  if command -v systemctl >/dev/null 2>&1 && systemctl show-environment >/dev/null 2>&1; then
    systemctl daemon-reload || return 1
    systemctl enable --now live-relay-auto-controller.service >/dev/null 2>&1 || return 1
  else
    warn "systemd 不可用，已应用配置；自动控制器不会常驻。"
  fi
}

apply_profile() {
  if [ "${CONFIGURATION_TRANSACTION_ACTIVE:-0}" = 1 ]; then
    apply_profile_impl "$@"
  else
    install_auto_tuning profile "${1:-2}"
  fi
}

apply_profile_impl() {
  local mode="$1" cc nic
  case "$mode" in 2) ;; *) err "未知模式：$mode"; return 1 ;; esac
  cc=$(pick_cc_algo) || return 1
  log "选择拥塞控制算法：$cc"
  write_limits || return 1
  write_profile_2 "$cc" || return 1
  apply_sysctl_file || return 1
  enable_sysctl_persistence || return 1
  if is_container; then
    warn "检测到容器环境，仅应用可用 sysctl / limits，跳过 NIC / IRQ / RPS / XPS / qdisc 调优。"
    nic=""
  else
    nic=$(select_nic_noninteractive || true)
    if [ -n "$nic" ]; then
      log "使用网卡：$nic"
      setup_mode2_persistence "$nic" || return 1
    else
      warn "无法检测网卡，跳过网卡调优。可通过 NIC=eth0 指定。"
    fi
  fi
  persist_state 2 "${nic:-}" || return 1
  if [ "${DEFER_HIA_REMOVAL:-0}" != 1 ]; then remove_hia_baseline || return 1; fi
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
  printf '%-22s %s\n' "tcp_tw_reuse:" "$(sysctl -n net.ipv4.tcp_tw_reuse 2>/dev/null || echo n/a)"
  printf '%-22s %s\n' "tcp_max_tw_buckets:" "$(sysctl -n net.ipv4.tcp_max_tw_buckets 2>/dev/null || echo n/a)"
  printf '%-22s %s\n' "tcp_fastopen:" "$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo n/a)"
  printf '%-22s %s\n' "conntrack_count:" "$(sysctl -n net.netfilter.nf_conntrack_count 2>/dev/null || echo n/a)"
  printf '%-22s %s\n' "conntrack_max:" "$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo n/a)"
  printf '%-22s %s\n' "CPU策略:" "$worker_target"
  printf '%-22s %s\n' "队列策略:" "$target_queues"
  printf '%-22s %s\n' "使用HT:" "$use_ht"
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
  local service_status pause_status="未运行" reason="未采集" nic="$(default_nic)" data_plane
  service_status=$(tuner_status_label)
  data_plane=$(data_plane_label "$(detect_data_plane)")
  local METRICS_VALID=0 DETAIL_VALID=0 DRIVER_VALID=0 QDISC_VALID=0 SAMPLE_SECONDS=1
  local RX_PPS=0 TX_PPS=0 RX_BPS=0 TX_BPS=0 SOFTIRQ_PCT=0 HARDIRQ_PCT=0 STEAL_PCT=0
  local DROP_DELTA=0 SQUEEZE_DELTA=0 DRIVER_DROP_RATE=0 UDP_RCVBUF_DELTA=0 UDP_SNDBUF_DELTA=0
  local TCP_RETRANS_DELTA=0 TCP_RETRANS_BP=0 LISTEN_DROP_RATE=0 QDISC_DROP_RATE=0 QDISC_BACKLOG_BYTES=0
  local QDISC_POLICY=unknown QDISC_AQM_DROP_RATE=0 ACTIVE_BACKLOG=0 ACTIVE_BUDGET=0 ACTIVE_BUDGET_USECS=0 ACTIVE_WEIGHT=0 ACTIVE_COALESCE=0
  local ACTIVE_ADAPTIVE_RX=unknown TRIAL_STATUS=baseline TRIAL_GROUP=none VERIFICATION_SCOPE=unverified
  local REASON=unknown MACHINE=unknown UPDATED_AT=unknown COOLDOWN_REMAINING=0
  if [ -r "$AUTO_ENV_FILE" ]; then source "$AUTO_ENV_FILE" || true; nic="${DEV:-$nic}"; fi
  if [ -r "$AUTO_STATE_FILE" ]; then source "$AUTO_STATE_FILE" || true; reason="$REASON"; fi
  case "$service_status" in 运行中*) pause_status="正在观察" ;; 已暂停*) pause_status="已暂停" ;; esac
  case "$reason" in
    calibrated) reason="配置已校准，等待业务观察" ;;
    controller_started) reason="控制器启动" ;;
    learning_baseline) reason="正在学习负载基线" ;;
    pressure_detected) reason="检测到本机接收处理压力" ;;
    trial_started) reason="单组参数试调，正在验证" ;;
    trial_local_improved) reason="本机指标改善，已保留参数" ;;
    trial_no_improvement) reason="收益不足，已恢复原参数" ;;
    trial_latency_regression|trial_queue_regression|trial_throughput_regression|trial_error_regression) reason="检测到指标恶化，已恢复原参数" ;;
    trial_load_changed|trial_packet_mix_changed|trial_connections_changed) reason="业务负载变化，撤销本轮试调" ;;
    trial_latency_unobserved) reason="缺少新的可比 RTT，撤销本轮试调" ;;
    trial_invalid_sample|trial_interrupted|trial_recovered|trial_paused) reason="试调中断或样本失效，恢复原参数" ;;
    cooldown_hold) reason="观察已选参数，暂不重复调参" ;;
    host_steal_pressure) reason="宿主机 CPU 争抢，暂停试调" ;;
    application_socket_pressure) reason="应用缓冲或监听队列压力，查看应用诊断" ;;
    nic_receive_pressure) reason="网卡接收压力，查看驱动与队列" ;;
    egress_queue_pressure) reason="出口排队或丢包，需要核对瓶颈带宽" ;;
    retransmission_observed) reason="观察到 TCP 重传，来源尚未确定" ;;
    bounded_hold|actuator_unsupported) reason="达到参数边界或不支持该项调整" ;;
    metrics_unavailable) reason="指标不可用，暂停试调" ;;
    counter_reset) reason="计数器重置，重新学习基线" ;;
    actuator_rollback) reason="参数写入失败，已尝试事务恢复" ;;
    rollback_failed) reason="恢复尚未确认，已保留恢复记录" ;;
    user_paused) reason="用户暂停" ;;
    steady) reason="运行观察中" ;;
  esac
  echo
  echo "============== 自适应调优状态 =============="
  printf '%-24s %s / %s\n' "控制器:" "$service_status" "$pause_status"
  printf '%-24s %s\n' "数据面:" "$data_plane"
  show_installation_diagnostics
  printf '%-24s %s\n' "网卡:" "${nic:-unknown}"
  printf '%-24s %s\n' "资源模型:" "$MACHINE"
  printf '%-24s %s\n' "当前动作:" "$reason"
  printf '%-24s %ss / %s / %s\n' "采样/轻量有效/详细有效:" "$SAMPLE_SECONDS" "$METRICS_VALID" "$DETAIL_VALID"
  printf '%-24s %s / %s\n' "RX/TX PPS:" "$RX_PPS" "$TX_PPS"
  printf '%-24s %s / %s\n' "RX/TX bps:" "$RX_BPS" "$TX_BPS"
  printf '%-24s %s%% / %s%% / %s%%\n' "最忙核软中断/IRQ/Steal:" "$SOFTIRQ_PCT" "$HARDIRQ_PCT" "$STEAL_PCT"
  printf '%-24s %s / %s\n' "softnet丢包/预算耗尽增量:" "$DROP_DELTA" "$SQUEEZE_DELTA"
  printf '%-24s %s / %s\n' "驱动压力事件每秒/有效:" "$DRIVER_DROP_RATE" "$DRIVER_VALID"
  printf '%-24s %s / %s\n' "双栈UDP收/发缓冲错误:" "$UDP_RCVBUF_DELTA" "$UDP_SNDBUF_DELTA"
  printf '%-24s %s / %s bp\n' "TCP重传段/计数比:" "$TCP_RETRANS_DELTA" "$TCP_RETRANS_BP"
  printf '%-24s %s / %s\n' "监听/qdisc事件每秒:" "$LISTEN_DROP_RATE" "$QDISC_DROP_RATE"
  printf '%-24s %s bytes / %s / %s\n' "出口积压/策略/有效:" "$QDISC_BACKLOG_BYTES" "$QDISC_POLICY" "$QDISC_VALID"
  printf '%-24s %s\n' "已有AQM策略drop每秒:" "$QDISC_AQM_DROP_RATE"
  printf '%-24s %s / %s / %sus / %s\n' "backlog/budget/usecs/weight:" "$ACTIVE_BACKLOG" "$ACTIVE_BUDGET" "$ACTIVE_BUDGET_USECS" "$ACTIVE_WEIGHT"
  printf '%-24s %sus / %s\n' "RX合并/adaptive:" "$ACTIVE_COALESCE" "$ACTIVE_ADAPTIVE_RX"
  printf '%-24s %s / %s / %ss\n' "试调状态/参数组/冷却:" "$TRIAL_STATUS" "$TRIAL_GROUP" "$COOLDOWN_REMAINING"
  printf '%-24s %s（未代替对端丢包与播放延迟验收）\n' "验证范围:" "$VERIFICATION_SCOPE"
  printf '%-24s %s\n' "更新时间:" "$UPDATED_AT"
  if [ -r "$WORKDIR/diagnostics.env" ]; then
    source "$WORKDIR/diagnostics.env" || true
    printf '%-24s %s\n' "代理诊断:" "${DIAG_PROXY_STATUS:-unknown} / ${DIAG_PROXY_NETNS_STATUS:-unknown}"
    printf '%-24s %s\n' "识别到的代理:" "${DIAG_PROXY_PROCESSES:-unknown}"
    printf '%-24s %s\n' "代理线程热点:" "${DIAG_THREAD_TOP:-unknown}"
    printf '%-24s %s / %s\n' "代理TCP/UDP抽样socket:" "${DIAG_PROXY_SOCKET_COUNT:-unknown}" "${DIAG_PROXY_UDP_SOCKET_COUNT:-unknown}"
    printf '%-24s %s bytes / %s\n' "UDP抽样缓冲/累计drop:" "${DIAG_PROXY_UDP_RCVBUF_ALLOC:-unknown}" "${DIAG_PROXY_UDP_SOCKET_DROPS:-unknown}"
    printf '%-24s %s KiB / %s pages\n' "可用内存/UDP池占用:" "${DIAG_MEM_AVAILABLE_KB:-unknown}" "${DIAG_UDP_MEM_PAGES:-unknown}"
    printf '%-24s %s / %s\n' "conntrack使用/上限:" "${DIAG_CONNTRACK_COUNT:-unknown}" "${DIAG_CONNTRACK_MAX:-unknown}"
    printf '%-24s %s / %s\n' "网卡/显式路由MTU:" "${DIAG_LINK_MTU:-unknown}" "${DIAG_ROUTE_MTU:-unknown}"
    printf '%-24s %s\n' "UDP批处理/GSO能力:" "${DIAG_APP_BATCH_STATUS:-unknown}"
    printf '%-24s %s\n' "代理pacing能力:" "${DIAG_APP_PACING_STATUS:-unknown}"
    printf '%-24s %s\n' "协议FEC能力:" "${DIAG_APP_FEC_STATUS:-unknown}"
  fi
  echo "================================================"
  echo
}

redetect_environment() {
  install_auto_tuning redetect
}

redetect_environment_impl() {
  local nic="$1" old_nic="$2"
  if ! is_container; then setup_mode2_persistence "$nic" || return 1; fi
  write_auto_env "$nic" || return 1
  build_diagnostics_helper || return 1
  build_auto_controller || return 1
  build_auto_service || return 1
  if command -v systemctl >/dev/null 2>&1 && systemctl show-environment >/dev/null 2>&1; then systemctl daemon-reload || return 1; fi
  NTC_CONFIG_LOCK_HELD=1 "$AUTO_HELPER" calibrate || return 1
  persist_state auto "$nic" || return 1
}

calibrate_now() {
  install_auto_tuning calibrate
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

confirm_cleanup() {
  local confirm
  read -r -p "确认卸载并回退 HIA？[y/N] " confirm
  case "$confirm" in
    y|Y)
      cleanup_live_relay
      ;;
    *)
      warn "已取消卸载。"
      return 1
      ;;
  esac
}

wait_for_main_menu() {
  local ignored
  read -r -p "按回车返回主菜单..." ignored || true
}

show_menu() {
  local status data_plane pause_label="暂停调优"
  status=$(tuner_status_label)
  data_plane=$(data_plane_label "$(detect_data_plane)")
  [ ! -e "$PAUSE_FILE" ] || pause_label="继续调优"
  clear || true
  cat <<EOF_MENU
========================================================
 Live Relay 高级自适应调优
========================================================
 状态：$status | 数据面：$data_plane
--------------------------------------------------------
 1) 自动调优
 2) 运行状态
 3) $pause_label
 4) 卸载并回退 HIA
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
    detect)
      redetect_environment
      return 0
      ;;
    calibrate)
      calibrate_now
      return 0
      ;;
    3|5|pause|resume|toggle)
      toggle_auto_tuning
      return 0
      ;;
    diag|diagnostics)
      show_diagnostics
      return 0
      ;;
    4|7|cleanup|remove|hia)
      confirm_cleanup
      return $?
      ;;
    hyper) apply_profile 2; return 0 ;;
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
        install_auto_tuning || true
        wait_for_main_menu
        ;;
      2)
        show_auto_status || true
        wait_for_main_menu
        ;;
      3)
        toggle_auto_tuning || true
        wait_for_main_menu
        ;;
      4)
        confirm_cleanup || true
        wait_for_main_menu
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
