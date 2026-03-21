#!/usr/bin/env bash
set -euo pipefail

VERSION="1.2.0-srt-proxy-ultimate"
WORKDIR="/opt/live-relay-srt-smart"
SRC_DIR="/usr/local/src"
ENV_FILE="/etc/live-relay-srt-smart.env"
SERVICE_NAME="live-relay-srt-smart.service"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}"
RUN_HELPER="/usr/local/sbin/live-relay-srt-smart-run.sh"
STATE_FILE="${WORKDIR}/state.env"
LOG_FILE="${WORKDIR}/srt-proxy.log"
PID_FILE="${WORKDIR}/srt-proxy.pid"

SRT_VERSION="${SRT_VERSION:-1.5.3}"
LOCAL_UDP_HOST="${LOCAL_UDP_HOST:-127.0.0.1}"
LOCAL_UDP_PORT="${LOCAL_UDP_PORT:-10000}"
PROXY_SRT_HOST="${PROXY_SRT_HOST:-0.0.0.0}"
PROXY_SRT_PORT="${PROXY_SRT_PORT:-10001}"
LATENCY_MS="${LATENCY_MS:-auto}"

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
  mkdir -p "$WORKDIR" "$SRC_DIR"
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
      DEBIAN_FRONTEND=noninteractive apt-get update -y
      DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
      ;;
    dnf) dnf install -y "$@" ;;
    yum) yum install -y "$@" ;;
    zypper) zypper --non-interactive install "$@" ;;
    pacman) pacman -Sy --noconfirm "$@" ;;
    *) return 1 ;;
  esac
}

mem_total_gb() {
  awk '/MemTotal:/ {printf "%d\n", int(($2 + 1048575) / 1048576)}' /proc/meminfo
}

cpu_count() {
  nproc 2>/dev/null || echo 1
}

detect_env_type() {
  if grep -qaE 'docker|lxc|container|kubepods' /proc/1/cgroup 2>/dev/null || \
     grep -qaE 'container=' /proc/1/environ 2>/dev/null; then
    echo container
    return 0
  fi

  if command -v systemd-detect-virt >/dev/null 2>&1; then
    local v
    v="$(systemd-detect-virt 2>/dev/null || true)"
    case "$v" in
      none|'') echo baremetal ;;
      docker|lxc|podman|container-other) echo container ;;
      kvm|qemu|vmware|microsoft|oracle|xen|bochs|uml|parallels) echo vm ;;
      *) echo "$v" ;;
    esac
    return 0
  fi

  echo unknown
}

has_systemd() {
  command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

smart_build_jobs() {
  local mem cpu
  mem="$(mem_total_gb)"
  cpu="$(cpu_count)"

  # 智能编译并发控制，防 VPS 爆内存 (OOM)
  if [ "$mem" -le 1 ]; then
    echo 1
  elif [ "$mem" -le 2 ] && [ "$cpu" -gt 2 ]; then
    echo 2
  elif [ "$cpu" -le 1 ]; then
    echo 1
  elif [ "$cpu" -le 2 ]; then
    echo "$cpu"
  else
    echo "$cpu"
  fi
}

normalize_config() {
  if [ "${LOCAL_UDP_HOST}" = "127.0.0.0" ]; then
    warn "检测到 LOCAL_UDP_HOST=127.0.0.0，已自动修正为 127.0.0.1"
    LOCAL_UDP_HOST="127.0.0.1"
  fi

  # 剥离原版基于内存猜测网络延迟的谬误逻辑，回归物理本质
  if [ "$LATENCY_MS" = "auto" ] || [ -z "$LATENCY_MS" ]; then
    warn "未指定公网物理延迟 (LATENCY_MS)，默认锁定为安全基线 200 ms。"
    LATENCY_MS=200
  fi
}

validate_number() {
  local name="$1" value="$2"
  case "$value" in
    ''|*[!0-9]*)
      err "$name 必须是纯数字，当前值：$value"
      exit 1
      ;;
  esac
}

