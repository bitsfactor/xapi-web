#!/bin/bash
# ============================================================================
# Develop API - 苹果风模板 (Apple Style)
# 设计语言：Apple.com 官网风格，超大标题 + 充足留白 + 蓝紫渐变
#
# 用法:
#   export DEVELOP_API_TOKEN=<管理员令牌>
#   export DEVELOP_API_SERVER=http://localhost:3000  # 可选，默认 localhost
#   bash scripts/template-apple.sh
#
# 注意：Logo 使用 /logo-apple.svg，需要该文件存在于 web/public/ 目录。
#       生产环境部署前需重新构建前端（bun run build），或将 Logo 改为外部 URL。
#       模板使用固定配色（白色背景），不跟随系统暗色/亮色主题切换。
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

echo "🍎 正在应用 [苹果风] 模板..."
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
.da-apple-bg{background:#FFFFFF;min-height:calc(100vh - 60px);min-height:calc(100dvh - 60px);width:100%}
.da-apple-wrap{font-family:-apple-system,BlinkMacSystemFont,'SF Pro Display','SF Pro Text','Helvetica Neue',Helvetica,Arial,sans-serif;color:#1D1D1F;max-width:980px;margin:0 auto;padding:0 20px}
.da-apple-hero{text-align:center;padding:80px 0 60px}
.da-apple-hero h1{font-size:56px;font-weight:700;letter-spacing:-0.015em;line-height:1.07;margin:0;background:linear-gradient(135deg,#007AFF,#5856D6);-webkit-background-clip:text;-webkit-text-fill-color:transparent;background-clip:text;color:transparent}
.da-apple-hero .da-sub{font-size:21px;color:#86868B;margin-top:16px;line-height:1.38;max-width:600px;margin-left:auto;margin-right:auto}
.da-apple-addr{margin-top:32px;background:#F5F5F7;border-radius:12px;padding:16px 24px;display:inline-block}
.da-apple-addr .da-label{color:#86868B;font-size:14px}
.da-apple-addr .da-url{font-size:18px;font-weight:600;color:#1D1D1F;margin-top:4px;font-family:'SF Mono',SFMono-Regular,Menlo,monospace}
.da-apple-cta{display:inline-block;background:linear-gradient(135deg,#007AFF,#5856D6);color:white;padding:12px 28px;border-radius:980px;font-size:17px;font-weight:600;text-decoration:none;margin-top:24px;transition:opacity 0.3s}
.da-apple-cta:hover{opacity:0.85;color:white}
.da-apple-features{display:grid;grid-template-columns:repeat(3,1fr);gap:20px;padding:40px 0}
.da-apple-card{background:#F5F5F7;border-radius:18px;padding:32px;text-align:center;color:#1D1D1F}
.da-apple-card .da-icon{font-size:40px;margin-bottom:16px}
.da-apple-card h3{font-size:19px;font-weight:600;margin:0 0 8px}
.da-apple-card p{font-size:14px;color:#86868B;margin:0;line-height:1.5}
.da-apple-models{padding:40px 0 80px;text-align:center}
.da-apple-models h2{font-size:32px;font-weight:700;margin:0 0 24px}
.da-apple-tags{display:flex;flex-wrap:wrap;gap:8px;justify-content:center}
.da-apple-tag{padding:6px 16px;border-radius:980px;font-size:13px;font-weight:500}
.da-tag-openai{background:rgba(0,122,255,0.12);color:#007AFF}
.da-tag-claude{background:rgba(217,115,64,0.12);color:#D97340}
.da-tag-gemini{background:rgba(66,133,244,0.12);color:#4285F4}
.da-tag-deep{background:rgba(16,185,129,0.12);color:#059669}
.da-tag-other{background:rgba(139,92,246,0.12);color:#7C3AED}
.da-tag-more{background:rgba(107,114,128,0.12);color:#6B7280}
@media(max-width:768px){
  .da-apple-hero h1{font-size:36px}
  .da-apple-hero .da-sub{font-size:17px}
  .da-apple-features{grid-template-columns:1fr}
}
</style>
<div class="da-apple-bg">
  <div class="da-apple-wrap">
  <div class="da-apple-hero">
    <h1>智能 AI API 网关</h1>
    <p class="da-sub">统一接口，聚合全球 40+ AI 模型，为您的应用赋予智能</p>
    <div class="da-apple-addr">
      <div class="da-label">API 地址</div>
      <div class="da-url">https://api.develop.cc</div>
    </div>
    <div><a href="/token" class="da-apple-cta">开始使用</a></div>
  </div>
  <div class="da-apple-features">
    <div class="da-apple-card">
      <div class="da-icon">🔗</div>
      <h3>统一接口</h3>
      <p>OpenAI 兼容格式，一个接口调用所有主流模型，无需适配多套 SDK</p>
    </div>
    <div class="da-apple-card">
      <div class="da-icon">🤖</div>
      <h3>多模型支持</h3>
      <p>GPT-4o、Claude、Gemini、DeepSeek 等 40+ 模型，按需灵活切换</p>
    </div>
    <div class="da-apple-card">
      <div class="da-icon">🔒</div>
      <h3>安全可靠</h3>
      <p>企业级安全架构，密钥隔离，限流保护，稳定高可用</p>
    </div>
  </div>
  <div class="da-apple-models">
    <h2>支持的模型</h2>
    <div class="da-apple-tags">
      <span class="da-apple-tag da-tag-openai">GPT-4o</span>
      <span class="da-apple-tag da-tag-openai">GPT-4o-mini</span>
      <span class="da-apple-tag da-tag-openai">o1</span>
      <span class="da-apple-tag da-tag-openai">o3-mini</span>
      <span class="da-apple-tag da-tag-claude">Claude 3.5 Sonnet</span>
      <span class="da-apple-tag da-tag-claude">Claude 3 Opus</span>
      <span class="da-apple-tag da-tag-claude">Claude 3 Haiku</span>
      <span class="da-apple-tag da-tag-gemini">Gemini 2.0</span>
      <span class="da-apple-tag da-tag-gemini">Gemini 1.5 Pro</span>
      <span class="da-apple-tag da-tag-deep">DeepSeek V3</span>
      <span class="da-apple-tag da-tag-deep">DeepSeek R1</span>
      <span class="da-apple-tag da-tag-other">Llama 3</span>
      <span class="da-apple-tag da-tag-other">Mistral</span>
      <span class="da-apple-tag da-tag-more">更多模型...</span>
    </div>
  </div>
  </div>
</div>
HTMLEOF

# --------------------------------------------------
# 5. 页脚 (Footer)
# --------------------------------------------------
cat <<'HTMLEOF' | set_option "Footer"
<style>.custom-footer + div { display: none !important; }</style>
<div style="text-align:center;padding:20px 0;font-family:-apple-system,BlinkMacSystemFont,'SF Pro Text',sans-serif;color:#86868B;font-size:13px;border-top:1px solid #E5E5E5;background:#FFFFFF;">
  <span>© 2025–2026 <a href="https://develop.cc" target="_blank" style="color:#86868B;text-decoration:none;">BitFactor LLC</a> · </span>
  <a href="https://develop.cc" target="_blank" style="color:#86868B;text-decoration:none;">develop.cc</a>
</div>
HTMLEOF

# --------------------------------------------------
# 6. 关于页面 (About)
# --------------------------------------------------
cat <<'HTMLEOF' | set_option "About"
<div style="background:#FFFFFF;min-height:calc(100vh - 120px);min-height:calc(100dvh - 120px);margin:0 -0.5rem;padding:0 0.5rem;">
  <div style="max-width:680px;margin:0 auto;font-family:-apple-system,BlinkMacSystemFont,'SF Pro Text',sans-serif;color:#1D1D1F;line-height:1.6;padding:40px 20px;">
  <h2 style="font-size:32px;font-weight:700;margin:0 0 16px;background:linear-gradient(135deg,#007AFF,#5856D6);-webkit-background-clip:text;-webkit-text-fill-color:transparent;background-clip:text;color:transparent;">Develop API</h2>
  <p style="font-size:17px;color:#86868B;margin:0 0 32px;">智能 AI API 网关 · 由 BitFactor LLC 提供</p>
  <div style="background:#F5F5F7;border-radius:12px;padding:24px;margin-bottom:24px;">
    <h3 style="font-size:17px;font-weight:600;margin:0 0 12px;">关于我们</h3>
    <p style="font-size:15px;color:#1D1D1F;margin:0;line-height:1.6;">Develop API 是由 BitFactor LLC 运营的 AI API 聚合网关服务。我们提供统一的 OpenAI 兼容接口，聚合全球 40+ 主流 AI 模型，帮助开发者快速集成 AI 能力。</p>
  </div>
  <div style="background:#F5F5F7;border-radius:12px;padding:24px;">
    <h3 style="font-size:17px;font-weight:600;margin:0 0 12px;">联系方式</h3>
    <p style="font-size:15px;color:#1D1D1F;margin:0;">网站：<a href="https://develop.cc" target="_blank" style="color:#007AFF;text-decoration:none;">develop.cc</a></p>
  </div>
  </div>
</div>
HTMLEOF

echo ""
echo "✅ 苹果风模板应用完成！请刷新浏览器查看效果。"
echo ""
echo "提示：如需生产环境使用 Logo，请执行 cd web && bun run build 重新构建前端，"
echo "      或将 Logo 选项改为外部图片 URL。"
