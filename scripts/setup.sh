#!/bin/bash
# ============================================================
# New API 项目维护脚本
#
# 使用说明:
#   ./scripts/setup.sh              显示交互式菜单
#   ./scripts/setup.sh install      初始化项目、编译并启动服务
#   ./scripts/setup.sh uninstall    卸载服务、删除所有 install 产物
#   ./scripts/setup.sh rebuild      重新编译并重启服务
#   ./scripts/setup.sh pull         从上游同步更新到 main 分支
#   ./scripts/setup.sh push         推送 main 分支到 origin
#   ./scripts/setup.sh status       查看服务状态
#   ./scripts/setup.sh logs         查看服务日志
#
# 支持系统: Linux (systemd) / macOS (后台进程)
# 上游仓库: https://github.com/Calcium-Ion/new-api.git
# ============================================================
set -e

# ===== 配置变量 =====
SERVICE_NAME="new-api"
BRANCH_NAME="main"
UPSTREAM_URL="https://github.com/Calcium-Ion/new-api.git"
UPSTREAM_REMOTE="upstream"
PORT=3000
MODULE_PATH="github.com/QuantumNous/new-api"

# ===== 自动检测 =====
# 解析符号链接，确保通过 symlink 调用时也能正确定位项目目录
# 添加最大深度限制（10 层），防止循环链接导致无限循环
SCRIPT_PATH="$0"
_symlink_depth=0
while [ -L "$SCRIPT_PATH" ] && [ "$_symlink_depth" -lt 10 ]; do
    SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
    LINK_TARGET="$(readlink "$SCRIPT_PATH")"
    # 处理相对路径的符号链接
    case "$LINK_TARGET" in
        /*) SCRIPT_PATH="$LINK_TARGET" ;;
        *)  SCRIPT_PATH="$SCRIPT_DIR/$LINK_TARGET" ;;
    esac
    _symlink_depth=$((_symlink_depth + 1))
done
if [ "$_symlink_depth" -eq 10 ]; then
    echo "[ERROR] 符号链接嵌套过深（疑似循环链接），请检查 $0" >&2
    exit 1
fi
unset _symlink_depth
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BINARY_PATH="$PROJECT_DIR/$SERVICE_NAME"
OS_TYPE="$(uname -s | tr '[:upper:]' '[:lower:]')"
SYSTEMD_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
# Python 解释器（py_json_get 工具函数依赖此全局变量），优先使用 python3
PY="$(command -v python3 || command -v python || true)"

# ===== 颜色输出 =====
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # 无颜色

info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }
title()   { echo -e "\n${BLUE}===== $1 =====${NC}"; }

# root 时直接执行命令，否则通过 sudo 提权
_EUID="$(id -u)"
_sudo() { if [ "$_EUID" -eq 0 ]; then "$@"; else sudo "$@"; fi; }

# apt-get install，确保 update 只执行一次
_APT_UPDATED=0
_apt_install() {
    if [ "$_APT_UPDATED" -eq 0 ]; then
        _sudo apt-get update -qq
        _APT_UPDATED=1
    fi
    _sudo apt-get install -y "$@"
}

# ===== 工具函数 =====

# 读取 VERSION 文件，返回版本号字符串
# 如果文件不存在或为空，返回 "unknown"
get_version() {
    local version_file="$PROJECT_DIR/VERSION"
    if [ -f "$version_file" ]; then
        local ver
        ver="$(tr -d '[:space:]' < "$version_file")"
        if [ -n "$ver" ]; then
            echo "$ver"
            return
        fi
    fi
    echo "unknown"
}

# 通过点分隔路径从 JSON 字符串中提取字段值
# 参数: $1 = JSON 字符串
#       $2 = 点分隔字段路径（如 "data.id" 或 "success"）
# 输出: 字段值（bool 自动转为小写 true/false），路径不存在或解析失败时返回 1
# 依赖: 全局变量 PY（Python 解释器路径）
# 示例:
#   py_json_get "$resp" "success"     → "true"
#   py_json_get "$resp" "data.id"     → "123"
#   py_json_get "$resp" "data"        → "value"
py_json_get() {
    local _json="$1" _path="$2"
    if [ -z "$PY" ]; then return 1; fi
    # 注意：必须使用 -c 传递 Python 代码，而不能用 heredoc（<<）。
    # 管道（|）与 heredoc 同时存在时，heredoc 会覆盖管道的 stdin，
    # 导致 Python 收到的是代码文本而非 JSON，json.load() 必然失败。
    printf '%s' "$_json" | "$PY" -c "
import json, sys
try:
    node = json.load(sys.stdin)
    for key in sys.argv[1].split('.'):
        node = node[key] if isinstance(node, dict) else node[int(key)]
    print(str(node).lower() if isinstance(node, bool) else str(node))
except Exception:
    sys.exit(1)
" "$_path" 2>/dev/null
}

# 比较两个语义化版本号，判断 $1 >= $2
# 参数: $1 = 实际版本, $2 = 最低要求版本
# 返回: 0 表示满足, 1 表示不满足
version_gte() {
    # 去掉前缀 v/go 等非数字字符，空字符串默认为 "0"
    local actual="${1#go}"; actual="${actual#v}"; actual="${actual:-0}"
    local required="${2#go}"; required="${required#v}"; required="${required:-0}"

    # 逐段比较 major.minor.patch
    local IFS='.'
    local -a a=($actual) r=($required)
    local i
    for i in 0 1 2; do
        # 去掉非数字后缀（如 "1-rc1" → "1"），空段默认为 0
        local av="${a[$i]:-0}"; av="${av%%[!0-9]*}"; av="${av:-0}"
        local rv="${r[$i]:-0}"; rv="${rv%%[!0-9]*}"; rv="${rv:-0}"
        if [ "$av" -gt "$rv" ]; then
            return 0
        elif [ "$av" -lt "$rv" ]; then
            return 1
        fi
    done
    return 0
}

# 从 go.mod 中读取最低 Go 版本要求
get_required_go_version() {
    local gomod="$PROJECT_DIR/go.mod"
    if [ -f "$gomod" ]; then
        # 匹配 "go x.y.z" 行（忽略注释中的 goVersion）
        local ver
        ver="$(grep -E '^go [0-9]' "$gomod" | head -1 | awk '{print $2}')"
        if [ -n "$ver" ]; then
            echo "$ver"
            return
        fi
    fi
    echo "1.18"
}

# 确保 Homebrew 已安装（仅 macOS）
ensure_brew() {
    if command -v brew &>/dev/null; then
        return 0
    fi
    info "Homebrew 未安装，开始安装..."
    # 安全提示：以下命令从 Homebrew 官方仓库下载并执行安装脚本。
    # 请确认信任该来源（https://brew.sh）后再继续。
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # Apple Silicon 和 Intel Mac 的 brew 路径不同，需要初始化环境
    if [ -f "/opt/homebrew/bin/brew" ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [ -f "/usr/local/bin/brew" ]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
    if ! command -v brew &>/dev/null; then
        error "Homebrew 安装失败，请手动安装: https://brew.sh"
        exit 1
    fi
    info "Homebrew 安装完成"
}

# 安装单个依赖
# 参数: $1 = 命令名
# macOS 统一使用 brew，Linux 使用系统包管理器或官方脚本
install_cmd() {
    local cmd="$1"
    info "开始安装 $cmd..."

    if [ "$OS_TYPE" = "darwin" ]; then
        ensure_brew
        case "$cmd" in
            go)    brew install go ;;
            bun)   brew install oven-sh/bun/bun ;;
            git)   brew install git ;;
            redis) brew install redis ;;
        esac
    else
        case "$cmd" in
            git)
                if command -v apt-get &>/dev/null; then
                    _apt_install git
                elif command -v yum &>/dev/null; then
                    _sudo yum install -y git
                else
                    error "无法自动安装 git，请手动安装"
                    return 1
                fi
                ;;
            go)
                local go_ver arch
                go_ver="$(get_required_go_version)"
                arch="$(uname -m)"
                case "$arch" in
                    x86_64)  arch="amd64" ;;
                    aarch64) arch="arm64" ;;
                    *) error "不支持的 CPU 架构: $arch，请手动安装 Go"; return 1 ;;
                esac
                local url="https://go.dev/dl/go${go_ver}.linux-${arch}.tar.gz"
                # 用子 shell 隔离 trap，避免 trap - 清除父 shell 中已有的全局 trap
                (
                    tmp_tar="/tmp/go.$$.tar.gz"
                    trap "rm -f '${tmp_tar}'" EXIT INT TERM
                    info "下载 Go ${go_ver}: ${url}"
                    curl -fsSL "$url" -o "$tmp_tar"
                    _sudo rm -rf /usr/local/go
                    _sudo tar -C /usr/local -xzf "$tmp_tar"
                ) || return 1
                export PATH="/usr/local/go/bin:$PATH"
                ;;
            bun)
                # 安全提示：以下命令从 bun.sh 下载并执行安装脚本。
                # 请确认信任该来源（https://bun.sh）后再继续。
                # bun 官方安装脚本依赖 unzip，先确保其存在
                if ! command -v unzip &>/dev/null; then
                    info "安装 unzip（bun 安装脚本依赖）..."
                    if command -v apt-get &>/dev/null; then
                        _apt_install unzip
                    elif command -v yum &>/dev/null; then
                        _sudo yum install -y unzip
                    else
                        error "无法自动安装 unzip，请手动安装后重试"
                        return 1
                    fi
                fi
                curl -fsSL https://bun.sh/install | bash
                export BUN_INSTALL="$HOME/.bun"
                export PATH="$BUN_INSTALL/bin:$PATH"
                ;;
            redis)
                if command -v apt-get &>/dev/null; then
                    _apt_install redis-server
                elif command -v yum &>/dev/null; then
                    _sudo yum install -y redis
                else
                    error "无法自动安装 redis，请手动安装"
                    return 1
                fi
                ;;
        esac
    fi

    # 验证安装结果（redis 安装后二进制名为 redis-cli，而非 redis）
    local verify_cmd="$cmd"
    [ "$cmd" = "redis" ] && verify_cmd="redis-cli"
    if ! command -v "$verify_cmd" &>/dev/null; then
        error "$cmd 安装失败，请手动安装"
        return 1
    fi
    info "$cmd 安装完成: $(command -v "$verify_cmd")"
}

# 检查所有必要依赖，缺少时自动安装
check_dependencies() {
    title "检查依赖"
    local has_error=0
    local cmd

    for cmd in git go bun; do
        if command -v "$cmd" &>/dev/null; then
            info "$cmd: $(command -v "$cmd")"
        else
            warn "缺少依赖: $cmd"
            install_cmd "$cmd" || has_error=1
        fi
    done
    if [ "$has_error" -eq 1 ]; then
        error "部分依赖安装失败，请手动安装后重试"
        exit 1
    fi

    # --- 版本检查 ---
    title "检查版本"

    # Go 版本
    local go_version go_required
    go_version="$(go version | awk '{print $3}')"       # 例: go1.25.1
    go_required="$(get_required_go_version)"             # 例: 1.25.1
    if version_gte "$go_version" "$go_required"; then
        info "Go 版本: $go_version (要求 >= $go_required)"
    else
        error "Go 版本过低: $go_version (要求 >= $go_required)"
        has_error=1
    fi

    # Bun 版本（仅显示）
    local bun_version
    bun_version="$(bun --version 2>/dev/null || echo '未知')"
    info "Bun 版本: $bun_version"

    # Git 版本（仅显示）
    local git_version
    git_version="$(git --version | awk '{print $3}')"
    info "Git 版本: $git_version"

    if [ "$has_error" -eq 1 ]; then
        error "版本检查未通过，请升级后重试"
        exit 1
    fi
    info "所有依赖和版本检查通过"
}

# 检查端口是否可用
# 参数: $1 = 端口号
# 如果端口被自身服务占用（重新安装场景），视为正常
check_port() {
    title "检查端口"
    local port="${1:-$PORT}"

    # 获取占用端口的进程 PID（只取第一个）
    local listen_pid=""
    if command -v lsof &>/dev/null; then
        listen_pid="$(lsof -iTCP:"$port" -sTCP:LISTEN -P -n -t 2>/dev/null | head -1 || true)"
    elif command -v ss &>/dev/null; then
        # 使用 grep -oE + cut 替代 grep -P，兼容 busybox 环境
        listen_pid="$(ss -tlnp "sport = :$port" 2>/dev/null \
            | grep -oE 'pid=[0-9]+' | cut -d= -f2 | head -1 || true)"
    else
        warn "未找到 lsof 或 ss 命令，跳过端口检查（建议安装其中之一）"
        return 0
    fi

    # 端口未被占用
    if [ -z "$listen_pid" ]; then
        info "端口 $port 可用"
        return 0
    fi

    # 端口被占用，检查是否为自身服务进程
    # 使用 basename 处理部分系统 ps 返回完整路径的情况
    local listen_cmd
    listen_cmd="$(ps -p "$listen_pid" -o comm= 2>/dev/null || true)"
    [ -n "$listen_cmd" ] && listen_cmd="$(basename "$listen_cmd" 2>/dev/null || true)"
    if [ "$listen_cmd" = "$SERVICE_NAME" ]; then
        warn "端口 $port 被当前服务占用 (PID: $listen_pid)，重新安装将重启服务"
        return 0
    fi

    # 被其他进程占用
    warn "端口 $port 已被占用:"
    if command -v lsof &>/dev/null; then
        lsof -iTCP:"$port" -sTCP:LISTEN -P -n 2>/dev/null || true
    fi
    error "请释放端口 $port 或修改脚本顶部的 PORT 变量"
    exit 1
}

# 检查项目结构完整性
check_project_structure() {
    title "检查项目结构"
    local has_error=0

    # 必须是 git 仓库
    if git -C "$PROJECT_DIR" rev-parse --git-dir &>/dev/null; then
        info "Git 仓库: 正常"
    else
        error "$PROJECT_DIR 不是一个 Git 仓库"
        has_error=1
    fi

    # go.mod
    if [ -f "$PROJECT_DIR/go.mod" ]; then
        info "go.mod: 存在"
    else
        error "go.mod 不存在"
        has_error=1
    fi

    # web/ 目录
    if [ -d "$PROJECT_DIR/web" ]; then
        info "web/ 目录: 存在"
    else
        error "web/ 目录不存在，无法构建前端"
        has_error=1
    fi

    # web/package.json
    if [ -f "$PROJECT_DIR/web/package.json" ]; then
        info "web/package.json: 存在"
    else
        error "web/package.json 不存在"
        has_error=1
    fi

    # VERSION 文件（仅警告）
    local ver
    ver="$(get_version)"
    if [ "$ver" = "unknown" ]; then
        warn "VERSION 文件不存在或为空，构建版本将标记为 'unknown'"
    else
        info "VERSION: $ver"
    fi

    if [ "$has_error" -eq 1 ]; then
        error "项目结构检查未通过"
        exit 1
    fi
    info "项目结构检查通过"
}

# 构建前端
# 在子 shell 中执行，避免 cd 污染当前 shell 工作目录
build_frontend() {
    title "构建前端"
    local version
    version="$(get_version)"
    (
        cd "$PROJECT_DIR/web"
        info "安装前端依赖..."
        bun install
        info "编译前端 (版本: ${version})..."
        DISABLE_ESLINT_PLUGIN='true' VITE_REACT_APP_VERSION="${version}" bun run build
    ) || {
        error "前端构建失败"
        exit 1
    }
    info "前端构建完成"
}

# 构建后端
# 在子 shell 中执行，避免 cd 污染当前 shell 工作目录
build_backend() {
    title "构建后端"
    local version tmp_binary
    version="$(get_version)"
    tmp_binary="${BINARY_PATH}.new"
    # 先构建到临时文件，成功后再原子替换旧二进制
    # 这样 rebuild 时若 go build 失败，旧二进制仍存在，服务可以继续运行
    rm -f "$tmp_binary"
    (
        cd "$PROJECT_DIR"
        info "编译后端 (版本: ${version})..."
        go build -ldflags "-s -w -X '${MODULE_PATH}/common.Version=${version}'" -o "$tmp_binary"
    ) || {
        rm -f "$tmp_binary"
        error "后端构建失败"
        exit 1
    }
    mv "$tmp_binary" "$BINARY_PATH" || {
        rm -f "$tmp_binary"
        error "二进制替换失败: $tmp_binary → $BINARY_PATH"
        exit 1
    }
    info "后端构建完成: $BINARY_PATH"
}

# 确保 upstream remote 已配置
ensure_upstream() {
    if ! git -C "$PROJECT_DIR" remote get-url "$UPSTREAM_REMOTE" &>/dev/null; then
        info "添加 upstream remote: $UPSTREAM_URL"
        git -C "$PROJECT_DIR" remote add "$UPSTREAM_REMOTE" "$UPSTREAM_URL"
    else
        local current_url
        current_url="$(git -C "$PROJECT_DIR" remote get-url "$UPSTREAM_REMOTE")"
        if [ "$current_url" != "$UPSTREAM_URL" ]; then
            warn "upstream remote URL 不匹配，更新为: $UPSTREAM_URL"
            git -C "$PROJECT_DIR" remote set-url "$UPSTREAM_REMOTE" "$UPSTREAM_URL"
        fi
    fi
}

# 获取当前分支名
current_branch() {
    git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD
}

# 生成 systemd service 文件内容
# 注意: --port 使用脚本顶部 PORT 变量，优先级高于 .env 中的 PORT
#       如需修改端口，请修改脚本顶部的 PORT 变量后重新 install
generate_systemd_service() {
    local user
    user="$(whoami)"
    cat <<EOF
[Unit]
Description=New API Service
After=network.target redis.service redis-server.service

[Service]
User=${user}
WorkingDirectory=${PROJECT_DIR}
ExecStart="${BINARY_PATH}" --port ${PORT} --log-dir "${PROJECT_DIR}/logs"
Restart=always
RestartSec=5
EnvironmentFile=-${PROJECT_DIR}/.env

[Install]
WantedBy=multi-user.target
EOF
}

# 停止服务
# macOS: 发送 SIGTERM 给所有匹配进程，超时后发送 SIGKILL
stop_service() {
    if [ "$OS_TYPE" = "linux" ]; then
        _sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    elif [ "$OS_TYPE" = "darwin" ]; then
        local pids
        pids="$(pgrep -x "${SERVICE_NAME}" 2>/dev/null || true)"
        if [ -n "$pids" ]; then
            # 向所有匹配进程发送 SIGTERM（而非只取第一个）
            echo "$pids" | xargs kill 2>/dev/null || true
            # 等待所有进程退出，最多 5 秒
            local i=0
            while [ $i -lt 10 ]; do
                if ! pgrep -x "${SERVICE_NAME}" &>/dev/null; then
                    break
                fi
                sleep 0.5
                i=$((i + 1))
            done
            # 仍有残留进程则强制终止
            pids="$(pgrep -x "${SERVICE_NAME}" 2>/dev/null || true)"
            if [ -n "$pids" ]; then
                warn "进程未响应 SIGTERM，发送 SIGKILL"
                echo "$pids" | xargs kill -9 2>/dev/null || true
            fi
        fi
    fi
}

# 启动服务
# macOS: nohup 后台运行防 SIGHUP，用 pgrep 确认实际进程存活
# 启动前确保 Redis 运行（仅在 Redis 已安装时）
start_service() {
    if command -v redis-cli &>/dev/null; then
        if ! redis_running; then
            start_redis || true
        fi
    fi
    if [ "$OS_TYPE" = "linux" ]; then
        _sudo systemctl restart "$SERVICE_NAME"
    elif [ "$OS_TYPE" = "darwin" ]; then
        mkdir -p "$PROJECT_DIR/logs"
        # 使用 nohup 防止 SSH 断开时 SIGHUP 杀死进程；
        # 不依赖 $!（nohup 的 PID），改用 pgrep 确认实际服务进程存活
        nohup "$BINARY_PATH" --port "$PORT" --log-dir "$PROJECT_DIR/logs" \
            >> "$PROJECT_DIR/logs/stdout.log" 2>> "$PROJECT_DIR/logs/stderr.log" &
        # 等待一秒后用 pgrep 确认实际服务进程存活
        sleep 1
        local service_pid
        service_pid="$(pgrep -x "${SERVICE_NAME}" 2>/dev/null | head -1 || true)"
        if [ -n "$service_pid" ]; then
            info "服务已启动 (PID: $service_pid, 端口: $PORT)"
        else
            error "服务启动失败，请查看日志: $PROJECT_DIR/logs/stderr.log"
            return 1
        fi
    fi
}

# 重启服务（先停后启）
restart_service() {
    stop_service
    start_service
}

# ===== Redis 管理函数 =====

# 检测 Redis 是否运行中
# 返回: 0=运行中, 1=未运行或 redis-cli 未安装
redis_running() {
    if ! command -v redis-cli &>/dev/null; then
        return 1
    fi
    if command -v timeout &>/dev/null; then
        timeout 1 redis-cli ping 2>/dev/null | grep -q "PONG"
    else
        redis-cli ping 2>/dev/null | grep -q "PONG"
    fi
}

# 启动 Redis 服务（不做验证，由调用方负责验证就绪状态）
# macOS: brew services start redis
# Linux: systemctl start redis-server / redis
start_redis() {
    if redis_running; then
        info "Redis 已在运行中"
        return 0
    fi
    info "启动 Redis..."
    if [ "$OS_TYPE" = "darwin" ]; then
        brew services start redis 2>/dev/null || true
    else
        # 先检查哪个服务单元存在，再启动，避免因服务不存在的非零退出触发 fallback
        if systemctl list-unit-files redis-server.service &>/dev/null 2>&1 \
                && systemctl list-unit-files redis-server.service | grep -q 'redis-server'; then
            _sudo systemctl start redis-server 2>/dev/null || true
        elif systemctl list-unit-files redis.service &>/dev/null 2>&1 \
                && systemctl list-unit-files redis.service | grep -q 'redis.service'; then
            _sudo systemctl start redis 2>/dev/null || true
        else
            warn "未找到 redis-server.service 或 redis.service，请手动启动 Redis"
        fi
    fi
}

# 停止 Redis 服务
# macOS: brew services stop redis
# Linux: systemctl stop redis-server / redis
stop_redis() {
    if ! redis_running; then
        return 0
    fi
    info "停止 Redis..."
    if [ "$OS_TYPE" = "darwin" ]; then
        brew services stop redis 2>/dev/null || true
    else
        if systemctl list-unit-files redis-server.service &>/dev/null 2>&1 \
                && systemctl list-unit-files redis-server.service | grep -q 'redis-server'; then
            _sudo systemctl stop redis-server 2>/dev/null || true
        elif systemctl list-unit-files redis.service &>/dev/null 2>&1 \
                && systemctl list-unit-files redis.service | grep -q 'redis.service'; then
            _sudo systemctl stop redis 2>/dev/null || true
        fi
    fi
}

# 打印 Redis 状态信息
# 若未安装：打印"Redis 未安装"
# 若未运行：打印"Redis 未运行"
# 若运行中：打印版本和端口
redis_status() {
    title "Redis 状态"
    if ! command -v redis-cli &>/dev/null; then
        warn "Redis 未安装"
        return 0
    fi
    if redis_running; then
        info "Redis 正在运行"
        local _redis_info redis_ver redis_port
        _redis_info="$(redis-cli info server 2>/dev/null)"
        redis_ver="$(printf '%s' "$_redis_info" | grep 'redis_version' | cut -d: -f2 | tr -d '[:space:]')"
        redis_port="$(printf '%s' "$_redis_info" | grep '^tcp_port' | cut -d: -f2 | tr -d '[:space:]')"
        [ -n "$redis_ver" ]  && info "Redis 版本: $redis_ver"
        [ -n "$redis_port" ] && info "Redis 端口: $redis_port"
    else
        warn "Redis 未运行"
    fi
}

# 一键安装配置 Redis（install 专用）
# 步骤：检测 → 安装 → 启动 → 等待就绪 → 写入 .env（幂等）
setup_redis() {
    # 1. 检测是否已安装
    if ! command -v redis-cli &>/dev/null; then
        info "Redis 未安装，开始安装..."
        install_cmd redis || { warn "Redis 安装失败，跳过 Redis 配置"; return 0; }
        # 写入标记，供 uninstall 时识别是否由本脚本安装（预装的 Redis 不会被卸载）
        grep -qE '^REDIS_MANAGED_BY_SETUP=true' "$PROJECT_DIR/.env" 2>/dev/null \
            || echo "REDIS_MANAGED_BY_SETUP=true" >> "$PROJECT_DIR/.env"
    else
        info "Redis 已安装: $(command -v redis-cli)"
    fi

    # 2. 启动 Redis
    start_redis || true

    # 3. 等待 Redis 就绪（最多 10 秒）
    local ready=0 _ri=0
    if redis_running; then
        ready=1
    else
        info "等待 Redis 就绪..."
        while [ $_ri -lt 10 ]; do
            if redis_running; then
                ready=1
                break
            fi
            sleep 1
            _ri=$((_ri + 1))
        done
    fi
    if [ "$ready" -eq 1 ]; then
        info "Redis 已就绪"
    else
        warn "Redis 未能在 10 秒内就绪，请手动启动 Redis"
    fi

    # 4a. 写入 REDIS_CONN_STRING（幂等）
    if grep -qE '^REDIS_CONN_STRING=.+' "$PROJECT_DIR/.env" 2>/dev/null; then
        info "REDIS_CONN_STRING 已配置，跳过"
    else
        if grep -qE '^#*[[:space:]]*REDIS_CONN_STRING=' "$PROJECT_DIR/.env" 2>/dev/null; then
            local _tmp_r
            _tmp_r="$(mktemp)"
            chmod 600 "$_tmp_r"
            if awk '/^#*[[:space:]]*REDIS_CONN_STRING=/ { print "REDIS_CONN_STRING=redis://localhost:6379/0"; next } { print }' \
                    "$PROJECT_DIR/.env" > "$_tmp_r" \
                    && mv "$_tmp_r" "$PROJECT_DIR/.env"; then
                info "已写入 REDIS_CONN_STRING=redis://localhost:6379/0"
            else
                rm -f "$_tmp_r"
                warn "REDIS_CONN_STRING 写入失败"
            fi
        else
            echo "REDIS_CONN_STRING=redis://localhost:6379/0" >> "$PROJECT_DIR/.env"
            info "已写入 REDIS_CONN_STRING=redis://localhost:6379/0"
        fi
    fi

    # 4b. 写入 MEMORY_CACHE_ENABLED（幂等）
    if grep -qE '^MEMORY_CACHE_ENABLED=.+' "$PROJECT_DIR/.env" 2>/dev/null; then
        info "MEMORY_CACHE_ENABLED 已配置，跳过"
    else
        if grep -qE '^#*[[:space:]]*MEMORY_CACHE_ENABLED=' "$PROJECT_DIR/.env" 2>/dev/null; then
            local _tmp_m
            _tmp_m="$(mktemp)"
            chmod 600 "$_tmp_m"
            if awk '/^#*[[:space:]]*MEMORY_CACHE_ENABLED=/ { print "MEMORY_CACHE_ENABLED=true"; next } { print }' \
                    "$PROJECT_DIR/.env" > "$_tmp_m" \
                    && mv "$_tmp_m" "$PROJECT_DIR/.env"; then
                info "已写入 MEMORY_CACHE_ENABLED=true"
            else
                rm -f "$_tmp_m"
                warn "MEMORY_CACHE_ENABLED 写入失败"
            fi
        else
            echo "MEMORY_CACHE_ENABLED=true" >> "$PROJECT_DIR/.env"
            info "已写入 MEMORY_CACHE_ENABLED=true"
        fi
    fi
}

# 打印凭据信息
# 参数: $1 = 端口, $2 = 用户名, $3 = 密码, $4 = Access Token（可为空）
_print_credentials() {
    local _port="$1" _user="$2" _pass="$3" _token="$4"
    echo ""
    info "管理后台: http://localhost:$_port"
    info "用户名: $_user"
    info "密码: $_pass"
    [ -n "$_token" ] && info "Access Token: ${_token:0:12}..."
    warn "请妥善保管密码，此密码仅显示一次"
}

# 初始化管理员凭据（全新数据库场景）
# 通过 /api/setup 创建初始管理员，登录后获取 Access Token 并写入 .env
# 依赖: 全局变量 PY、PORT、SCRIPT_DIR
_init_admin_credentials() {
    local ADMIN_PASS
    ADMIN_PASS="$(head -c 48 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 12)"

    # 通过 stdin 传递密码，避免密码出现在 ps 命令输出中
    local SETUP_BODY SETUP_POST_RESP SETUP_SUCCESS
    SETUP_BODY="$(printf '%s' "$ADMIN_PASS" | "$PY" -c "
import json, sys
pw = sys.stdin.read()
print(json.dumps({'username': 'admin', 'password': pw, 'confirmPassword': pw}))
")"
    SETUP_POST_RESP="$(curl -s --max-time 10 -X POST "http://localhost:$PORT/api/setup" \
        -H "Content-Type: application/json" -d "$SETUP_BODY" 2>/dev/null || true)"

    if [ -z "$SETUP_POST_RESP" ]; then
        warn "初始化请求无响应，请手动访问 http://localhost:$PORT 完成初始设置"
        return 1
    fi

    SETUP_SUCCESS="$(py_json_get "$SETUP_POST_RESP" "success")" || true
    if [ "$SETUP_SUCCESS" != "true" ]; then
        warn "系统初始化失败: ${SETUP_POST_RESP:0:200}"
        warn "请手动访问 http://localhost:$PORT 完成初始设置"
        return 1
    fi
    info "管理员账号创建成功"

    # 登录获取 session cookie，用于申请 Access Token
    # COOKIE_JAR 不使用 local，确保 EXIT/INT/TERM trap 能正确访问此变量
    COOKIE_JAR=""
    if ! COOKIE_JAR="$(mktemp 2>/dev/null)"; then
        warn "无法创建临时 cookie 文件，跳过 Token 获取"
        _print_credentials "$PORT" "admin" "$ADMIN_PASS" ""
        return 0
    fi
    trap 'rm -f "$COOKIE_JAR" 2>/dev/null' EXIT INT TERM

    # 通过 stdin 传递密码，避免密码出现在 ps 命令输出中
    local LOGIN_BODY LOGIN_RESP LOGIN_SUCCESS
    LOGIN_BODY="$(printf '%s' "$ADMIN_PASS" | "$PY" -c "
import json, sys
pw = sys.stdin.read()
print(json.dumps({'username': 'admin', 'password': pw}))
")"
    LOGIN_RESP="$(curl -s --max-time 10 -c "$COOKIE_JAR" -X POST "http://localhost:$PORT/api/user/login" \
        -H "Content-Type: application/json" -d "$LOGIN_BODY" 2>/dev/null || true)"
    LOGIN_SUCCESS="$(py_json_get "$LOGIN_RESP" "success")" || true

    if [ "$LOGIN_SUCCESS" != "true" ]; then
        rm -f "$COOKIE_JAR"
        trap - EXIT INT TERM
        warn "登录失败，跳过 Token 生成"
        _print_credentials "$PORT" "admin" "$ADMIN_PASS" ""
        return 0
    fi

    # 从登录响应提取用户 ID（UserAuth 中间件需要 New-Api-User header）
    local USER_ID
    USER_ID="$(py_json_get "$LOGIN_RESP" "data.id")" || true
    if [ -z "$USER_ID" ]; then
        rm -f "$COOKIE_JAR"
        trap - EXIT INT TERM
        warn "无法提取用户 ID，跳过 Token 生成"
        _print_credentials "$PORT" "admin" "$ADMIN_PASS" ""
        return 0
    fi

    # 获取 Access Token
    local TOKEN_RESP ACCESS_TOKEN
    TOKEN_RESP="$(curl -s --max-time 10 -b "$COOKIE_JAR" \
        -H "New-Api-User: $USER_ID" \
        "http://localhost:$PORT/api/user/token" 2>/dev/null || true)"
    rm -f "$COOKIE_JAR"
    trap - EXIT INT TERM
    ACCESS_TOKEN="$(py_json_get "$TOKEN_RESP" "data")" || true

    # 先打印凭据，确保即使 .env 写入失败也不丢失
    _print_credentials "$PORT" "admin" "$ADMIN_PASS" "$ACCESS_TOKEN"

    if [ -z "$ACCESS_TOKEN" ]; then
        warn "获取 Access Token 失败，跳过凭据保存"
        return 0
    fi

    # 幂等写入三个管理员凭据变量到 .env
    local _env_write_ok=true
    # 写入 ADMIN_SERVER
    if grep -qE '^ADMIN_SERVER=.+' "$PROJECT_DIR/.env" 2>/dev/null; then
        local _tmp1
        _tmp1="$(mktemp)" && chmod 600 "$_tmp1" \
            && awk -v val="http://localhost:$PORT" \
                '/^ADMIN_SERVER=/ { print "ADMIN_SERVER=" val; next } { print }' \
                "$PROJECT_DIR/.env" > "$_tmp1" \
            && mv "$_tmp1" "$PROJECT_DIR/.env" || { rm -f "$_tmp1"; _env_write_ok=false; }
    else
        echo "ADMIN_SERVER=http://localhost:$PORT" >> "$PROJECT_DIR/.env" || _env_write_ok=false
    fi
    # 写入 ADMIN_TOKEN
    if grep -qE '^ADMIN_TOKEN=.+' "$PROJECT_DIR/.env" 2>/dev/null; then
        local _tmp2
        _tmp2="$(mktemp)" && chmod 600 "$_tmp2" \
            && awk -v val="$ACCESS_TOKEN" \
                '/^ADMIN_TOKEN=/ { print "ADMIN_TOKEN=" val; next } { print }' \
                "$PROJECT_DIR/.env" > "$_tmp2" \
            && mv "$_tmp2" "$PROJECT_DIR/.env" || { rm -f "$_tmp2"; _env_write_ok=false; }
    else
        echo "ADMIN_TOKEN=$ACCESS_TOKEN" >> "$PROJECT_DIR/.env" || _env_write_ok=false
    fi
    # 写入 ADMIN_USER_ID
    if grep -qE '^ADMIN_USER_ID=.+' "$PROJECT_DIR/.env" 2>/dev/null; then
        local _tmp3
        _tmp3="$(mktemp)" && chmod 600 "$_tmp3" \
            && awk -v val="$USER_ID" \
                '/^ADMIN_USER_ID=/ { print "ADMIN_USER_ID=" val; next } { print }' \
                "$PROJECT_DIR/.env" > "$_tmp3" \
            && mv "$_tmp3" "$PROJECT_DIR/.env" || { rm -f "$_tmp3"; _env_write_ok=false; }
    else
        echo "ADMIN_USER_ID=$USER_ID" >> "$PROJECT_DIR/.env" || _env_write_ok=false
    fi
    if [ "$_env_write_ok" = "true" ]; then
        info "管理员凭据已写入 .env (ADMIN_SERVER / ADMIN_TOKEN / ADMIN_USER_ID)"
    else
        warn ".env 凭据写入失败，请手动记录上述信息"
    fi
}

# ===== 模板工具函数（template-dark / template-light 子命令共用）=====

_TEMPLATE_TMPFILES=()
_template_cleanup() { rm -f "${_TEMPLATE_TMPFILES[@]}" 2>/dev/null; }

# 从 .env 加载 ADMIN_SERVER / ADMIN_TOKEN / ADMIN_USER_ID 到 SERVER / TOKEN / USER_ID
# 依赖: 全局变量 PY、PROJECT_DIR
_load_template_config() {
    if [ -z "$PY" ]; then
        error "需要 python3 或 python，请先安装"; exit 1
    fi
    if ! command -v curl &>/dev/null; then
        error "需要 curl，请先安装"; exit 1
    fi
    local env_file="$PROJECT_DIR/.env"
    if [ ! -f "$env_file" ]; then
        error "未找到 .env 文件"
        echo "请先运行: ./scripts/setup.sh install"
        exit 1
    fi
    SERVER=$(grep -E '^ADMIN_SERVER=' "$env_file" 2>/dev/null | cut -d= -f2- | head -1)
    TOKEN=$(grep  -E '^ADMIN_TOKEN='  "$env_file" 2>/dev/null | cut -d= -f2- | head -1)
    USER_ID=$(grep -E '^ADMIN_USER_ID=' "$env_file" 2>/dev/null | cut -d= -f2- | head -1)
    if [ -z "$TOKEN" ] || [ -z "$USER_ID" ]; then
        error ".env 中缺少 ADMIN_TOKEN 或 ADMIN_USER_ID"
        echo "请重新运行: ./scripts/setup.sh install"
        exit 1
    fi
}

# 从 stdin 读取值，调用 API 写入单个选项
# 用法：printf 'value' | set_option "Key"
#       cat <<'EOF' | set_option "Key"
#       multi-line value
#       EOF
# 依赖: 全局变量 PY、SERVER、TOKEN、USER_ID、_TEMPLATE_TMPFILES
set_option() {
    local key="$1"
    local value
    value=$(cat)
    local tmpfile
    tmpfile=$(mktemp)
    _TEMPLATE_TMPFILES+=("$tmpfile")

    printf '%s' "$value" | "$PY" -c "
import json, sys
key = sys.argv[1]
value = sys.stdin.read()
with open(sys.argv[2], 'w') as f:
    json.dump({'key': key, 'value': value}, f)
" "$key" "$tmpfile"

    local response curl_err
    curl_err=$(mktemp)
    _TEMPLATE_TMPFILES+=("$curl_err")
    response=$(curl -s -X PUT "${SERVER}/api/option/" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "New-Api-User: ${USER_ID}" \
        -H "Content-Type: application/json" \
        -d "@${tmpfile}" 2>"$curl_err") || true

    rm -f "$tmpfile"

    if [ -z "$response" ]; then
        local err_detail
        err_detail=$(cat "$curl_err")
        rm -f "$curl_err"
        echo "  ✗ $key - 网络连接失败: ${err_detail:-服务器无响应}"
        return 1
    fi

    rm -f "$curl_err"

    if printf '%s' "$response" | "$PY" -c "import json,sys; exit(0 if json.load(sys.stdin).get('success') else 1)" 2>/dev/null; then
        echo "  ✓ $key"
    else
        local msg
        msg=$(printf '%s' "$response" | "$PY" -c "
import json,sys
try:
  d=json.load(sys.stdin); print(d.get('message','未知错误'))
except:
  print(sys.stdin.read())
" 2>/dev/null)
        echo "  ✗ $key - ${msg:-$response}"

        # 认证失败时提前终止，避免重复相同错误
        if printf '%s' "$response" | "$PY" -c "
import json,sys
d=json.load(sys.stdin)
m=d.get('message','')
sys.exit(0 if any(k in m for k in ['token','无权','未登录','unauthorized']) else 1)
" 2>/dev/null; then
            echo ""
            echo "错误：认证失败，请检查 .env 中的 ADMIN_TOKEN 是否正确。"
            exit 1
        fi
    fi
}

# ===== 命令实现 =====

# uninstall: 停止服务、删除所有 install 产物、清理 systemd 服务
# 保留源码文件（.env.example、go.mod、web/src/ 等）、git 仓库、数据库文件和凭据文件
cmd_uninstall() {
    title "卸载 New API 服务"

    # 提前读取 Redis 安装标记（.env 会在后续步骤被删除，须在此处读取）
    local redis_managed=false
    if grep -qE '^REDIS_MANAGED_BY_SETUP=true' "$PROJECT_DIR/.env" 2>/dev/null; then
        redis_managed=true
    fi

    # 先确认，再停止服务（避免用户取消后服务已停）
    echo ""
    warn "即将删除以下内容:"
    echo "  - 环境配置:   $PROJECT_DIR/.env"
    echo "  - 二进制文件: $BINARY_PATH"
    echo "  - 前端构建:   $PROJECT_DIR/web/dist/"
    echo "  - 日志目录:   $PROJECT_DIR/logs/"
    if [ "$redis_managed" = "true" ]; then
        echo "  - Redis 服务及安装包（由本脚本安装）"
    fi
    if [ "$OS_TYPE" = "linux" ]; then
        echo "  - systemd 服务: $SYSTEMD_PATH"
    fi
    echo ""
    local answer
    read -r -p "确认卸载？此操作不可恢复 (y/N): " answer || true
    if [ "$answer" != "y" ] && [ "$answer" != "Y" ]; then
        info "已取消卸载"
        exit 0
    fi

    # 确认后停止服务
    info "停止服务..."
    stop_service

    # 删除环境配置
    rm -f "$PROJECT_DIR/.env"
    info "已删除 .env"

    # 删除二进制文件
    rm -f "$BINARY_PATH"
    info "已删除二进制文件"

    # 删除前端构建产物
    rm -rf "$PROJECT_DIR/web/dist"
    info "已删除 web/dist/"

    # 删除日志目录
    rm -rf "$PROJECT_DIR/logs"
    info "已删除 logs/"

    # 清理 systemd 服务（仅 Linux）
    if [ "$OS_TYPE" = "linux" ] && [ -f "$SYSTEMD_PATH" ]; then
        _sudo systemctl disable "$SERVICE_NAME" 2>/dev/null || true
        _sudo rm -f "$SYSTEMD_PATH"
        _sudo systemctl daemon-reload
        info "已清理 systemd 服务"
    fi

    # 卸载 Redis（仅限由本脚本安装的，预装的 Redis 不受影响）
    if [ "$redis_managed" = "true" ] && command -v redis-cli &>/dev/null; then
        info "停止并卸载 Redis..."
        stop_redis || true
        if [ "$OS_TYPE" = "darwin" ]; then
            brew uninstall redis 2>/dev/null || true
        else
            if command -v apt-get &>/dev/null; then
                _sudo apt-get remove -y redis-server 2>/dev/null || true
            elif command -v yum &>/dev/null; then
                _sudo yum remove -y redis 2>/dev/null || true
            fi
        fi
        info "Redis 已卸载"
    fi

    title "卸载完成"
    info "所有 install 产物已清理"
    info "源码、git 仓库和 upstream remote 配置已保留"
    if [ -f "$PROJECT_DIR/one-api.db" ]; then
        info "数据库文件已保留: $PROJECT_DIR/one-api.db"
    fi
    info "可随时重新运行 ./scripts/setup.sh install"
}

# install: 初始化项目、编译并启动服务
cmd_install() {
    title "安装 New API 服务"

    # 环境检测: 依赖 + 版本 + 项目结构 + 端口
    check_dependencies
    check_project_structure
    check_port

    # 配置 git upstream
    title "配置 Git"
    ensure_upstream
    info "upstream remote 已配置: $UPSTREAM_URL"

    # 确保在正确的分支上（在构建之前切换，确保基于正确的分支编译）
    local branch
    branch="$(current_branch)"
    if [ "$branch" != "$BRANCH_NAME" ]; then
        if git -C "$PROJECT_DIR" show-ref --verify --quiet "refs/heads/$BRANCH_NAME"; then
            info "切换到 $BRANCH_NAME 分支"
            git -C "$PROJECT_DIR" checkout "$BRANCH_NAME"
        else
            info "创建并切换到 $BRANCH_NAME 分支"
            git -C "$PROJECT_DIR" checkout -b "$BRANCH_NAME"
        fi
    else
        info "当前已在 $BRANCH_NAME 分支"
    fi

    # 配置 .env 文件
    title "配置环境变量"
    if [ ! -f "$PROJECT_DIR/.env" ]; then
        if [ -f "$PROJECT_DIR/.env.example" ]; then
            cp "$PROJECT_DIR/.env.example" "$PROJECT_DIR/.env"
            info "已从 .env.example 创建 .env"
        else
            touch "$PROJECT_DIR/.env"
            info "已创建空 .env"
        fi
    else
        info ".env 文件已存在"
    fi
    # 立即限制 .env 权限，防止其他用户读取
    chmod 600 "$PROJECT_DIR/.env"
    # SESSION_SECRET 是必填项（设为 random_string 会导致程序 fatal）
    # 如果 .env 中没有有效的 SESSION_SECRET，自动生成一个
    if ! grep -qE '^SESSION_SECRET=.+' "$PROJECT_DIR/.env" \
       || grep -qE '^SESSION_SECRET=random_string$' "$PROJECT_DIR/.env"; then
        local secret
        secret="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)"
        # 替换已有的行，或追加新行
        # 使用临时文件替代 sed -i.bak，避免 .bak 短暂包含明文 secret
        if grep -q '^SESSION_SECRET=' "$PROJECT_DIR/.env" || grep -q '^# SESSION_SECRET=' "$PROJECT_DIR/.env"; then
            local _tmp_env
            _tmp_env="$(mktemp)"
            chmod 600 "$_tmp_env"
            # 使用 awk -v 传递变量，避免 secret 中含有 & \ 等 sed 特殊字符导致替换错误
            awk -v secret="$secret" '/^#* *SESSION_SECRET=/ { print "SESSION_SECRET=" secret; next } { print }' \
                "$PROJECT_DIR/.env" > "$_tmp_env" || { rm -f "$_tmp_env"; error "SESSION_SECRET 替换失败"; exit 1; }
            mv "$_tmp_env" "$PROJECT_DIR/.env" || { rm -f "$_tmp_env"; error "SESSION_SECRET 写入失败"; exit 1; }
        else
            echo "SESSION_SECRET=${secret}" >> "$PROJECT_DIR/.env"
        fi
        info "已自动生成 SESSION_SECRET"
    else
        info "SESSION_SECRET 已配置"
    fi

    # 配置 Redis
    title "配置 Redis"
    setup_redis

    # 构建
    build_frontend
    build_backend

    # 创建 logs 目录
    mkdir -p "$PROJECT_DIR/logs"
    info "logs 目录已创建: $PROJECT_DIR/logs"

    # 注册 systemd 服务（仅 Linux）
    if [ "$OS_TYPE" = "linux" ]; then
        title "注册系统服务"
        local service_content
        service_content="$(generate_systemd_service)"
        echo "$service_content" | _sudo tee "$SYSTEMD_PATH" >/dev/null
        info "已写入 $SYSTEMD_PATH"
        _sudo systemctl daemon-reload
        _sudo systemctl enable "$SERVICE_NAME"
    fi

    # 启动服务
    title "启动服务"
    restart_service

    # ===== 自动初始化系统凭据 =====
    title "初始化系统凭据"

    # 检测 Python（py_json_get 工具函数依赖全局变量 PY）
    if [ -z "$PY" ]; then
        warn "未找到 python3/python，跳过自动初始化"
        warn "请手动访问 http://localhost:$PORT 完成初始设置"
    else
        # 等待服务就绪（最多 15 秒）
        # 先将 http_code 存入变量再判断，避免管道截断 curl 输出
        info "等待服务就绪..."
        local ready=0
        local _i
        for _i in {1..15}; do
            local http_code
            http_code="$(curl -s -o /dev/null -w '%{http_code}' \
                "http://localhost:$PORT/api/status" 2>/dev/null)" || http_code="000"
            if [ "$http_code" = "200" ]; then
                ready=1
                break
            fi
            sleep 1
        done

        if [ "$ready" -eq 0 ]; then
            warn "服务未在 15 秒内就绪，跳过自动初始化"
            warn "请手动访问 http://localhost:$PORT 完成初始设置"
        else
            info "服务已就绪，开始初始化..."

            # 检查 setup 状态
            local SETUP_RESP SETUP_STATUS
            SETUP_RESP="$(curl -s --max-time 10 "http://localhost:$PORT/api/setup" 2>/dev/null || true)"
            if [ -z "$SETUP_RESP" ]; then
                warn "无法获取系统状态（服务未响应或网络错误），跳过自动初始化"
                warn "请手动访问 http://localhost:$PORT 完成初始设置"
            else
                SETUP_STATUS="$(py_json_get "$SETUP_RESP" "data.status")" || true

                if [ "$SETUP_STATUS" = "true" ]; then
                    # 系统已初始化，检查 .env 中是否存在 ADMIN_TOKEN
                    if grep -qE '^ADMIN_TOKEN=.+' "$PROJECT_DIR/.env" 2>/dev/null; then
                        info "系统已初始化，管理员凭据已存在于 .env"
                    else
                        info "系统已初始化（已有数据库），跳过凭据初始化"
                        warn "未在 .env 中找到 ADMIN_TOKEN"
                        warn "请使用原有管理员密码登录: http://localhost:$PORT"
                        warn "如忘记密码，请参考文档通过数据库重置"
                    fi
                elif [ "$SETUP_STATUS" = "false" ]; then
                    # 全新数据库，调用辅助函数创建初始管理员并保存凭据
                    # || true：凭据初始化失败属非致命错误，不应中止 install（set -e 保护）
                    _init_admin_credentials || true
                else
                    # SETUP_STATUS 为空：JSON 解析失败或返回了非 true/false 的值
                    warn "无法解析系统状态，跳过自动初始化"
                    warn "原始响应: ${SETUP_RESP:0:200}"
                    warn "请手动访问 http://localhost:$PORT 完成初始设置"
                fi
            fi
        fi
    fi

    title "安装完成"
    info "项目目录: $PROJECT_DIR"
    info "二进制文件: $BINARY_PATH"
    info "端口: $PORT"
    info "配置文件: $PROJECT_DIR/.env"
    echo ""
    if grep -qE '^REDIS_CONN_STRING=.+' "$PROJECT_DIR/.env" 2>/dev/null; then
        info "已自动配置本地 Redis，REDIS_CONN_STRING 已写入 .env"
    else
        warn "Redis 配置未成功，如需启用请手动在 $PROJECT_DIR/.env 中设置 REDIS_CONN_STRING"
    fi
    info "如需 MySQL/PostgreSQL 等，请编辑 $PROJECT_DIR/.env"
}

# rebuild: 重新编译并重启服务
cmd_rebuild() {
    title "重新编译"

    check_dependencies
    build_frontend
    build_backend

    # 重启服务
    title "重启服务"
    restart_service

    info "重新编译并重启完成"
}

# pull: 从上游同步更新
cmd_pull() {
    title "从上游同步更新"
    local answer

    # 确保 upstream 已配置
    ensure_upstream

    # 检查已跟踪文件是否有未提交的变更（不检查未跟踪文件，不影响 merge）
    if ! git -C "$PROJECT_DIR" diff --quiet \
       || ! git -C "$PROJECT_DIR" diff --cached --quiet; then
        error "有未提交的变更，请先提交或 stash 后再同步"
        git -C "$PROJECT_DIR" status --short
        echo ""
        echo "  可使用以下命令暂存变更后再执行 pull:"
        echo "    git stash"
        echo "    ./scripts/setup.sh pull"
        echo "  同步完成后恢复变更:"
        echo "    git stash pop"
        exit 1
    fi

    # fetch 上游
    info "拉取上游更新..."
    if ! git -C "$PROJECT_DIR" fetch "$UPSTREAM_REMOTE"; then
        error "拉取上游失败，请检查网络连接"
        exit 1
    fi

    # 合并
    info "合并 ${UPSTREAM_REMOTE}/${BRANCH_NAME} 到当前分支..."
    if git -C "$PROJECT_DIR" merge "${UPSTREAM_REMOTE}/${BRANCH_NAME}" --no-edit; then
        info "合并成功"

        # 提示是否 rebuild
        read -r -p "是否现在重新编译并重启？(y/n) " answer || true
        if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
            cmd_rebuild
        else
            info "跳过编译，可稍后运行 rebuild 命令"
        fi
    else
        error "合并出现冲突，请手动解决后运行:"
        echo "  git add <已解决的文件>"
        echo "  git commit"
        echo "  ./scripts/setup.sh rebuild"
        exit 1
    fi
}

# push: 推送到远程
cmd_push() {
    title "推送到远程仓库"

    local branch answer
    branch="$(current_branch)"
    if [ "$branch" != "$BRANCH_NAME" ]; then
        warn "当前分支为 '$branch'，不是 '$BRANCH_NAME'"
        read -r -p "是否仍然推送当前分支？(y/n) " answer || true
        if [ "$answer" != "y" ] && [ "$answer" != "Y" ]; then
            info "已取消推送"
            exit 0
        fi
    fi

    info "推送 $branch 到 origin..."
    if ! git -C "$PROJECT_DIR" push origin "$branch"; then
        error "推送失败，请检查网络连接和远程仓库权限"
        exit 1
    fi
    info "推送完成"
}

# status: 查看服务状态（含实际监听端口）
cmd_status() {
    title "服务状态"
    if [ "$OS_TYPE" = "linux" ]; then
        _sudo systemctl status "$SERVICE_NAME" --no-pager || true
    elif [ "$OS_TYPE" = "darwin" ]; then
        # macOS 下按进程名精确匹配检查是否在运行
        local pid
        pid="$(pgrep -x "${SERVICE_NAME}" 2>/dev/null | head -1 || true)"
        if [ -n "$pid" ]; then
            info "服务正在运行 (PID: $pid)"
            ps -p "$pid" -o pid,user,%cpu,%mem,etime,command 2>/dev/null || true
            # 显示实际监听端口
            local ports
            ports="$(lsof -p "$pid" -a -iTCP -sTCP:LISTEN -P -n 2>/dev/null \
                | grep -oE '(\*|\[?[0-9a-f.:]+\]?):[0-9]+' || true)"
            if [ -n "$ports" ]; then
                info "监听端口: $ports"
            fi
        else
            warn "服务未运行"
            info "启动命令: cd $PROJECT_DIR && ./$SERVICE_NAME --port $PORT --log-dir ./logs"
        fi
    else
        error "不支持的系统: $OS_TYPE"
    fi
    redis_status
}

# logs: 查看服务日志
cmd_logs() {
    title "服务日志"
    local log_dir="$PROJECT_DIR/logs"
    if [ "$OS_TYPE" = "linux" ]; then
        _sudo journalctl -u "$SERVICE_NAME" -f --no-pager -n 100
    elif [ "$OS_TYPE" = "darwin" ]; then
        if [ -d "$log_dir" ]; then
            local log_count
            log_count="$(find "$log_dir" -maxdepth 1 -name "*.log" -type f 2>/dev/null | wc -l | tr -d ' ')"
            if [ "$log_count" -gt 0 ]; then
                info "显示最近 100 行日志 (目录: $log_dir)"
                # 用 xargs 传递文件列表，避免构建 bash 数组
                find "$log_dir" -maxdepth 1 -name "*.log" -type f -print0 2>/dev/null \
                    | xargs -0 tail -f -n 100
            else
                warn "未找到日志文件"
                info "日志目录: $log_dir"
            fi
        else
            warn "日志目录不存在: $log_dir"
            info "请先运行 install 或 rebuild 生成二进制后手动启动"
        fi
    else
        error "不支持的系统: $OS_TYPE"
    fi
}

# template-dark: 应用深色高雅风主题模板
cmd_template_dark() {
    _load_template_config
    _TEMPLATE_TMPFILES=()
    trap _template_cleanup EXIT INT TERM
    echo "🌙 正在应用 [深色高雅风] 模板..."
    echo "   服务器: $SERVER"
    echo ""
    echo "Develop API"            | set_option "SystemName"
    echo "/logo-dark.svg"         | set_option "Logo"
    echo "https://api.develop.cc" | set_option "ServerAddress"
    cat <<'HTMLEOF' | set_option "HomePageContent"
<style>
.da-dark-bg{background:#0A0A0A;min-height:calc(100vh - 60px);min-height:calc(100dvh - 60px);width:100%}
.da-dark-wrap{font-family:Inter,-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;color:#E5E5E5;max-width:960px;margin:0 auto;padding:0 20px}
.da-dark-hero{text-align:center;padding:80px 0 60px;position:relative;overflow:visible}
.da-dark-hero::before{content:'';position:absolute;top:0;left:50%;transform:translateX(-50%);width:600px;height:600px;background:radial-gradient(circle,rgba(212,165,116,0.08) 0%,transparent 70%);pointer-events:none}
.da-dark-hero h1{font-size:52px;font-weight:700;letter-spacing:-0.02em;line-height:1.1;margin:0;background:linear-gradient(135deg,#D4A574,#C9956B);-webkit-background-clip:text;-webkit-text-fill-color:transparent;background-clip:text;color:transparent;position:relative}
.da-dark-hero .da-sub{font-size:20px;color:#888;margin-top:16px;line-height:1.4;max-width:560px;margin-left:auto;margin-right:auto;position:relative}
.da-dark-addr{margin-top:32px;background:#111;border:1px solid #2A2A2A;border-radius:10px;padding:16px 28px;display:inline-block;position:relative}
.da-dark-addr .da-label{color:#888;font-size:13px;text-transform:uppercase;letter-spacing:0.05em}
.da-dark-addr .da-url{font-size:17px;font-weight:600;color:#D4A574;margin-top:4px;font-family:'SF Mono',SFMono-Regular,Menlo,monospace}
.da-dark-cta{display:inline-block;background:linear-gradient(135deg,#D4A574,#C9956B);color:#0A0A0A;padding:12px 28px;border-radius:8px;font-size:16px;font-weight:600;text-decoration:none;margin-top:24px;transition:opacity 0.3s;position:relative}
.da-dark-cta:hover{opacity:0.9;color:#0A0A0A}
.da-dark-features{display:grid;grid-template-columns:repeat(3,1fr);gap:16px;padding:40px 0}
.da-dark-card{background:#111;border:1px solid #2A2A2A;border-radius:12px;padding:28px;text-align:center;transition:border-color 0.3s}
.da-dark-card:hover{border-color:#D4A574}
.da-dark-card .da-icon{font-size:32px;margin-bottom:16px;background:linear-gradient(135deg,#D4A574,#C9956B);-webkit-background-clip:text;-webkit-text-fill-color:transparent;background-clip:text;color:transparent}
.da-dark-card h3{font-size:17px;font-weight:600;color:#E5E5E5;margin:0 0 8px}
.da-dark-card p{font-size:14px;color:#888;margin:0;line-height:1.5}
.da-dark-models{padding:40px 0 80px;text-align:center}
.da-dark-models h2{font-size:28px;font-weight:700;color:#E5E5E5;margin:0 0 24px}
.da-dark-tags{display:flex;flex-wrap:wrap;gap:8px;justify-content:center}
.da-dark-tag{padding:6px 14px;border-radius:6px;font-size:13px;font-weight:500;background:#1A1A1A;border:1px solid #2A2A2A;color:#999;transition:border-color 0.3s}
.da-dark-tag:hover{border-color:#D4A574;color:#D4A574}
@media(max-width:768px){
  .da-dark-hero h1{font-size:34px}
  .da-dark-hero .da-sub{font-size:16px}
  .da-dark-features{grid-template-columns:1fr}
}
</style>
<div class="da-dark-bg">
  <div class="da-dark-wrap">
    <div class="da-dark-hero">
      <h1>AI API Gateway</h1>
      <p class="da-sub">Unified interface to 40+ AI models. One API, endless possibilities.</p>
      <div class="da-dark-addr">
        <div class="da-label">Endpoint</div>
        <div class="da-url">https://api.develop.cc</div>
      </div>
      <div><a href="/token" class="da-dark-cta">Get Started</a></div>
    </div>
    <div class="da-dark-features">
      <div class="da-dark-card">
        <div class="da-icon">◆</div>
        <h3>Unified Interface</h3>
        <p>OpenAI-compatible API format. Connect to all major models through a single endpoint.</p>
      </div>
      <div class="da-dark-card">
        <div class="da-icon">◈</div>
        <h3>40+ Models</h3>
        <p>GPT-4o, Claude, Gemini, DeepSeek and more. Switch models with a single parameter change.</p>
      </div>
      <div class="da-dark-card">
        <div class="da-icon">◇</div>
        <h3>Enterprise Ready</h3>
        <p>Key isolation, rate limiting, usage tracking, and high-availability architecture built in.</p>
      </div>
    </div>
    <div class="da-dark-models">
      <h2>Supported Models</h2>
      <div class="da-dark-tags">
        <span class="da-dark-tag">GPT-4o</span>
        <span class="da-dark-tag">GPT-4o-mini</span>
        <span class="da-dark-tag">o1</span>
        <span class="da-dark-tag">o3-mini</span>
        <span class="da-dark-tag">Claude 3.5 Sonnet</span>
        <span class="da-dark-tag">Claude 3 Opus</span>
        <span class="da-dark-tag">Claude 3 Haiku</span>
        <span class="da-dark-tag">Gemini 2.0</span>
        <span class="da-dark-tag">Gemini 1.5 Pro</span>
        <span class="da-dark-tag">DeepSeek V3</span>
        <span class="da-dark-tag">DeepSeek R1</span>
        <span class="da-dark-tag">Llama 3</span>
        <span class="da-dark-tag">Mistral</span>
        <span class="da-dark-tag">More...</span>
      </div>
    </div>
  </div>
</div>
HTMLEOF
    cat <<'HTMLEOF' | set_option "Footer"
<style>.custom-footer + div { display: none !important; } body,body[theme-mode],body[theme-mode="dark"]{--semi-color-text-0:#E5E5E5;--semi-color-text-1:#999;--semi-color-text-2:#666;--semi-color-primary:#D4A574;--semi-color-primary-hover:#C9956B;--semi-color-fill-0:#1A1A1A;--semi-color-fill-1:#222;--semi-color-fill-2:#2A2A2A;--semi-color-bg-0:#0A0A0A;--semi-color-bg-1:#111;--semi-color-bg-2:#1A1A1A;--semi-color-primary-light-default:rgba(212,165,116,0.15);--semi-color-bg-overlay:#111;--semi-color-border:#2A2A2A} header.sticky{background-color:rgba(10,10,10,0.85)!important;border-bottom:1px solid #2A2A2A!important}
/* ===== /pricing 页面深色适配 ===== */
/* 注：:has() 需要 Chrome 105+ / Firefox 121+ / Safari 15.4+，覆盖所有主流现代浏览器 */
.bg-white:has(.pricing-layout){background:#0A0A0A!important}
.pricing-layout .text-gray-900,.pricing-search-header .text-gray-900{color:#E5E5E5!important}
.pricing-layout .text-gray-800,.pricing-search-header .text-gray-800{color:#D4D4D4!important}
.pricing-layout .text-gray-700,.pricing-search-header .text-gray-700{color:#BABABA!important}
.pricing-layout .text-gray-600,.pricing-search-header .text-gray-600{color:#999!important}
.pricing-layout .text-gray-500,.pricing-search-header .text-gray-500{color:#888!important}
.pricing-layout .border-gray-200,.pricing-layout .border-gray-300{border-color:#2A2A2A!important}
.pricing-layout .border-blue-500{border-color:#D4A574!important}
.pricing-layout .bg-blue-50{background:rgba(212,165,116,0.1)!important}</style>
<div style="text-align:center;padding:20px 0;font-family:Inter,-apple-system,sans-serif;color:#888;font-size:13px;border-top:1px solid rgba(212,165,116,0.3);background:#0A0A0A;">
  <span>© 2025–2026 <a href="https://develop.cc" target="_blank" style="color:#D4A574;text-decoration:none;">BitFactor LLC</a></span>
</div>
HTMLEOF
    cat <<'HTMLEOF' | set_option "About"
<div style="background:#0A0A0A;min-height:calc(100vh - 120px);min-height:calc(100dvh - 120px);margin:0 -0.5rem;padding:0 0.5rem;">
  <div style="max-width:680px;margin:0 auto;font-family:Inter,-apple-system,sans-serif;color:#E5E5E5;line-height:1.6;padding:40px 20px;">
    <h2 style="font-size:32px;font-weight:700;margin:0 0 16px;background:linear-gradient(135deg,#D4A574,#C9956B);-webkit-background-clip:text;-webkit-text-fill-color:transparent;background-clip:text;color:transparent;">Develop API</h2>
    <p style="font-size:17px;color:#888;margin:0 0 32px;">AI API Gateway · Powered by BitFactor LLC</p>
    <div style="background:#111;border:1px solid #2A2A2A;border-radius:10px;padding:24px;margin-bottom:20px;">
      <h3 style="font-size:17px;font-weight:600;color:#E5E5E5;margin:0 0 12px;">About Us</h3>
      <p style="font-size:15px;color:#999;margin:0;line-height:1.6;">Develop API is an AI API aggregation gateway operated by BitFactor LLC. We provide a unified OpenAI-compatible interface to 40+ mainstream AI models, enabling developers to rapidly integrate AI capabilities into their applications.</p>
    </div>
    <div style="background:#111;border:1px solid #2A2A2A;border-radius:10px;padding:24px;">
      <h3 style="font-size:17px;font-weight:600;color:#E5E5E5;margin:0 0 12px;">Contact</h3>
      <p style="font-size:15px;color:#999;margin:0;">Website: <a href="https://develop.cc" target="_blank" style="color:#D4A574;text-decoration:none;">develop.cc</a></p>
    </div>
  </div>
</div>
HTMLEOF
    trap - EXIT INT TERM
    _template_cleanup
    echo ""
    echo "✅ 深色高雅风模板应用完成！请刷新浏览器查看效果。"
    echo ""
    echo "提示：如需生产环境使用 Logo，请执行 cd web && bun run build 重新构建前端，"
    echo "      或将 Logo 选项改为外部图片 URL。"
}

# template-light: 应用苹果简约风主题模板
cmd_template_light() {
    _load_template_config
    _TEMPLATE_TMPFILES=()
    trap _template_cleanup EXIT INT TERM
    echo "☀️  正在应用 [苹果简约风] 模板..."
    echo "   服务器: $SERVER"
    echo ""
    echo "Develop API"            | set_option "SystemName"
    echo "/logo-apple.svg"        | set_option "Logo"
    echo "https://api.develop.cc" | set_option "ServerAddress"
    cat <<'HTMLEOF' | set_option "HomePageContent"
<style>
.al-bg{background:#FBFBFD;min-height:calc(100vh - 60px);min-height:calc(100dvh - 60px);width:100%}
.al-wrap{font-family:-apple-system,BlinkMacSystemFont,'SF Pro Display','SF Pro Text','Helvetica Neue',Arial,sans-serif;color:#1D1D1F;max-width:960px;margin:0 auto;padding:0 20px}
.al-hero{text-align:center;padding:88px 0 72px;position:relative}
.al-hero::before{content:'';position:absolute;top:0;left:50%;transform:translateX(-50%);width:800px;height:480px;background:radial-gradient(ellipse at 50% 0%,rgba(0,113,227,0.06) 0%,transparent 65%);pointer-events:none}
.al-hero h1{font-size:56px;font-weight:700;letter-spacing:-0.03em;line-height:1.07;margin:0;color:#1D1D1F;position:relative}
.al-hero .al-sub{font-size:21px;font-weight:400;color:#6E6E73;margin:12px auto 0;line-height:1.4;max-width:520px;position:relative}
.al-endpoint{margin-top:36px;background:#FFFFFF;border-radius:14px;padding:16px 28px;display:inline-block;box-shadow:0 2px 20px rgba(0,0,0,0.08),0 0 0 1px rgba(0,0,0,0.04);position:relative}
.al-endpoint .al-label{color:#86868B;font-size:11px;text-transform:uppercase;letter-spacing:0.06em;font-weight:500}
.al-endpoint .al-url{font-size:17px;font-weight:600;color:#0071E3;margin-top:4px;font-family:'SF Mono',SFMono-Regular,Menlo,Courier,monospace}
.al-cta{display:inline-block;background:#0071E3;color:#FFFFFF;padding:13px 28px;border-radius:980px;font-size:17px;font-weight:400;text-decoration:none;margin-top:28px;transition:background 0.2s;position:relative;letter-spacing:-0.01em}
.al-cta:hover{background:#0077ED;color:#FFFFFF}
.al-features-wrap{background:#F5F5F7;padding:64px 20px}
.al-features{display:grid;grid-template-columns:repeat(3,1fr);gap:14px;max-width:960px;margin:0 auto}
.al-card{background:#FFFFFF;border-radius:18px;padding:32px 28px;box-shadow:0 2px 12px rgba(0,0,0,0.05)}
.al-card .al-icon{width:44px;height:44px;border-radius:10px;background:#E5F0FF;display:flex;align-items:center;justify-content:center;margin-bottom:20px;font-size:20px;color:#0071E3}
.al-card h3{font-size:17px;font-weight:600;color:#1D1D1F;margin:0 0 8px;letter-spacing:-0.01em}
.al-card p{font-size:14px;color:#6E6E73;margin:0;line-height:1.6}
.al-models{padding:64px 0 88px;text-align:center}
.al-models h2{font-size:32px;font-weight:700;color:#1D1D1F;margin:0 0 28px;letter-spacing:-0.02em}
.al-tags{display:flex;flex-wrap:wrap;gap:8px;justify-content:center}
.al-tag{padding:7px 16px;border-radius:980px;font-size:13px;font-weight:400;background:#F5F5F7;color:#1D1D1F;transition:background 0.2s,color 0.2s;letter-spacing:-0.01em}
.al-tag:hover{background:#E5F0FF;color:#0071E3}
@media(max-width:768px){
  .al-hero h1{font-size:36px}
  .al-hero .al-sub{font-size:17px}
  .al-features{grid-template-columns:1fr}
}
</style>
<div class="al-bg">
  <div class="al-wrap">
    <div class="al-hero">
      <h1>AI API Gateway</h1>
      <p class="al-sub">Unified interface to 40+ AI models. One API, endless possibilities.</p>
      <div class="al-endpoint">
        <div class="al-label">Endpoint</div>
        <div class="al-url">https://api.develop.cc</div>
      </div>
      <div><a href="/token" class="al-cta">Get Started</a></div>
    </div>
  </div>
  <div class="al-features-wrap">
    <div class="al-features">
      <div class="al-card">
        <div class="al-icon">◆</div>
        <h3>Unified Interface</h3>
        <p>OpenAI-compatible API format. Connect to all major models through a single endpoint.</p>
      </div>
      <div class="al-card">
        <div class="al-icon">◈</div>
        <h3>40+ Models</h3>
        <p>GPT-4o, Claude, Gemini, DeepSeek and more. Switch models with a single parameter change.</p>
      </div>
      <div class="al-card">
        <div class="al-icon">◇</div>
        <h3>Enterprise Ready</h3>
        <p>Key isolation, rate limiting, usage tracking, and high-availability architecture built in.</p>
      </div>
    </div>
  </div>
  <div class="al-wrap">
    <div class="al-models">
      <h2>Supported Models</h2>
      <div class="al-tags">
        <span class="al-tag">GPT-4o</span>
        <span class="al-tag">GPT-4o-mini</span>
        <span class="al-tag">o1</span>
        <span class="al-tag">o3-mini</span>
        <span class="al-tag">Claude 3.5 Sonnet</span>
        <span class="al-tag">Claude 3 Opus</span>
        <span class="al-tag">Claude 3 Haiku</span>
        <span class="al-tag">Gemini 2.0</span>
        <span class="al-tag">Gemini 1.5 Pro</span>
        <span class="al-tag">DeepSeek V3</span>
        <span class="al-tag">DeepSeek R1</span>
        <span class="al-tag">Llama 3</span>
        <span class="al-tag">Mistral</span>
        <span class="al-tag">More...</span>
      </div>
    </div>
  </div>
</div>
HTMLEOF
    cat <<'HTMLEOF' | set_option "Footer"
<style>.custom-footer + div { display: none !important; } body,body[theme-mode],body[theme-mode="dark"],body[theme-mode="light"]{--semi-color-text-0:#1D1D1F;--semi-color-text-1:#6E6E73;--semi-color-text-2:#86868B;--semi-color-primary:#0071E3;--semi-color-primary-hover:#0077ED;--semi-color-fill-0:#F5F5F7;--semi-color-fill-1:#EBEBEB;--semi-color-fill-2:#E0E0E0;--semi-color-bg-0:#FFFFFF;--semi-color-bg-1:#F5F5F7;--semi-color-bg-2:#EBEBEB;--semi-color-primary-light-default:rgba(0,113,227,0.1);--semi-color-bg-overlay:#FFFFFF;--semi-color-border:#D2D2D7} header.sticky{background-color:rgba(255,255,255,0.85)!important;backdrop-filter:saturate(180%) blur(20px)!important;-webkit-backdrop-filter:saturate(180%) blur(20px)!important;border-bottom:1px solid rgba(0,0,0,0.08)!important}</style>
<div style="text-align:center;padding:20px 0;font-family:-apple-system,BlinkMacSystemFont,sans-serif;color:#86868B;font-size:13px;border-top:1px solid #D2D2D7;background:#FBFBFD;">
  <span>© 2025–2026 <a href="https://develop.cc" target="_blank" style="color:#0071E3;text-decoration:none;">BitFactor LLC</a></span>
</div>
HTMLEOF
    cat <<'HTMLEOF' | set_option "About"
<div style="background:#FBFBFD;min-height:calc(100vh - 120px);min-height:calc(100dvh - 120px);margin:0 -0.5rem;padding:0 0.5rem;">
  <div style="max-width:680px;margin:0 auto;font-family:-apple-system,BlinkMacSystemFont,'SF Pro Text','Helvetica Neue',Arial,sans-serif;color:#1D1D1F;line-height:1.6;padding:56px 20px;">
    <h2 style="font-size:36px;font-weight:700;margin:0 0 8px;color:#1D1D1F;letter-spacing:-0.025em;">Develop API</h2>
    <p style="font-size:17px;color:#6E6E73;margin:0 0 40px;font-weight:400;">AI API Gateway · Powered by BitFactor LLC</p>
    <div style="background:#FFFFFF;border-radius:18px;padding:28px;margin-bottom:14px;box-shadow:0 2px 12px rgba(0,0,0,0.05);">
      <h3 style="font-size:17px;font-weight:600;color:#1D1D1F;margin:0 0 10px;letter-spacing:-0.01em;">About Us</h3>
      <p style="font-size:15px;color:#6E6E73;margin:0;line-height:1.6;">Develop API is an AI API aggregation gateway operated by BitFactor LLC. We provide a unified OpenAI-compatible interface to 40+ mainstream AI models, enabling developers to rapidly integrate AI capabilities into their applications.</p>
    </div>
    <div style="background:#FFFFFF;border-radius:18px;padding:28px;box-shadow:0 2px 12px rgba(0,0,0,0.05);">
      <h3 style="font-size:17px;font-weight:600;color:#1D1D1F;margin:0 0 10px;letter-spacing:-0.01em;">Contact</h3>
      <p style="font-size:15px;color:#6E6E73;margin:0;">Website: <a href="https://develop.cc" target="_blank" style="color:#0071E3;text-decoration:none;">develop.cc</a></p>
    </div>
  </div>
</div>
HTMLEOF
    trap - EXIT INT TERM
    _template_cleanup
    echo ""
    echo "✅ 苹果简约风模板应用完成！请刷新浏览器查看效果。"
    echo ""
    echo "提示：如需生产环境使用 Logo，请执行 cd web && bun run build 重新构建前端，"
    echo "      或将 Logo 选项改为外部图片 URL。"
}

# ===== Backup 子命令（数据库备份到 Cloudflare R2）=====

# 幂等写入单个 .env 变量（已存在则替换，否则追加）
_backup_env_write() {
    local var="$1" val="$2"
    local env_file="$PROJECT_DIR/.env"
    touch "$env_file" 2>/dev/null || true
    if awk -v k="$var" 'index($0, k "=") == 1 {found=1; exit} END{exit !found}' "$env_file" 2>/dev/null; then
        local _tmp
        _tmp="$(mktemp)" && chmod 600 "$_tmp" \
            && _BACKUP_AWK_VAL="$val" awk -v k="$var" \
                'BEGIN{pat="^" k "="} $0 ~ pat { print k "=" ENVIRON["_BACKUP_AWK_VAL"]; next } { print }' \
                "$env_file" > "$_tmp" \
            && unset _BACKUP_AWK_VAL && mv "$_tmp" "$env_file" || { unset _BACKUP_AWK_VAL; rm -f "$_tmp"; return 1; }
    else
        printf '%s=%s\n' "$var" "$val" >> "$env_file" || return 1
    fi
}

# 从 .env 读取单个变量值，不存在时返回第二个参数指定的默认值
_backup_get_env() {
    local var="$1" default="${2:-}"
    local env_file="$PROJECT_DIR/.env"
    local val
    val="$(awk -v k="$var" 'index($0, k "=") == 1 {val=substr($0, length(k)+2)} END{printf "%s", val}' "$env_file" 2>/dev/null)" || true
    if [ -n "$val" ]; then
        printf '%s' "$val"
    else
        printf '%s' "$default"
    fi
}

# 检查 R2 配置是否完整，缺失时打印提示并返回非零
backup_check_config() {
    local env_file="$PROJECT_DIR/.env"
    local var missing=""
    for var in R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET; do
        if ! grep -qE "^${var}=.+" "$env_file" 2>/dev/null; then
            missing="${missing} ${var}"
        fi
    done
    if [ -n "$missing" ]; then
        error "R2 配置不完整，缺少:${missing}"
        info "请先运行: $0 backup setup"
        return 1
    fi
}

# 交互式配置 R2 凭据，写入 .env（幂等）
backup_setup() {
    title "配置 Cloudflare R2 备份"
    echo ""
    echo "所需凭据可在 Cloudflare 控制台 → R2 → 管理 API 令牌 中获取。"
    echo ""

    local account_id access_key secret_key bucket backup_dir keep
    local cur_id cur_key cur_bucket cur_dir cur_keep

    cur_id="$(_backup_get_env R2_ACCOUNT_ID)"
    cur_key="$(_backup_get_env R2_ACCESS_KEY_ID)"
    cur_bucket="$(_backup_get_env R2_BUCKET)"
    cur_dir="$(_backup_get_env R2_BACKUP_DIR "new-api-backups")"
    cur_keep="$(_backup_get_env R2_BACKUP_KEEP "7")"

    local prompt_id="Cloudflare Account ID"
    [ -n "$cur_id" ] && prompt_id="${prompt_id} [${cur_id}]"
    read -r -p "${prompt_id}: " account_id || true
    account_id="${account_id:-$cur_id}"

    local prompt_key="R2 Access Key ID"
    [ -n "$cur_key" ] && prompt_key="${prompt_key} [${cur_key}]"
    read -r -p "${prompt_key}: " access_key || true
    access_key="${access_key:-$cur_key}"

    read -r -s -p "R2 Secret Access Key（输入不显示，留空保留现有）: " secret_key || true
    echo ""
    if [ -z "$secret_key" ]; then
        secret_key="$(_backup_get_env R2_SECRET_ACCESS_KEY)"
    fi

    local prompt_bucket="R2 Bucket 名称"
    [ -n "$cur_bucket" ] && prompt_bucket="${prompt_bucket} [${cur_bucket}]"
    read -r -p "${prompt_bucket}: " bucket || true
    bucket="${bucket:-$cur_bucket}"

    read -r -p "备份目录（桶内路径，默认 ${cur_dir}）: " backup_dir || true
    backup_dir="${backup_dir:-$cur_dir}"

    read -r -p "保留备份数量（默认 ${cur_keep}）: " keep || true
    keep="${keep:-$cur_keep}"
    # 校验保留数量为正整数（W1）
    if ! printf '%s' "$keep" | grep -qE '^[1-9][0-9]*$'; then
        warn "保留数量必须为正整数，已重置为 7"
        keep=7
    fi

    if [ -z "$account_id" ] || [ -z "$access_key" ] || [ -z "$secret_key" ] || [ -z "$bucket" ]; then
        error "Account ID、Access Key ID、Secret Key、Bucket 均为必填项"
        return 1
    fi

    _backup_env_write "R2_ACCOUNT_ID"        "$account_id" || warn "写入 R2_ACCOUNT_ID 失败"
    _backup_env_write "R2_ACCESS_KEY_ID"     "$access_key" || warn "写入 R2_ACCESS_KEY_ID 失败"
    _backup_env_write "R2_SECRET_ACCESS_KEY" "$secret_key" || warn "写入 R2_SECRET_ACCESS_KEY 失败"
    _backup_env_write "R2_BUCKET"            "$bucket"     || warn "写入 R2_BUCKET 失败"
    _backup_env_write "R2_BACKUP_DIR"        "$backup_dir" || warn "写入 R2_BACKUP_DIR 失败"
    _backup_env_write "R2_BACKUP_KEEP"       "$keep"       || warn "写入 R2_BACKUP_KEEP 失败"

    echo ""
    info "R2 配置已写入 .env"
    echo "  Account ID : $account_id"
    echo "  Access Key : $access_key"
    echo "  Bucket     : ${bucket}/${backup_dir}"
    echo "  保留数量   : ${keep} 个"
}

# 执行数据库 dump，结果文件路径写入全局变量 _BACKUP_DUMP_FILE
# 临时目录路径写入 _BACKUP_DUMP_TMP_DIR（调用方负责清理）
backup_dump() {
    local timestamp
    timestamp="$(date +%Y%m%d_%H%M%S)"
    local tmp_dir
    tmp_dir="$(mktemp -d)"

    local sql_dsn
    sql_dsn="$(_backup_get_env SQL_DSN)"
    local db_type
    if printf '%s' "$sql_dsn" | grep -qi "mysql"; then
        db_type="mysql"
    elif printf '%s' "$sql_dsn" | grep -qi "postgres"; then
        db_type="postgres"
    else
        db_type="sqlite"
    fi

    local dump_file
    case "$db_type" in
        sqlite)
            local sqlite_path
            sqlite_path="$(_backup_get_env SQLITE_PATH "$PROJECT_DIR/new-api.db")"
            dump_file="${tmp_dir}/new-api_${timestamp}.db"
            if [ ! -f "$sqlite_path" ]; then
                error "SQLite 数据库文件不存在: $sqlite_path"
                rm -rf "$tmp_dir"
                return 1
            fi
            info "备份 SQLite: $sqlite_path"
            # 优先使用 sqlite3 .backup（在线热备份，保证一致性）；B2
            if command -v sqlite3 >/dev/null 2>&1; then
                sqlite3 "$sqlite_path" ".backup '${dump_file}'" \
                    || { rm -rf "$tmp_dir"; return 1; }
            else
                warn "未找到 sqlite3，使用 cp 复制（运行中写入可能导致备份不一致）"
                cp "$sqlite_path" "$dump_file" || { rm -rf "$tmp_dir"; return 1; }
            fi
            ;;
        mysql)
            if ! command -v mysqldump >/dev/null 2>&1; then
                error "未找到 mysqldump，请先安装 MySQL 客户端工具"
                rm -rf "$tmp_dir"
                return 1
            fi
            dump_file="${tmp_dir}/new-api_${timestamp}.sql.gz"
            info "备份 MySQL..."
            # GORM DSN 格式: user:pass@tcp(host:port)/dbname?opts
            # 以 @tcp( 为凭据与主机的分隔点，支持密码中含 @ 或 : 的情况
            local db_user db_pass db_host db_port db_name _creds _host_port
            _creds="$(     printf '%s' "$sql_dsn" | sed 's/@tcp(.*//')"
            db_user="$(    printf '%s' "$_creds"   | cut -d: -f1)"
            db_pass="$(    printf '%s' "$_creds"   | cut -d: -f2-)"
            _host_port="$( printf '%s' "$sql_dsn" | sed 's/.*@tcp(//;s/).*//')"
            # 用最后一个冒号分隔 host 与 port，兼容 IPv6 地址（如 [::1]:3306）
            if printf '%s' "$_host_port" | grep -qE ':[0-9]+$'; then
                db_host="$(printf '%s' "$_host_port" | sed 's/:[0-9]*$//')"
                db_port="$(printf '%s' "$_host_port" | sed 's/.*://')"
            else
                db_host="$_host_port"
                db_port=""
            fi
            db_name="$(    printf '%s' "$sql_dsn" | sed 's/.*@tcp([^)]*)\///;s/?.*//')"
            ( set -o pipefail
              MYSQL_PWD="$db_pass" mysqldump \
                  -u "$db_user" -h "$db_host" -P "${db_port:-3306}" "$db_name" \
                  | gzip
            ) > "$dump_file" || { rm -rf "$tmp_dir"; return 1; }
            ;;
        postgres)
            if ! command -v pg_dump >/dev/null 2>&1; then
                error "未找到 pg_dump，请先安装 PostgreSQL 客户端工具"
                rm -rf "$tmp_dir"
                return 1
            fi
            dump_file="${tmp_dir}/new-api_${timestamp}.sql.gz"
            info "备份 PostgreSQL..."
            # pg_dump 仅接受 URI 格式；GORM 也支持 key-value 格式，需转换（B3）
            local pg_dsn="$sql_dsn"
            if ! printf '%s' "$sql_dsn" | grep -qE '^postgres(ql)?://'; then
                # key-value 格式：host=h user=u password=p dbname=d port=p
                # 用 POSIX grep -o 避免 macOS 不支持 grep -oP 的问题（B1）
                local pg_h pg_u pg_p pg_d pg_port
                pg_h="$(    printf '%s' "$sql_dsn" | grep -o 'host=[^ ]*'     | cut -d= -f2)"
                pg_u="$(    printf '%s' "$sql_dsn" | grep -o 'user=[^ ]*'     | cut -d= -f2)"
                pg_p="$(    printf '%s' "$sql_dsn" | grep -o 'password=[^ ]*' | cut -d= -f2)"
                pg_d="$(    printf '%s' "$sql_dsn" | grep -o 'dbname=[^ ]*'   | cut -d= -f2)"
                pg_port="$( printf '%s' "$sql_dsn" | grep -o 'port=[^ ]*'     | cut -d= -f2)"
                pg_dsn="postgresql://${pg_u}:${pg_p}@${pg_h}:${pg_port:-5432}/${pg_d}"
            fi
            ( set -o pipefail
              pg_dump "$pg_dsn" | gzip
            ) > "$dump_file" || { rm -rf "$tmp_dir"; return 1; }
            ;;
    esac

    local size
    size="$(du -sh "$dump_file" 2>/dev/null | cut -f1)"
    info "Dump 完成: $(basename "$dump_file")（${size}）"
    _BACKUP_DUMP_FILE="$dump_file"
    _BACKUP_DUMP_TMP_DIR="$tmp_dir"
}

# aws s3 封装：通过环境变量传递 R2 凭据，避免凭据出现在 ps aux 进程列表中
# --endpoint-url 为非敏感配置，直接作为 CLI flag 传入
# 用法: _aws_r2 <access_key> <secret_key> <endpoint> <aws s3 子命令及参数...>
_aws_r2() {
    local _ak="$1" _sk="$2" _ep="$3"
    shift 3
    AWS_ACCESS_KEY_ID="$_ak" \
    AWS_SECRET_ACCESS_KEY="$_sk" \
    AWS_DEFAULT_REGION=auto \
    aws s3 --endpoint-url "$_ep" "$@"
}

# 上传 dump 文件到 R2，并清理旧备份（只保留最近 N 个）
backup_upload() {
    local dump_file="$1"

    if ! command -v aws >/dev/null 2>&1; then
        error "未找到 aws cli，请先安装: https://aws.amazon.com/cli/"
        return 1
    fi

    local account_id access_key secret_key bucket backup_dir keep
    account_id="$(_backup_get_env R2_ACCOUNT_ID)"
    access_key="$(_backup_get_env R2_ACCESS_KEY_ID)"
    secret_key="$(_backup_get_env R2_SECRET_ACCESS_KEY)"
    bucket="$(_backup_get_env R2_BUCKET)"
    backup_dir="$(_backup_get_env R2_BACKUP_DIR "new-api-backups")"
    keep="$(_backup_get_env R2_BACKUP_KEEP "7")"
    # 防止 .env 被手动改为非数字导致算术崩溃（B2）
    if ! printf '%s' "$keep" | grep -qE '^[1-9][0-9]*$'; then
        warn "R2_BACKUP_KEEP 值无效（$keep），使用默认值 7"
        keep=7
    fi

    local endpoint="https://${account_id}.r2.cloudflarestorage.com"
    local r2_path="${bucket}/${backup_dir}"

    info "上传到 R2: ${r2_path}/$(basename "$dump_file")"
    _aws_r2 "$access_key" "$secret_key" "$endpoint" \
        cp "$dump_file" "s3://${r2_path}/$(basename "$dump_file")" \
        || { error "上传失败，请检查 R2 配置和网络连接"; return 1; }
    info "上传成功"

    # 列出远端文件（按文件名排序），清理超出保留数量的旧备份
    info "检查旧备份（最多保留 ${keep} 个）..."
    # 先捕获 aws 退出码再提取文件名，避免管道吞掉错误（同 backup_list 的修复）
    # aws s3 ls 输出格式：date time size filename，取最后一列得到文件名
    local file_list_raw file_list=""
    if ! file_list_raw="$(_aws_r2 "$access_key" "$secret_key" "$endpoint" \
            ls "s3://${r2_path}/" 2>/dev/null)"; then
        warn "列出远端文件失败，跳过旧备份清理"
        return 0
    fi
    [ -n "$file_list_raw" ] && file_list="$(printf '%s\n' "$file_list_raw" | awk '{print $NF}' | sort)"

    local total=0
    if [ -n "$file_list" ]; then
        total="$(printf '%s\n' "$file_list" | grep -c .)" || total=0
    fi
    local to_delete=$(( total - keep ))

    if [ "$to_delete" -gt 0 ]; then
        local old_files deleted=0
        old_files="$(printf '%s\n' "$file_list" | head -n "$to_delete")"
        while IFS= read -r f; do
            [ -z "$f" ] && continue
            _aws_r2 "$access_key" "$secret_key" "$endpoint" \
                rm "s3://${r2_path}/${f}" 2>/dev/null \
                && { info "已删除旧备份: $f"; deleted=$(( deleted + 1 )); } \
                || warn "删除失败: $f"
        done <<EOF
$old_files
EOF
        info "清理完成，共删除 ${deleted} 个旧备份"
    else
        info "当前共 ${total} 个备份，无需清理"
    fi
}

# 列出 R2 上的备份文件
backup_list() {
    backup_check_config || return 1

    if ! command -v aws >/dev/null 2>&1; then
        error "未找到 aws cli，请先安装: https://aws.amazon.com/cli/"
        return 1
    fi

    local account_id access_key secret_key bucket backup_dir
    account_id="$(_backup_get_env R2_ACCOUNT_ID)"
    access_key="$(_backup_get_env R2_ACCESS_KEY_ID)"
    secret_key="$(_backup_get_env R2_SECRET_ACCESS_KEY)"
    bucket="$(_backup_get_env R2_BUCKET)"
    backup_dir="$(_backup_get_env R2_BACKUP_DIR "new-api-backups")"

    local endpoint="https://${account_id}.r2.cloudflarestorage.com"

    title "R2 备份列表（${bucket}/${backup_dir}）"
    # 先捕获 aws 退出码，再交给 sort，避免管道吞掉错误
    # aws s3 ls 输出格式：date time size filename，sort -k4 按文件名排序
    local list_output
    list_output="$(_aws_r2 "$access_key" "$secret_key" "$endpoint" \
        ls "s3://${bucket}/${backup_dir}/" 2>&1)" \
        || { error "列出备份失败，请检查 R2 配置"; return 1; }
    printf '%s\n' "$list_output" | sort -k4
}

# 配置定时备份 cron（仅 Linux）
# 运行时间：每天 19:00 UTC = 北京时间 03:00
backup_cron() {
    if [ "$OS_TYPE" != "linux" ]; then
        warn "定时备份（cron）仅支持 Linux 系统，当前系统（$OS_TYPE）不支持自动配置"
        return 0
    fi

    local script_path="$PROJECT_DIR/scripts/setup.sh"
    local cron_marker="setup.sh backup"
    local cron_line="0 19 * * * cd \"$PROJECT_DIR\" && \"$script_path\" backup >> \"$PROJECT_DIR/backup.log\" 2>&1"
    local already_installed=false

    if crontab -l 2>/dev/null | grep -qF "$cron_marker"; then
        already_installed=true
    fi

    # 显示当前状态并询问操作
    echo ""
    if [ "$already_installed" = "true" ]; then
        info "定时备份当前状态：已安装"
        echo ""
        crontab -l 2>/dev/null | grep "$cron_marker"
        echo ""
        echo "请选择操作："
        echo "  1) 卸载定时任务"
        echo "  2) 取消（保持不变）"
        echo ""
        read -r -p "请选择 [1-2]: " cron_choice || true
        case "${cron_choice:-2}" in
            1)
                # 删除含 marker 的行及其上方的注释行
                local new_crontab
                new_crontab="$(crontab -l 2>/dev/null \
                    | grep -v "new-api backup:" \
                    | grep -vF "$cron_marker")" || new_crontab=""
                # 检查过滤后是否还有有效内容（非空白行）；B4
                if printf '%s' "$new_crontab" | grep -q '[^[:space:]]'; then
                    printf '%s\n' "$new_crontab" | crontab - || { error "更新 crontab 失败"; return 1; }
                else
                    crontab -r 2>/dev/null || true
                fi
                info "定时备份已卸载"
                ;;
            *)
                info "已取消，crontab 未修改"
                ;;
        esac
    else
        info "定时备份当前状态：未安装"
        echo ""
        echo "将添加以下 cron 任务："
        echo "  $cron_line"
        echo "  执行时间：每天 19:00 UTC（北京时间 03:00）"
        echo "  日志文件：$PROJECT_DIR/backup.log"
        echo ""
        echo "请选择操作："
        echo "  1) 安装定时任务"
        echo "  2) 取消"
        echo ""
        read -r -p "请选择 [1-2]: " cron_choice || true
        case "${cron_choice:-2}" in
            1)
                local existing new_crontab
                existing="$(crontab -l 2>/dev/null || true)"
                if [ -n "$existing" ]; then
                    new_crontab="${existing}
# new-api backup: 每天 19:00 UTC（北京时间 03:00）
${cron_line}"
                else
                    new_crontab="# new-api backup: 每天 19:00 UTC（北京时间 03:00）
${cron_line}"
                fi
                printf '%s\n' "$new_crontab" | crontab - || { error "写入 crontab 失败"; return 1; }
                info "定时备份已安装"
                info "查看 crontab : crontab -l"
                ;;
            *)
                info "已取消，crontab 未修改"
                ;;
        esac
    fi
}

# backup 命令主入口
cmd_backup() {
    local subcmd="${2:-now}"
    case "$subcmd" in
        setup)
            backup_setup
            ;;
        cron)
            backup_cron
            ;;
        list)
            backup_list
            ;;
        now|"")
            backup_check_config || return 1
            title "执行数据库备份"
            _BACKUP_DUMP_FILE=""
            _BACKUP_DUMP_TMP_DIR=""
            backup_dump || return 1
            local _upload_ret=0
            backup_upload "$_BACKUP_DUMP_FILE" || _upload_ret=$?
            rm -rf "$_BACKUP_DUMP_TMP_DIR" 2>/dev/null || true
            [ "$_upload_ret" -eq 0 ] && info "备份完成" || return 1
            ;;
        *)
            error "未知 backup 子命令: $subcmd"
            echo "用法: $0 backup [setup|cron|list]"
            return 1
            ;;
    esac
}

# 显示交互式菜单
show_menu() {
    local choice
    echo ""
    echo -e "${BLUE}===== New API 维护脚本 =====${NC}"
    echo ""
    echo "  1) install        - 初始化项目、编译并启动"
    echo "  2) uninstall      - 卸载服务、清理所有产物"
    echo "  3) rebuild        - 重新编译并重启"
    echo "  4) pull           - 从上游同步更新"
    echo "  5) push           - 推送到远程仓库"
    echo "  6) status         - 查看服务状态"
    echo "  7) logs           - 查看服务日志"
    echo "  8) template-dark  - 应用深色高雅风模板"
    echo "  9) template-light - 应用苹果简约风模板"
    echo "  b) backup         - 备份数据库到 Cloudflare R2"
    echo "  0) 退出"
    echo ""
    read -r -p "请选择操作 [0-9/b]: " choice || true
    case "$choice" in
        1) cmd_install ;;
        2) cmd_uninstall ;;
        3) cmd_rebuild ;;
        4) cmd_pull ;;
        5) cmd_push ;;
        6) cmd_status ;;
        7) cmd_logs ;;
        8) cmd_template_dark ;;
        9) cmd_template_light ;;
        b|B) cmd_backup ;;
        0) info "再见！"; exit 0 ;;
        "") info "已取消"; exit 0 ;;
        *) error "无效选择: $choice"; exit 1 ;;
    esac
}