validate_config() {
  validate_number "LOCAL_UDP_PORT" "$LOCAL_UDP_PORT"
  validate_number "PROXY_SRT_PORT" "$PROXY_SRT_PORT"
  validate_number "LATENCY_MS" "$LATENCY_MS"

  if [ "$LOCAL_UDP_PORT" -lt 1 ] || [ "$LOCAL_UDP_PORT" -gt 65535 ]; then
    err "LOCAL_UDP_PORT 超出范围：$LOCAL_UDP_PORT"
    exit 1
  fi
  if [ "$PROXY_SRT_PORT" -lt 1 ] || [ "$PROXY_SRT_PORT" -gt 65535 ]; then
    err "PROXY_SRT_PORT 超出范围：$PROXY_SRT_PORT"
    exit 1
  fi

  if [ "$LATENCY_MS" -lt 20 ]; then
    warn "LATENCY_MS=$LATENCY_MS 较低，跨国/丢包环境下可能导致 ARQ 重传失效。"
  elif [ "$LATENCY_MS" -gt 800 ]; then
    warn "LATENCY_MS=$LATENCY_MS 较高，虽极抗丢包但时延会明显增加。"
  fi

  if [ "$LOCAL_UDP_HOST" = "0.0.0.0" ]; then
    warn "LOCAL_UDP_HOST=0.0.0.0 通常不适合作为 UDP 发送目标，建议改为 127.0.0.1 或内网互联地址。"
  fi
}

ensure_runtime_tools() {
  local pm
  pm="$(detect_pm)"

  if command -v ss >/dev/null 2>&1; then
    return 0
  fi

  case "$pm" in
    apt) install_packages "$pm" iproute2 ;;
    dnf|yum) install_packages "$pm" iproute ;;
    pacman) install_packages "$pm" iproute2 ;;
    zypper) install_packages "$pm" iproute2 ;;
    *) true ;;
  esac
}

ensure_build_deps() {
  local pm
  pm="$(detect_pm)"

  case "$pm" in
    apt)
      install_packages "$pm" ca-certificates wget curl tar pkg-config cmake make gcc g++ libssl-dev tcl
      ;;
    dnf)
      install_packages "$pm" ca-certificates wget curl tar pkgconf-pkg-config cmake make gcc gcc-c++ openssl-devel tcl
      ;;
    yum)
      install_packages "$pm" epel-release || true
      install_packages "$pm" ca-certificates wget curl tar pkgconfig cmake make gcc gcc-c++ openssl-devel tcl
      ;;
    zypper)
      install_packages "$pm" ca-certificates wget curl tar pkg-config cmake make gcc gcc-c++ libopenssl-devel tcl
      ;;
    pacman)
      install_packages "$pm" ca-certificates wget curl tar pkgconf cmake make gcc openssl tcl
      ;;
    *)
      err "未找到受支持的包管理器，请手动安装 SRT 依赖。"
      exit 1
      ;;
  esac
}

download_srt_source() {
  local tarball url
  tarball="${SRC_DIR}/srt-${SRT_VERSION}.tar.gz"
  url="https://github.com/Haivision/srt/archive/refs/tags/v${SRT_VERSION}.tar.gz"

  info "下载 SRT v${SRT_VERSION} 源码..."
  rm -rf "${SRC_DIR}/srt-${SRT_VERSION}" "${SRC_DIR}/srt-${SRT_VERSION}/build" 2>/dev/null || true

  if command -v wget >/dev/null 2>&1; then
    wget -O "$tarball" "$url"
  elif command -v curl >/dev/null 2>&1; then
    curl -L "$url" -o "$tarball"
  else
    err "既没有 wget 也没有 curl，无法下载源码。"
    exit 1
  fi

  tar -xzf "$tarball" -C "$SRC_DIR"
}

