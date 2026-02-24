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
            go)  brew install go ;;
            bun) brew install oven-sh/bun/bun ;;
            git) brew install git ;;
        esac
    else
        case "$cmd" in
            git)
                if command -v apt-get &>/dev/null; then
                    sudo apt-get update && sudo apt-get install -y git
                elif command -v yum &>/dev/null; then
                    sudo yum install -y git
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
                esac
                local url="https://go.dev/dl/go${go_ver}.linux-${arch}.tar.gz"
                # 用子 shell 隔离 trap，避免 trap - 清除父 shell 中已有的全局 trap
                (
                    tmp_tar="/tmp/go.$$.tar.gz"
                    trap "rm -f '${tmp_tar}'" EXIT INT TERM
                    info "下载 Go ${go_ver}: ${url}"
                    curl -fsSL "$url" -o "$tmp_tar"
                    sudo rm -rf /usr/local/go
                    sudo tar -C /usr/local -xzf "$tmp_tar"
                ) || return 1
                export PATH="/usr/local/go/bin:$PATH"
                ;;
            bun)
                # 安全提示：以下命令从 bun.sh 下载并执行安装脚本。
                # 请确认信任该来源（https://bun.sh）后再继续。
                curl -fsSL https://bun.sh/install | bash
                export BUN_INSTALL="$HOME/.bun"
                export PATH="$BUN_INSTALL/bin:$PATH"
                ;;
        esac
    fi

    # 验证安装结果
    if ! command -v "$cmd" &>/dev/null; then
        error "$cmd 安装失败，请手动安装"
        return 1
    fi
    info "$cmd 安装完成: $(command -v "$cmd")"
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
After=network.target

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
        sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
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
start_service() {
    if [ "$OS_TYPE" = "linux" ]; then
        sudo systemctl restart "$SERVICE_NAME"
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
# 通过 /api/setup 创建初始管理员，登录后获取 Access Token 并保存到 config.json
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

    # 先打印凭据，确保即使 config.json 写入失败也不丢失
    _print_credentials "$PORT" "admin" "$ADMIN_PASS" "$ACCESS_TOKEN"

    if [ -z "$ACCESS_TOKEN" ]; then
        warn "获取 Access Token 失败，跳过凭据保存"
        return 0
    fi

    # 通过环境变量传递敏感信息，避免出现在 ps 命令输出中
    if NEW_API_SERVER="http://localhost:$PORT" \
       NEW_API_TOKEN="$ACCESS_TOKEN" \
       NEW_API_PASS="$ADMIN_PASS" \
       NEW_API_USER_ID="$USER_ID" \
       "$PY" -c "
import json, sys, os
config = {
    'server': os.environ['NEW_API_SERVER'],
    'token': os.environ['NEW_API_TOKEN'],
    'user_id': os.environ['NEW_API_USER_ID'],
    'username': 'admin',
    'password': os.environ['NEW_API_PASS']
}
with open(sys.argv[1], 'w') as f:
    json.dump(config, f, indent=2, ensure_ascii=False)
" "$SCRIPT_DIR/config.json"; then
        chmod 600 "$SCRIPT_DIR/config.json"
        info "凭据已保存到: $SCRIPT_DIR/config.json"
    else
        warn "config.json 写入失败，请手动记录上述凭据"
    fi
}

# ===== 命令实现 =====

