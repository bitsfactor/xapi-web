#!/bin/bash
# ============================================================
# New API 项目维护脚本
#
# 使用说明:
#   ./scripts/setup.sh              显示交互式菜单
#   ./scripts/setup.sh install      初始化项目、编译并启动服务
#   ./scripts/setup.sh rebuild      重新编译并重启服务
#   ./scripts/setup.sh pull         从上游同步更新到 xapi 分支
#   ./scripts/setup.sh push         推送 xapi 分支到 origin
#   ./scripts/setup.sh status       查看服务状态
#   ./scripts/setup.sh logs         查看服务日志
#
# 支持系统: Linux (systemd) / macOS (后台进程)
# 上游仓库: https://github.com/Calcium-Ion/new-api.git
# ============================================================
set -e

# ===== 配置变量 =====
SERVICE_NAME="new-api"
BRANCH_NAME="xapi"
UPSTREAM_URL="https://github.com/Calcium-Ion/new-api.git"
UPSTREAM_REMOTE="upstream"
PORT=3000
MODULE_PATH="github.com/QuantumNous/new-api"

# ===== 自动检测 =====
# 解析符号链接，确保通过 symlink 调用时也能正确定位项目目录
SCRIPT_PATH="$0"
while [ -L "$SCRIPT_PATH" ]; do
    SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
    LINK_TARGET="$(readlink "$SCRIPT_PATH")"
    # 处理相对路径的符号链接
    case "$LINK_TARGET" in
        /*) SCRIPT_PATH="$LINK_TARGET" ;;
        *)  SCRIPT_PATH="$SCRIPT_DIR/$LINK_TARGET" ;;
    esac
done
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BINARY_PATH="$PROJECT_DIR/$SERVICE_NAME"
OS_TYPE="$(uname -s | tr '[:upper:]' '[:lower:]')"
SYSTEMD_PATH="/etc/systemd/system/${SERVICE_NAME}.service"

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

# 比较两个语义化版本号，判断 $1 >= $2
# 参数: $1 = 实际版本, $2 = 最低要求版本
# 返回: 0 表示满足, 1 表示不满足
version_gte() {
    # 去掉前缀 v/go 等非数字字符
    local actual="${1#go}"
    actual="${actual#v}"
    local required="${2#go}"
    required="${required#v}"

    # 逐段比较 major.minor.patch
    local IFS='.'
    local -a a=($actual) r=($required)
    local i
    for i in 0 1 2; do
        # 去掉非数字后缀（如 "1-rc1" → "1"）
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
                info "下载 Go ${go_ver}: ${url}"
                curl -fsSL "$url" -o /tmp/go.tar.gz
                sudo rm -rf /usr/local/go
                sudo tar -C /usr/local -xzf /tmp/go.tar.gz
                rm -f /tmp/go.tar.gz
                export PATH="/usr/local/go/bin:$PATH"
                ;;
            bun)
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
        # 不使用 grep -P（busybox grep 不支持），改用兼容写法
        listen_pid="$(ss -tlnp "sport = :$port" 2>/dev/null | grep -o 'pid=[0-9]*' | head -1 | grep -o '[0-9]*' || true)"
    else
        warn "未找到 lsof 或 ss 命令，跳过端口检查"
        return 0
    fi

    # 端口未被占用
    if [ -z "$listen_pid" ]; then
        info "端口 $port 可用"
        return 0
    fi

    # 端口被占用，检查是否为自身服务进程
    local listen_cmd
    listen_cmd="$(ps -p "$listen_pid" -o comm= 2>/dev/null || echo '')"
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
        info "编译前端 (版本: $version)..."
        DISABLE_ESLINT_PLUGIN='true' VITE_REACT_APP_VERSION="$version" bun run build
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
    local version
    version="$(get_version)"
    (
        cd "$PROJECT_DIR"
        info "编译后端 (版本: $version)..."
        go build -ldflags "-s -w -X '${MODULE_PATH}/common.Version=${version}'" -o "$SERVICE_NAME"
    ) || {
        error "后端构建失败"
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
ExecStart=${BINARY_PATH} --port ${PORT} --log-dir ${PROJECT_DIR}/logs
Restart=always
RestartSec=5
EnvironmentFile=-${PROJECT_DIR}/.env

[Install]
WantedBy=multi-user.target
EOF
}

# 停止服务
stop_service() {
    if [ "$OS_TYPE" = "linux" ]; then
        sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    elif [ "$OS_TYPE" = "darwin" ]; then
        local pid
        pid="$(pgrep -x "${SERVICE_NAME}" 2>/dev/null | head -1 || true)"
        if [ -n "$pid" ]; then
            kill "$pid" 2>/dev/null || true
            # 等待进程退出，最多 5 秒
            local i=0
            while [ $i -lt 10 ] && kill -0 "$pid" 2>/dev/null; do
                sleep 0.5
                i=$((i + 1))
            done
            if kill -0 "$pid" 2>/dev/null; then
                warn "进程未响应 SIGTERM，发送 SIGKILL"
                kill -9 "$pid" 2>/dev/null || true
            fi
        fi
    fi
}

# 启动服务
start_service() {
    if [ "$OS_TYPE" = "linux" ]; then
        sudo systemctl restart "$SERVICE_NAME"
    elif [ "$OS_TYPE" = "darwin" ]; then
        mkdir -p "$PROJECT_DIR/logs"
        # 后台启动，日志输出到 logs 目录
        nohup "$BINARY_PATH" --port "$PORT" --log-dir "$PROJECT_DIR/logs" \
            >> "$PROJECT_DIR/logs/stdout.log" 2>> "$PROJECT_DIR/logs/stderr.log" &
        local new_pid=$!
        # 等待一秒确认进程存活
        sleep 1
        if kill -0 "$new_pid" 2>/dev/null; then
            info "服务已启动 (PID: $new_pid, 端口: $PORT)"
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

# ===== 命令实现 =====

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
    # SESSION_SECRET 是必填项（设为 random_string 会导致程序 fatal）
    # 如果 .env 中没有有效的 SESSION_SECRET，自动生成一个
    if ! grep -qE '^SESSION_SECRET=.+' "$PROJECT_DIR/.env" \
       || grep -qE '^SESSION_SECRET=random_string$' "$PROJECT_DIR/.env"; then
        local secret
        secret="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 32)"
        # 替换已有的行，或追加新行
        if grep -q '^SESSION_SECRET=' "$PROJECT_DIR/.env" || grep -q '^# SESSION_SECRET=' "$PROJECT_DIR/.env"; then
            sed -i.bak 's/^#\{0,1\} \{0,1\}SESSION_SECRET=.*/SESSION_SECRET='"$secret"'/' "$PROJECT_DIR/.env"
            rm -f "$PROJECT_DIR/.env.bak"
        else
            echo "SESSION_SECRET=$secret" >> "$PROJECT_DIR/.env"
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

    # 检测 Python
    local PY
    PY="$(command -v python3 || command -v python || true)"
    if [ -z "$PY" ]; then
        warn "未找到 python3/python，跳过自动初始化"
        warn "请手动访问 http://localhost:$PORT 完成初始设置"
    else
        # 等待服务就绪（最多 15 秒）
        info "等待服务就绪..."
        local ready=0
        for _ in $(seq 1 15); do
            if curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/api/status" 2>/dev/null | grep -q 200; then
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

            # 登录默认管理员账号（root/123456）
            local COOKIE_JAR
            COOKIE_JAR=$(mktemp)
            local LOGIN_RESP
            LOGIN_RESP=$(curl -s -c "$COOKIE_JAR" -X POST "http://localhost:$PORT/api/user/login" \
                -H "Content-Type: application/json" \
                -d '{"username":"root","password":"123456"}') || true

            # 解析登录响应，提取 user_id
            local INIT_USER_ID
            INIT_USER_ID=$("$PY" -c "import json,sys; d=json.loads(sys.argv[1]); print(d['data']['id'])" "$LOGIN_RESP" 2>/dev/null) || true

            if [ -z "$INIT_USER_ID" ]; then
                warn "登录默认管理员失败（可能已修改过密码），跳过自动初始化"
                rm -f "$COOKIE_JAR"
            else
                # 生成随机密码（8 位字母数字）
                local ADMIN_PASS
                ADMIN_PASS=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 8)

                # 修改用户名和密码（root → admin）
                local UPDATE_BODY
                UPDATE_BODY=$("$PY" -c "import json,sys; print(json.dumps({'id':int(sys.argv[1]),'username':'admin','password':sys.argv[2]}))" "$INIT_USER_ID" "$ADMIN_PASS")
                curl -s -b "$COOKIE_JAR" -X PUT "http://localhost:$PORT/api/user/" \
                    -H "Content-Type: application/json" -d "$UPDATE_BODY" >/dev/null 2>&1 || true

                # 生成 Access Token
                local TOKEN_RESP ACCESS_TOKEN
                TOKEN_RESP=$(curl -s -b "$COOKIE_JAR" "http://localhost:$PORT/api/user/token") || true
                ACCESS_TOKEN=$("$PY" -c "import json,sys; d=json.loads(sys.argv[1]); print(d['data'])" "$TOKEN_RESP" 2>/dev/null) || true

                # 清理 cookie
                rm -f "$COOKIE_JAR"

                if [ -z "$ACCESS_TOKEN" ]; then
                    warn "获取 Access Token 失败，跳过凭据保存"
                    warn "用户名已修改为 admin，密码: $ADMIN_PASS"
                else
                    # 先打印凭据，确保即使 config.json 写入失败也不丢失
                    echo ""
                    info "管理后台: http://localhost:$PORT"
                    info "用户名: admin"
                    info "密码: $ADMIN_PASS"
                    info "Access Token: ${ACCESS_TOKEN:0:12}..."

                    # 写入 config.json（失败不影响凭据输出）
                    if "$PY" -c "