build_install_srt_from_source() {
  local jobs
  jobs="$(smart_build_jobs)"

  ensure_build_deps
  download_srt_source

  info "强制编译安装 SRT v${SRT_VERSION}，规避包管理器旧版本 Bug..."
  info "当前编译并发: -j${jobs}"

  cd "${SRC_DIR}/srt-${SRT_VERSION}"
  cmake -S . -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DENABLE_APPS=ON \
    -DENABLE_SHARED=ON

  cmake --build build -j"${jobs}"
  cmake --install build
  ldconfig

  if ! command -v srt-live-transmit >/dev/null 2>&1; then
    err "源码安装完成后仍未找到 srt-live-transmit。"
    exit 1
  fi
}

ensure_srt_installed() {
  if command -v srt-live-transmit >/dev/null 2>&1; then
    # 简单的版本号判断，如果低于 1.5，建议重编，但这里为了鲁棒性只做基础检测
    log "检测到 srt-live-transmit 已安装，跳过源码编译。"
    return 0
  fi
  build_install_srt_from_source
}

find_srt_bin() {
  local bin
  bin="$(command -v srt-live-transmit || true)"
  if [ -z "$bin" ]; then
    for p in /usr/local/bin/srt-live-transmit /usr/bin/srt-live-transmit; do
      [ -x "$p" ] && bin="$p" && break
    done
  fi

  [ -n "$bin" ] || { err "未找到 srt-live-transmit。"; exit 1; }
  echo "$bin"
}

write_env_file() {
  cat > "$ENV_FILE" <<EOF
SRT_BIN=$(find_srt_bin)
LOCAL_UDP_HOST=${LOCAL_UDP_HOST}
LOCAL_UDP_PORT=${LOCAL_UDP_PORT}
PROXY_SRT_HOST=${PROXY_SRT_HOST}
PROXY_SRT_PORT=${PROXY_SRT_PORT}
LATENCY_MS=${LATENCY_MS}
EOF
}

build_run_helper() {
  cat > "$RUN_HELPER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="/etc/live-relay-srt-smart.env"
[ -f "$ENV_FILE" ] || { echo "缺少 $ENV_FILE"; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"

# 核心：即使退化为无 systemd 模式，依然强行注入 8MB 内核接收/发送缓冲窗
exec "$SRT_BIN" \
  "srt://${PROXY_SRT_HOST}:${PROXY_SRT_PORT}?mode=listener&latency=${LATENCY_MS}&rcvbuf=8388608&sndbuf=8388608" \
  "udp://${LOCAL_UDP_HOST}:${LOCAL_UDP_PORT}?sndbuf=8388608&rcvbuf=8388608"
EOF
  chmod +x "$RUN_HELPER"
}

build_service() {
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Live Relay Ultimate SRT to UDP Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${ENV_FILE}
ExecStart=/bin/bash -c 'exec "\$SRT_BIN" "srt://\${PROXY_SRT_HOST}:\${PROXY_SRT_PORT}?mode=listener&latency=\${LATENCY_MS}&rcvbuf=8388608&sndbuf=8388608" "udp://\${LOCAL_UDP_HOST}:\${LOCAL_UDP_PORT}?sndbuf=8388608&rcvbuf=8388608"'

Restart=always
RestartSec=3
StartLimitIntervalSec=0
LimitNOFILE=1048576

# 核心：实时调度 (Real-Time Scheduling) 防御 VPS 层面的 Steal Time 软抖动
CPUSchedulingPolicy=rr
CPUSchedulingPriority=89
IOSchedulingClass=realtime
IOSchedulingPriority=0

NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
}

persist_state() {
  cat > "$STATE_FILE" <<EOF
PROFILE=srt-proxy-ultimate
ENV_TYPE=$(detect_env_type)
SYSTEMD=$(has_systemd && echo yes || echo no)
UPDATED_AT=$(date +%F_%T)
EOF
}

port_in_use() {
  local port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltnup 2>/dev/null | awk '{print $5}' | grep -qE "[:.]${port}$"
    return $?
  fi
  return 1
}

udp_port_listener_exists() {
  local host="$1" port="$2"
  if command -v ss >/dev/null 2>&1; then
    ss -lunp 2>/dev/null | awk '{print $5}' | grep -qE "(${host}|0\.0\.0\.0|\*)[:.]${port}$"
    return $?
  fi
  return 1
}

deploy_with_systemd() {
  write_env_file
  build_run_helper
  build_service

  info "正在安装并启动 systemd 实时抢占服务..."
  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl restart "$SERVICE_NAME"

  if systemctl is-active --quiet "$SERVICE_NAME"; then
    log "SRT 代理服务已启动 (包含 RT 实时抢占及 8MB 缓冲优化)。"
  else
    err "systemd 服务启动失败。"
    echo "排查命令："
    echo "  systemctl status $SERVICE_NAME --no-pager -l"
    echo "  journalctl -u $SERVICE_NAME -n 100 --no-pager"
    exit 1
  fi
}

deploy_without_systemd() {
  write_env_file
  build_run_helper

  if [ -f "$PID_FILE" ]; then
    local oldpid
    oldpid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "${oldpid:-}" ] && kill -0 "$oldpid" 2>/dev/null; then
      info "停止旧的前台代理进程 PID=$oldpid ..."
      kill "$oldpid" >/dev/null 2>&1 || true
      sleep 1
    fi
  fi

  info "当前环境无 systemd，改用 nohup 后台运行模式..."
  nohup "$RUN_HELPER" >>"$LOG_FILE" 2>&1 &
  echo $! > "$PID_FILE"
  sleep 1

  if kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    log "SRT 代理已在后台启动 (降级为普通进程优先级)。"
  else
    err "后台运行模式启动失败，请检查日志：$LOG_FILE"
    exit 1
  fi
}