# 显示帮助信息
show_help() {
    echo "用法: $0 [命令]"
    echo ""
    echo "命令:"
    echo "  install         初始化项目、编译并启动服务"
    echo "  uninstall       卸载服务、删除所有 install 产物"
    echo "  rebuild         重新编译并重启服务"
    echo "  pull            从上游同步更新到 $BRANCH_NAME 分支"
    echo "  push            推送 $BRANCH_NAME 分支到 origin"
    echo "  status          查看服务状态"
    echo "  logs            查看服务日志"
    echo "  template-dark              应用深色高雅风主题模板"
    echo "  template-light             应用苹果简约风主题模板"
    echo "  backup [setup|cron|list]   备份数据库到 Cloudflare R2"
    echo "    backup setup               交互式配置 R2 凭据（写入 .env）"
    echo "    backup cron                配置 cron 定时任务（Linux，每天北京时间 03:00）"
    echo "    backup list                列出 R2 上已有的备份文件"
    echo "    backup                     立即执行一次备份"
    echo ""
    echo "不带参数运行时显示交互式菜单。"
}

# ===== 入口 =====
case "${1:-}" in
    install)        cmd_install ;;
    uninstall)      cmd_uninstall ;;
    rebuild)        cmd_rebuild ;;
    pull)           cmd_pull ;;
    push)           cmd_push ;;
    status)         cmd_status ;;
    logs)           cmd_logs ;;
    template-dark)  cmd_template_dark ;;
    template-light) cmd_template_light ;;
    backup)         cmd_backup "$@" ;;
    -h|--help)      show_help ;;
    "")             show_menu ;;
    *)
        error "未知命令: $1"
        echo ""
        show_help
        exit 1
        ;;
esac
