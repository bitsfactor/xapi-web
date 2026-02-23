#!/bin/bash
# ============================================================================
# Develop API - 科技简约风模板 (Tech Minimal)
# 设计语言：纯白背景 + 大量留白 + 绿色 accent + 终端/代码风格元素
#
# 用法:
#   export DEVELOP_API_TOKEN=<管理员令牌>
#   export DEVELOP_API_SERVER=http://localhost:3000  # 可选，默认 localhost
#   bash scripts/template-minimal.sh
#
# 注意：Logo 使用 /logo-minimal.svg，需要该文件存在于 web/public/ 目录。
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

echo "⚡ 正在应用 [科技简约风] 模板..."
echo "   服务器: $SERVER"
echo ""

# --------------------------------------------------
# 1. 系统名称
# --------------------------------------------------
echo "Develop API" | set_option "SystemName"

# --------------------------------------------------
# 2. Logo
# --------------------------------------------------
echo "/logo-minimal.svg" | set_option "Logo"

# --------------------------------------------------
# 3. 服务器地址
# --------------------------------------------------
echo "https://api.develop.cc" | set_option "ServerAddress"

# --------------------------------------------------
# 4. 首页内容 (HomePageContent)
# --------------------------------------------------
cat <<'HTMLEOF' | set_option "HomePageContent"
<style>
.da-min-bg{background:#FFFFFF;min-height:calc(100vh - 60px);min-height:calc(100dvh - 60px);width:100%}
.da-min-wrap{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;color:#000;max-width:900px;margin:0 auto;padding:0 20px}
.da-min-hero{text-align:center;padding:80px 0 60px}
.da-min-hero h1{font-size:48px;font-weight:800;letter-spacing:-0.03em;line-height:1.1;margin:0;color:#000}
.da-min-hero .da-sub{font-size:18px;color:#666;margin-top:14px;line-height:1.5;max-width:520px;margin-left:auto;margin-right:auto}
.da-min-addr{margin-top:32px;background:#F9FAFB;border:1px solid #E5E5E5;border-radius:6px;padding:14px 24px;display:inline-block;text-align:left;color:#000}
.da-min-addr .da-prompt{color:#059669;font-size:14px;font-family:'SF Mono',SFMono-Regular,'Fira Code',Menlo,monospace}
.da-min-addr .da-url{font-size:16px;font-weight:600;color:#000;font-family:'SF Mono',SFMono-Regular,'Fira Code',Menlo,monospace}
.da-min-cta{display:inline-block;background:#000;color:#fff;padding:10px 24px;border-radius:6px;font-size:15px;font-weight:600;text-decoration:none;margin-top:24px;transition:background 0.2s}
.da-min-cta:hover{background:#333;color:#fff}
.da-min-features{display:grid;grid-template-columns:repeat(3,1fr);gap:16px;padding:40px 0}
.da-min-card{background:#FFFFFF;border:1px solid #E5E5E5;border-radius:8px;padding:24px;transition:border-color 0.2s}
.da-min-card:hover{border-color:#10B981}
.da-min-card .da-accent{width:32px;height:3px;background:#10B981;border-radius:2px;margin-bottom:16px}
.da-min-card h3{font-size:16px;font-weight:700;margin:0 0 8px;color:#000}
.da-min-card p{font-size:14px;color:#666;margin:0;line-height:1.5}
.da-min-models{padding:40px 0 80px;text-align:center}
.da-min-models h2{font-size:24px;font-weight:800;color:#000;margin:0 0 24px;letter-spacing:-0.02em}
.da-min-list{display:flex;flex-wrap:wrap;gap:6px;justify-content:center}
.da-min-item{padding:5px 12px;font-size:13px;font-family:'SF Mono',SFMono-Regular,'Fira Code',Menlo,monospace;color:#666;background:#F9FAFB;border:1px solid #E5E5E5;border-radius:4px;transition:all 0.2s;text-decoration:none}
.da-min-item:hover{border-color:#10B981;color:#059669}
@media(max-width:768px){
  .da-min-hero h1{font-size:32px}
  .da-min-hero .da-sub{font-size:16px}
  .da-min-features{grid-template-columns:1fr}
}
</style>
<div class="da-min-bg">
  <div class="da-min-wrap">
  <div class="da-min-hero">
    <h1>Develop API</h1>
    <p class="da-sub">统一的 AI API 网关，一个接口连接 40+ 模型</p>
    <div class="da-min-addr">
      <div class="da-prompt">$ curl</div>
      <div class="da-url">https://api.develop.cc/v1/chat/completions</div>
    </div>
    <div><a href="/token" class="da-min-cta">获取 API Key →</a></div>
  </div>
  <div class="da-min-features">
    <div class="da-min-card">
      <div class="da-accent"></div>
      <h3>统一接口</h3>
      <p>兼容 OpenAI 格式，无缝切换模型供应商，零迁移成本</p>
    </div>
    <div class="da-min-card">
      <div class="da-accent"></div>
      <h3>多模型聚合</h3>
      <p>GPT-4o / Claude / Gemini / DeepSeek 等，按需灵活选择</p>
    </div>
    <div class="da-min-card">
      <div class="da-accent"></div>
      <h3>安全 &amp; 可靠</h3>
      <p>密钥隔离，请求限流，用量追踪，企业级高可用架构</p>
    </div>
  </div>
  <div class="da-min-models">
    <h2>支持的模型</h2>
    <div class="da-min-list">
      <span class="da-min-item">gpt-4o</span>
      <span class="da-min-item">gpt-4o-mini</span>
      <span class="da-min-item">o1</span>
      <span class="da-min-item">o3-mini</span>
      <span class="da-min-item">claude-3.5-sonnet</span>
      <span class="da-min-item">claude-3-opus</span>
      <span class="da-min-item">claude-3-haiku</span>
      <span class="da-min-item">gemini-2.0</span>
      <span class="da-min-item">gemini-1.5-pro</span>
      <span class="da-min-item">deepseek-v3</span>
      <span class="da-min-item">deepseek-r1</span>
      <span class="da-min-item">llama-3</span>
      <span class="da-min-item">mistral</span>
      <span class="da-min-item">...</span>
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
<div style="text-align:center;padding:16px 0;font-family:-apple-system,sans-serif;color:#999;font-size:12px;border-top:1px solid #EBEBEB;background:#FFFFFF;">
  © 2025–2026 BitFactor LLC
</div>
HTMLEOF

# --------------------------------------------------
# 6. 关于页面 (About)
# --------------------------------------------------
cat <<'HTMLEOF' | set_option "About"
<div style="background:#FFFFFF;min-height:calc(100vh - 120px);min-height:calc(100dvh - 120px);margin:0 -0.5rem;padding:0 0.5rem;">
  <div style="max-width:640px;margin:0 auto;font-family:-apple-system,BlinkMacSystemFont,sans-serif;color:#000;line-height:1.6;padding:40px 20px;">
  <h2 style="font-size:28px;font-weight:800;margin:0 0 12px;letter-spacing:-0.02em;">Develop API</h2>
  <p style="font-size:16px;color:#666;margin:0 0 32px;">AI API 网关 · BitFactor LLC</p>
  <div style="border:1px solid #E5E5E5;border-radius:8px;padding:24px;margin-bottom:16px;">
    <h3 style="font-size:16px;font-weight:700;margin:0 0 10px;">关于</h3>
    <p style="font-size:15px;color:#333;margin:0;line-height:1.6;">Develop API 是由 BitFactor LLC 运营的 AI API 聚合网关。提供统一的 OpenAI 兼容接口，支持 40+ 主流 AI 模型，一个 API Key 即可调用所有模型。</p>
  </div>
  <div style="border:1px solid #E5E5E5;border-radius:8px;padding:24px;">
    <h3 style="font-size:16px;font-weight:700;margin:0 0 10px;">联系</h3>
    <p style="font-size:15px;color:#333;margin:0;font-family:'SF Mono',monospace;"><a href="https://develop.cc" target="_blank" style="color:#059669;text-decoration:none;">develop.cc</a></p>
  </div>
  </div>
</div>
HTMLEOF

echo ""
echo "✅ 科技简约风模板应用完成！请刷新浏览器查看效果。"
echo ""
echo "提示：如需生产环境使用 Logo，请执行 cd web && bun run build 重新构建前端，"
echo "      或将 Logo 选项改为外部图片 URL。"