apply_proxy() {
  normalize_config
  validate_config
  ensure_runtime_tools

  if port_in_use "$PROXY_SRT_PORT"; then
    warn "检测到 SRT 监听端口 ${PROXY_SRT_PORT} 可能已被占用。"
  fi

  if udp_port_listener_exists "$LOCAL_UDP_HOST" "$LOCAL_UDP_PORT"; then
    log "检测到本地 UDP 端口 ${LOCAL_UDP_HOST}:${LOCAL_UDP_PORT} 已有监听程序。"
  else
    warn "未明显检测到本地 UDP 监听 ${LOCAL_UDP_HOST}:${LOCAL_UDP_PORT}，代理仍会部署，请确认下游业务已启动。"
  fi

  ensure_srt_installed

  if has_systemd; then
    deploy_with_systemd
  else
    deploy_without_systemd
  fi

  persist_state
  show_status
}

cleanup_proxy() {
  info "正在清理 SRT 终极代理配置..."

  if has_systemd; then
    systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi

  if [ -f "$PID_FILE" ]; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" >/dev/null 2>&1 || true
    fi
  fi

  rm -f "$ENV_FILE" "$RUN_HELPER" "$PID_FILE" "$STATE_FILE"

  log "代理配置已清理完成。"
  warn "已安装的 SRT 源码编译组件不会自动卸载，请保留以防重复编译耗时。"
}

