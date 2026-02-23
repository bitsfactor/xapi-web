#!/bin/bash
# ============================================================================
# Develop API - 模板脚本公共函数
# 被 template-*.sh 脚本通过 source 引用，不可直接执行
#
# 提供：
#   - Python 3 / curl 依赖检查（自动检测 python3 或 python）
#   - 临时文件自动清理（trap EXIT/INT/TERM）
#   - set_option 函数（从 stdin 读取值，调用 PUT /api/option/ 设置选项）
#
# 要求调用方在 source 前已定义 SERVER 和 TOKEN 变量
# ============================================================================

# 依赖检查：Python 3（支持 python3 或 python 命令名）
_DA_PYTHON=$(command -v python3 || command -v python || true)
if [ -z "$_DA_PYTHON" ]; then
  echo "错误：需要 python3 或 python，请先安装"
  exit 1
fi
if ! "$_DA_PYTHON" -c "import sys; assert sys.version_info >= (3,6)" 2>/dev/null; then
  echo "错误：需要 Python 3.6+，当前: $("$_DA_PYTHON" --version 2>&1)"
  exit 1
fi

# 依赖检查：curl
if ! command -v curl &>/dev/null; then
  echo "错误：需要 curl，请先安装"
  exit 1
fi

# 临时文件自动清理
_DA_TMPFILES=()
_da_cleanup() { rm -f "${_DA_TMPFILES[@]}"; }
trap _da_cleanup EXIT INT TERM

# 通用设置函数：从 stdin 读取值，调用 API 设置选项
# 用法：printf 'value' | set_option "Key"
#       cat <<'EOF' | set_option "Key"
#       multi-line value
#       EOF
set_option() {
  local key="$1"
  local value
  value=$(cat)
  local tmpfile
  tmpfile=$(mktemp)
  _DA_TMPFILES+=("$tmpfile")

  printf '%s' "$value" | "$_DA_PYTHON" -c "
import json, sys
key = sys.argv[1]
value = sys.stdin.read()
with open(sys.argv[2], 'w') as f:
    json.dump({'key': key, 'value': value}, f)
" "$key" "$tmpfile"

  local response curl_err
  curl_err=$(mktemp)
  _DA_TMPFILES+=("$curl_err")
  response=$(curl -s -X PUT "${SERVER}/api/option/" \
    -H "Authorization: Bearer ${TOKEN}" \
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

  if printf '%s' "$response" | "$_DA_PYTHON" -c "import json,sys; exit(0 if json.load(sys.stdin).get('success') else 1)" 2>/dev/null; then
    echo "  ✓ $key"
  else
    # 提取错误消息
    local msg
    msg=$(printf '%s' "$response" | "$_DA_PYTHON" -c "
import json,sys
try:
  d=json.load(sys.stdin); print(d.get('message','未知错误'))
except:
  print(sys.stdin.read())
" 2>/dev/null)
    echo "  ✗ $key - ${msg:-$response}"

    # 认证失败时提前终止，避免重复 6 次相同错误
    if printf '%s' "$response" | "$_DA_PYTHON" -c "
import json,sys
d=json.load(sys.stdin)
m=d.get('message','')
sys.exit(0 if any(k in m for k in ['token','无权','未登录','unauthorized']) else 1)
" 2>/dev/null; then
      echo ""
      echo "错误：认证失败，请检查 DEVELOP_API_TOKEN 是否正确。"
      exit 1
    fi
  fi
}