import json, sys
config = {
    'server': sys.argv[1],
    'token': sys.argv[2],
    'user_id': int(sys.argv[3]),
    'username': 'admin',
    'password': sys.argv[4]
}
with open(sys.argv[5], 'w') as f:
    json.dump(config, f, indent=2, ensure_ascii=False)
" "http://localhost:$PORT" "$ACCESS_TOKEN" "$INIT_USER_ID" "$ADMIN_PASS" "$SCRIPT_DIR/config.json"; then
                        chmod 600 "$SCRIPT_DIR/config.json"
                        info "凭据已保存到: $SCRIPT_DIR/config.json"
                    else
                        warn "config.json 写入失败，请手动记录上述凭据"
                    fi
                    warn "请妥善保管密码，此密码仅显示一次"
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
        exit 1
    fi

    # fetch 上游
    info "拉取上游更新..."
    if ! git -C "$PROJECT_DIR" fetch "$UPSTREAM_REMOTE"; then
        error "拉取上游失败，请检查网络连接"
        exit 1
    fi

    # 合并
    info "合并 ${UPSTREAM_REMOTE}/main 到当前分支..."
    if git -C "$PROJECT_DIR" merge "${UPSTREAM_REMOTE}/main" --no-edit; then
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

# status: 查看服务状态
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
            # 查找所有 .log 文件
            local log_files=()
            while IFS= read -r -d '' f; do
                log_files+=("$f")
            done < <(find "$log_dir" -name "*.log" -print0 2>/dev/null)
            if [ ${#log_files[@]} -gt 0 ]; then
                info "显示日志: ${log_files[*]}"
                tail -f -n 100 "${log_files[@]}"
            else
                warn "未找到日志文件"
                info "日志目录: $log_dir"
                ls -la "$log_dir" 2>/dev/null || true
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
    echo "  2) rebuild   - 重新编译并重启"
    echo "  3) pull      - 从上游同步更新"
    echo "  4) push      - 推送到远程仓库"
    echo "  5) status    - 查看服务状态"
    echo "  6) logs      - 查看服务日志"
    echo "  0) 退出"
    echo ""
    read -r -p "请选择操作 [0-6]: " choice || true
    case "$choice" in
        1) cmd_install ;;
        2) cmd_rebuild ;;
        3) cmd_pull ;;
        4) cmd_push ;;
        5) cmd_status ;;
        6) cmd_logs ;;
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
    echo "  install   初始化项目、编译并启动服务"
    echo "  rebuild   重新编译并重启服务"
    echo "  pull      从上游同步更新到 $BRANCH_NAME 分支"
    echo "  push      推送 $BRANCH_NAME 分支到 origin"
    echo "  status    查看服务状态"
    echo "  logs      查看服务日志"
    echo ""
    echo "不带参数运行时显示交互式菜单。"
}

# ===== 入口 =====
case "${1:-}" in
    install) cmd_install ;;
    rebuild) cmd_rebuild ;;
    pull)    cmd_pull ;;
    push)    cmd_push ;;
    status)  cmd_status ;;
    logs)    cmd_logs ;;
    -h|--help) show_help ;;
    "")      show_menu ;;
    *)
        error "未知命令: $1"
        echo ""
        show_help
        exit 1
        ;;
esac
