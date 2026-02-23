#!/bin/bash
# ============================================================================
# Develop API - 恢复默认模板
# 将所有自定义品牌选项重置为空，恢复 new-api 原始界面
#
# 用法:
#   export DEVELOP_API_TOKEN=<管理员令牌>
#   export DEVELOP_API_SERVER=http://localhost:3000  # 可选，默认 localhost
#   bash scripts/template-default.sh
# ============================================================================

SERVER="${DEVELOP_API_SERVER:-http://localhost:3000}"
TOKEN="${DEVELOP_API_TOKEN:-}"

if [ -z "$TOKEN" ]; then
  echo "错误：请先设置管理员令牌"
  echo ""
  echo "  export DEVELOP_API_TOKEN=<你的管理员令牌>"
  echo "  bash $0"
  echo ""
  echo "令牌获取方式：登录管理后台 → 令牌管理 → 复制令牌"
  exit 1
fi

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "${_SCRIPT_DIR}/_common.sh"

echo "🔄 正在恢复默认模板..."
echo "   服务器: $SERVER"
echo ""

# 重置所有自定义选项为空字符串
printf '' | set_option "SystemName"
printf '' | set_option "Logo"
printf '' | set_option "ServerAddress"
printf '' | set_option "HomePageContent"
printf '' | set_option "Footer"
printf '' | set_option "About"

echo ""
echo "✅ 已恢复默认模板！请刷新浏览器查看效果。"
