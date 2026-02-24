#!/bin/bash
# ============================================================================
# Develop API - 深色高雅风模板 (Dark Elegant)
# 设计语言：深色背景 + 金色/琥珀色 accent + 精致感
#
# 用法:
#   bash scripts/template-dark.sh
#
# 凭据从 scripts/config.json 自动加载（由 setup.sh install 生成）。
#
# 注意：Logo 使用 /logo-dark.svg，需要该文件存在于 web/public/ 目录。
#       生产环境部署前需重新构建前端（bun run build），或将 Logo 改为外部 URL。
#       模板使用固定配色（深色背景），不跟随系统暗色/亮色主题切换。
# ============================================================================

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# ========== 依赖检查 ==========

# Python 3（支持 python3 或 python 命令名）
_DA_PYTHON=$(command -v python3 || command -v python || true)
if [ -z "$_DA_PYTHON" ]; then
  echo "错误：需要 python3 或 python，请先安装"
  exit 1
fi
if ! "$_DA_PYTHON" -c "import sys; assert sys.version_info >= (3,6)" 2>/dev/null; then
  echo "错误：需要 Python 3.6+，当前: $("$_DA_PYTHON" --version 2>&1)"
  exit 1
fi

# curl
if ! command -v curl &>/dev/null; then
  echo "错误：需要 curl，请先安装"
  exit 1
fi

# ========== 加载凭据（从 config.json） ==========

_DA_CONFIG_FILE="${_SCRIPT_DIR}/config.json"
if [ ! -f "$_DA_CONFIG_FILE" ]; then
  echo "错误：未找到凭据文件 $_DA_CONFIG_FILE"
  echo "请先运行: ./scripts/setup.sh install"
  exit 1
fi

SERVER=$("$_DA_PYTHON" -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('server',''))" "$_DA_CONFIG_FILE")
TOKEN=$("$_DA_PYTHON" -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('token',''))" "$_DA_CONFIG_FILE")
USER_ID=$("$_DA_PYTHON" -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('user_id',''))" "$_DA_CONFIG_FILE")

if [ -z "$TOKEN" ] || [ -z "$USER_ID" ]; then
  echo "错误：config.json 中缺少 token 或 user_id"
  echo "请重新运行: ./scripts/setup.sh install"
  exit 1
fi

# ========== 临时文件自动清理 ==========

_DA_TMPFILES=()
_da_cleanup() { rm -f "${_DA_TMPFILES[@]}"; }
trap _da_cleanup EXIT INT TERM

# ========== 通用设置函数 ==========

# 从 stdin 读取值，调用 API 设置选项
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

    # 认证失败时提前终止，避免重复相同错误
    if printf '%s' "$response" | "$_DA_PYTHON" -c "
import json,sys
d=json.load(sys.stdin)
m=d.get('message','')
sys.exit(0 if any(k in m for k in ['token','无权','未登录','unauthorized']) else 1)
" 2>/dev/null; then
      echo ""
      echo "错误：认证失败，请检查 config.json 中的 token 是否正确。"
      exit 1
    fi
  fi
}

# ========== 模板逻辑 ==========

echo "🌙 正在应用 [深色高雅风] 模板..."
echo "   服务器: $SERVER"
echo ""

# --------------------------------------------------
# 1. 系统名称
# --------------------------------------------------
echo "Develop API" | set_option "SystemName"

# --------------------------------------------------
# 2. Logo
# --------------------------------------------------
echo "/logo-dark.svg" | set_option "Logo"

# --------------------------------------------------
# 3. 服务器地址
# --------------------------------------------------
echo "https://api.develop.cc" | set_option "ServerAddress"

# --------------------------------------------------
# 4. 首页内容 (HomePageContent)
# --------------------------------------------------
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

# --------------------------------------------------
# 5. 页脚 (Footer)
# --------------------------------------------------
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

# --------------------------------------------------
# 6. 关于页面 (About)
# --------------------------------------------------
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

echo ""
echo "✅ 深色高雅风模板应用完成！请刷新浏览器查看效果。"
echo ""
echo "提示：如需生产环境使用 Logo，请执行 cd web && bun run build 重新构建前端，"
echo "      或将 Logo 选项改为外部图片 URL。"