show_status() {
  local env_type systemd_state mem cpu srt_bin run_mode enabled active pid=""

  env_type="$(detect_env_type)"
  systemd_state="$(has_systemd && echo yes || echo no)"
  mem="$(mem_total_gb)"
  cpu="$(cpu_count)"
  srt_bin="$(find_srt_bin 2>/dev/null || echo not-found)"
  run_mode="none"
  enabled="disabled"
  active="inactive"

  if has_systemd; then
    if systemctl cat "$SERVICE_NAME" >/dev/null 2>&1; then
      run_mode="systemd"
      enabled="$(systemctl is-enabled "$SERVICE_NAME" 2>/dev/null || echo disabled)"
      active="$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo inactive)"
    fi
  fi

  if [ -f "$PID_FILE" ]; then
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "${pid:-}" ] && kill -0 "$pid" 2>/dev/null; then
      run_mode="nohup"
      active="active"
    fi
  fi

  echo
  echo "================ 状态信息 ================"
  printf '%-22s %s\n' "当前配置:" "srt-proxy-ultimate"
  printf '%-22s %s\n' "脚本版本:" "$VERSION"
  printf '%-22s %s\n' "环境类型:" "$env_type"
  printf '%-22s %s\n' "systemd 可用:" "$systemd_state"
  printf '%-22s %s\n' "CPU 核数:" "$cpu"
  printf '%-22s %s\n' "内存大小:" "${mem} GiB"
  printf '%-22s %s\n' "SRT 目标版本:" "$SRT_VERSION"
  printf '%-22s %s\n' "SRT 可执行文件:" "$srt_bin"
  printf '%-22s %s\n' "代理运行方式:" "$run_mode"
  printf '%-22s %s\n' "是否启用:" "$enabled"
  printf '%-22s %s\n' "运行状态:" "$active"
  printf '%-22s %s\n' "底层缓冲透传:" "8388608 Bytes (8MB) - Enabled"
  printf '%-22s %s\n' "SRT 监听地址:" "${PROXY_SRT_HOST}:${PROXY_SRT_PORT}"
  printf '%-22s %s\n' "本地 UDP 目标:" "${LOCAL_UDP_HOST}:${LOCAL_UDP_PORT}"
  printf '%-22s %s\n' "重传延迟(LATENCY):" "${LATENCY_MS} ms"
  printf '%-22s %s\n' "环境文件:" "$ENV_FILE"
  printf '%-22s %s\n' "运行脚本:" "$RUN_HELPER"
  printf '%-22s %s\n' "日志文件:" "$LOG_FILE"

  if [ -n "${pid:-}" ]; then
    printf '%-22s %s\n' "nohup PID:" "$pid"
  fi

  if command -v ss >/dev/null 2>&1; then
    echo "端口监听:"
    ss -ltnup 2>/dev/null | grep -E "(:${PROXY_SRT_PORT}|:${LOCAL_UDP_PORT})" || echo "  未检测到相关监听"
  fi

  if has_systemd && systemctl cat "$SERVICE_NAME" >/dev/null 2>&1; then
    echo "systemd 服务:"
    systemctl status "$SERVICE_NAME" --no-pager -l || true
  fi

  if [ -f "$LOG_FILE" ]; then
    echo "最近日志:"
    tail -n 20 "$LOG_FILE" 2>/dev/null | sed 's/^/  /' || true
  fi

  echo "========================================="
  echo
}

show_menu() {
  clear || true
  cat <<'EOF_MENU'
=====================================================
 Live Relay 智能自适 SRT 代理工具
=====================================================
 1) 智能部署 / 启动 SRT -> UDP 代理
 2) 查看当前状态
 3) 清理代理配置
 0) 退出
=====================================================
EOF_MENU
}

usage() {
  cat <<EOF
用法:
  bash $0 apply
  bash $0 status
  bash $0 cleanup

可选环境变量:
  SRT_VERSION=1.5.3
  LOCAL_UDP_HOST=127.0.0.1
  LOCAL_UDP_PORT=10000
  PROXY_SRT_HOST=0.0.0.0
  PROXY_SRT_PORT=10001
  LATENCY_MS=200

示例:
  LOCAL_UDP_PORT=10000 PROXY_SRT_PORT=10001 LATENCY_MS=200 bash $0 apply
EOF
}

main() {
  need_root
  ensure_base_dirs

  local choice="${1:-}"
  case "$choice" in
    1|apply|deploy|install|start|smart|auto)
      apply_proxy
      return 0
      ;;
    2|status)
      show_status
      return 0
      ;;
    3|cleanup|remove|uninstall)
      cleanup_proxy
      return 0
      ;;
    -h|--help|help)
      usage
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
    read -r -p "请选择 [0-3]：" choice
    case "$choice" in
      1)
        apply_proxy
        break
        ;;
      2)
        show_status
        read -r -p "按回车键继续..." _tmp
        ;;
      3)
        cleanup_proxy
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
