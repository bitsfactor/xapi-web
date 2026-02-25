#!/bin/bash
# ============================================================================
# Develop API - 浅色简约风模板 (Apple Light)
# 设计语言：苹果简约风 · 白色背景 + 系统蓝 accent + 极简留白
#
# 用法:
#   bash scripts/template-light.sh
#
# 凭据从 scripts/config.json 自动加载（由 setup.sh install 生成）。
#
# 注意：Logo 使用 /logo-apple.svg，需要该文件存在于 web/public/ 目录。
#       生产环境部署前需重新构建前端（bun run build），或将 Logo 改为外部 URL。
#       模板使用固定浅色配色，不跟随系统暗色/亮色主题切换。
# ============================================================================

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# ========== 依赖检查 ==========

# Python 3（支持 python3 或 python 命令名）
_LA_PYTHON=$(command -v python3 || command -v python || true)
if [ -z "$_LA_PYTHON" ]; then
  echo "错误：需要 python3 或 python，请先安装"
  exit 1
fi
if ! "$_LA_PYTHON" -c "import sys; assert sys.version_info >= (3,6)" 2>/dev/null; then
  echo "错误：需要 Python 3.6+，当前: $("$_LA_PYTHON" --version 2>&1)"
  exit 1
fi

# curl
if ! command -v curl &>/dev/null; then
  echo "错误：需要 curl，请先安装"
  exit 1
fi

# ========== 加载凭据（从 config.json） ==========

_LA_CONFIG_FILE="${_SCRIPT_DIR}/config.json"
if [ ! -f "$_LA_CONFIG_FILE" ]; then
  echo "错误：未找到凭据文件 $_LA_CONFIG_FILE"
  echo "请先运行: ./scripts/setup.sh install"
  exit 1
fi

SERVER=$("$_LA_PYTHON" -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('server',''))" "$_LA_CONFIG_FILE")
TOKEN=$("$_LA_PYTHON" -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('token',''))" "$_LA_CONFIG_FILE")
USER_ID=$("$_LA_PYTHON" -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('user_id',''))" "$_LA_CONFIG_FILE")

if [ -z "$TOKEN" ] || [ -z "$USER_ID" ]; then
  echo "错误：config.json 中缺少 token 或 user_id"
  echo "请重新运行: ./scripts/setup.sh install"
  exit 1
fi

# ========== 临时文件自动清理 ==========

_LA_TMPFILES=()
_la_cleanup() { rm -f "${_LA_TMPFILES[@]}"; }
trap _la_cleanup EXIT INT TERM

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
  _LA_TMPFILES+=("$tmpfile")

  printf '%s' "$value" | "$_LA_PYTHON" -c "
import json, sys
key = sys.argv[1]
value = sys.stdin.read()
with open(sys.argv[2], 'w') as f:
    json.dump({'key': key, 'value': value}, f)
" "$key" "$tmpfile"

  local response curl_err
  curl_err=$(mktemp)
  _LA_TMPFILES+=("$curl_err")
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

  if printf '%s' "$response" | "$_LA_PYTHON" -c "import json,sys; exit(0 if json.load(sys.stdin).get('success') else 1)" 2>/dev/null; then
    echo "  ✓ $key"
  else
    # 提取错误消息
    local msg
    msg=$(printf '%s' "$response" | "$_LA_PYTHON" -c "
import json,sys
try:
  d=json.load(sys.stdin); print(d.get('message','未知错误'))
except:
  print(sys.stdin.read())
" 2>/dev/null)
    echo "  ✗ $key - ${msg:-$response}"

    # 认证失败时提前终止，避免重复相同错误
    if printf '%s' "$response" | "$_LA_PYTHON" -c "
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

echo "☀️  正在应用 [苹果简约风] 模板..."
echo "   服务器: $SERVER"
echo ""

# --------------------------------------------------
# 1. 系统名称
# --------------------------------------------------
echo "Develop API" | set_option "SystemName"

# --------------------------------------------------
# 2. Logo
# --------------------------------------------------
echo "/logo-apple.svg" | set_option "Logo"

# --------------------------------------------------
# 3. 服务器地址
# --------------------------------------------------
echo "https://api.develop.cc" | set_option "ServerAddress"

# --------------------------------------------------
# 4. 首页内容 (HomePageContent)
# --------------------------------------------------
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

# --------------------------------------------------
# 5. 页脚 (Footer)
# --------------------------------------------------
cat <<'HTMLEOF' | set_option "Footer"
<style>.custom-footer + div { display: none !important; } body,body[theme-mode],body[theme-mode="dark"],body[theme-mode="light"]{--semi-color-text-0:#1D1D1F;--semi-color-text-1:#6E6E73;--semi-color-text-2:#86868B;--semi-color-primary:#0071E3;--semi-color-primary-hover:#0077ED;--semi-color-fill-0:#F5F5F7;--semi-color-fill-1:#EBEBEB;--semi-color-fill-2:#E0E0E0;--semi-color-bg-0:#FFFFFF;--semi-color-bg-1:#F5F5F7;--semi-color-bg-2:#EBEBEB;--semi-color-primary-light-default:rgba(0,113,227,0.1);--semi-color-bg-overlay:#FFFFFF;--semi-color-border:#D2D2D7} header.sticky{background-color:rgba(255,255,255,0.85)!important;backdrop-filter:saturate(180%) blur(20px)!important;-webkit-backdrop-filter:saturate(180%) blur(20px)!important;border-bottom:1px solid rgba(0,0,0,0.08)!important}</style>
<div style="text-align:center;padding:20px 0;font-family:-apple-system,BlinkMacSystemFont,sans-serif;color:#86868B;font-size:13px;border-top:1px solid #D2D2D7;background:#FBFBFD;">
  <span>© 2025–2026 <a href="https://develop.cc" target="_blank" style="color:#0071E3;text-decoration:none;">BitFactor LLC</a></span>
</div>
HTMLEOF

# --------------------------------------------------
# 6. 关于页面 (About)
# --------------------------------------------------
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

echo ""
echo "✅ 苹果简约风模板应用完成！请刷新浏览器查看效果。"
echo ""
echo "提示：如需生产环境使用 Logo，请执行 cd web && bun run build 重新构建前端，"
echo "      或将 Logo 选项改为外部图片 URL。"