# uninstall: 停止服务、删除所有 install 产物、清理 systemd 服务
# 保留源码文件（.env.example、go.mod、web/src/ 等）和 git 仓库
cmd_uninstall() {
    title "卸载 New API 服务"

    # 先确认，再停止服务（避免用户取消后服务已停）
    echo ""
    warn "即将删除以下内容:"
    echo "  - 数据库文件: $PROJECT_DIR/one-api.db, *-journal, *-wal, *-shm"
    echo "  - 环境配置:   $PROJECT_DIR/.env"
    echo "  - 二进制文件: $PROJECT_DIR/new-api"
    echo "  - 前端构建:   $PROJECT_DIR/web/dist/"
    echo "  - 日志目录:   $PROJECT_DIR/logs/"
    echo "  - 凭据文件:   $SCRIPT_DIR/config.json"
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

    # 删除数据库文件（统一引号风格）
    rm -f "$PROJECT_DIR/one-api.db" \
         "$PROJECT_DIR/one-api.db-journal" \
         "$PROJECT_DIR/one-api.db-wal" \
         "$PROJECT_DIR/one-api.db-shm"
    info "已删除数据库文件"

    # 删除环境配置
    rm -f "$PROJECT_DIR/.env"
    info "已删除 .env"

    # 删除二进制文件
    rm -f "$PROJECT_DIR/new-api"
    info "已删除二进制文件"

    # 删除前端构建产物
    rm -rf "$PROJECT_DIR/web/dist"
    info "已删除 web/dist/"

    # 删除日志目录
    rm -rf "$PROJECT_DIR/logs"
    info "已删除 logs/"

    # 删除凭据文件
    rm -f "$SCRIPT_DIR/config.json"
    info "已删除 config.json"

    # 清理 systemd 服务（仅 Linux）
    if [ "$OS_TYPE" = "linux" ] && [ -f "$SYSTEMD_PATH" ]; then
        sudo systemctl disable "$SERVICE_NAME" 2>/dev/null || true
        sudo rm -f "$SYSTEMD_PATH"
        sudo systemctl daemon-reload
        info "已清理 systemd 服务"
    fi

    title "卸载完成"
    info "所有 install 产物已清理"
    info "源码、git 仓库和 upstream remote 配置已保留"
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
                "$PROJECT_DIR/.env" > "$_tmp_env"
            mv "$_tmp_env" "$PROJECT_DIR/.env"
        else
            echo "SESSION_SECRET=${secret}" >> "$PROJECT_DIR/.env"
        fi
        info "已自动生成 SESSION_SECRET"
    else
        info "SESSION_SECRET 已配置"
    fi

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
        echo "$service_content" | sudo tee "$SYSTEMD_PATH" >/dev/null
        info "已写入 $SYSTEMD_PATH"
        sudo systemctl daemon-reload
        sudo systemctl enable "$SERVICE_NAME"
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
                    # 系统已初始化，检查是否有已保存的凭据
                    if [ -f "$SCRIPT_DIR/config.json" ]; then
                        info "系统已初始化，凭据文件已存在: $SCRIPT_DIR/config.json"
                    else
                        info "系统已初始化，跳过凭据初始化"
                        warn "如需管理凭据，请手动访问 http://localhost:$PORT"
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
    info "默认使用 SQLite 数据库，无需额外配置"
    info "如需 MySQL/PostgreSQL/Redis 等，请编辑 $PROJECT_DIR/.env"
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
        sudo systemctl status "$SERVICE_NAME" --no-pager || true
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
            info "启动命令: cd $PROJECT_DIR && ./new-api --port $PORT --log-dir ./logs"
        fi
    else
        error "不支持的系统: $OS_TYPE"
    fi
}

# logs: 查看服务日志
cmd_logs() {
    title "服务日志"
    local log_dir="$PROJECT_DIR/logs"
    if [ "$OS_TYPE" = "linux" ]; then
        sudo journalctl -u "$SERVICE_NAME" -f --no-pager -n 100
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

# 显示交互式菜单
show_menu() {
    local choice
    echo ""
    echo -e "${BLUE}===== New API 维护脚本 =====${NC}"
    echo ""
    echo "  1) install   - 初始化项目、编译并启动"
    echo "  2) uninstall - 卸载服务、清理所有产物"
    echo "  3) rebuild   - 重新编译并重启"
    echo "  4) pull      - 从上游同步更新"
    echo "  5) push      - 推送到远程仓库"
    echo "  6) status    - 查看服务状态"
    echo "  7) logs      - 查看服务日志"
    echo "  0) 退出"
    echo ""
    read -r -p "请选择操作 [0-7]: " choice || true
    case "$choice" in
        1) cmd_install ;;
        2) cmd_uninstall ;;
        3) cmd_rebuild ;;
        4) cmd_pull ;;
        5) cmd_push ;;
        6) cmd_status ;;
        7) cmd_logs ;;
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
    echo "  install     初始化项目、编译并启动服务"
    echo "  uninstall   卸载服务、删除所有 install 产物"
    echo "  rebuild     重新编译并重启服务"
    echo "  pull        从上游同步更新到 $BRANCH_NAME 分支"
    echo "  push        推送 $BRANCH_NAME 分支到 origin"
    echo "  status      查看服务状态"
    echo "  logs        查看服务日志"
    echo ""
    echo "不带参数运行时显示交互式菜单。"
}

# ===== 入口 =====
case "${1:-}" in
    install)   cmd_install ;;
    uninstall) cmd_uninstall ;;
    rebuild)   cmd_rebuild ;;
    pull)      cmd_pull ;;
    push)      cmd_push ;;
    status)    cmd_status ;;
    logs)      cmd_logs ;;
    -h|--help) show_help ;;
    "")      show_menu ;;
    *)
        error "未知命令: $1"
        echo ""
        show_help
        exit 1
        ;;
esac
