# Develop API 品牌模板系统

通过 shell 脚本一键切换管理后台的品牌外观，零源码修改，方便同步上游更新。

## 前置条件

- **bash**（macOS / Linux 自带）
- **curl**
- **Python 3.6+**（`python3` 或 `python` 均可，脚本自动检测）
- 后端服务已启动（默认 `http://localhost:3000`）
- 管理员 API 令牌（获取方式：登录管理后台 → 令牌管理 → 复制令牌）

## 快速开始

```bash
# 1. 设置环境变量
export DEVELOP_API_TOKEN=sk-xxxxxxxxxxxx

# 2. 如果后端不在默认地址，指定服务器（可选）
export DEVELOP_API_SERVER=http://localhost:3000

# 3. 应用模板（三选一）
bash scripts/template-apple.sh      # 苹果风
bash scripts/template-dark.sh       # 深色高雅风
bash scripts/template-minimal.sh    # 科技简约风

# 4. 刷新浏览器查看效果
```

## 可用模板

### 苹果风 (Apple Style)

```bash
bash scripts/template-apple.sh
```

- 设计语言：Apple.com 官网风格
- 白色背景 + 蓝紫渐变 accent (#007AFF → #5856D6)
- 超大标题 + 充足留白 + 圆角卡片
- 按厂商分组的彩色模型标签
- Logo: `web/public/logo-apple.svg`

### 深色高雅风 (Dark Elegant)

```bash
bash scripts/template-dark.sh
```

- 设计语言：深色背景 + 金色/琥珀色 accent
- 深色背景 (#0A0A0A) + 金色渐变 (#D4A574 → #C9956B)
- 英文界面，精致感
- 微妙的径向光晕装饰
- Logo: `web/public/logo-dark.svg`

### 科技简约风 (Tech Minimal)

```bash
bash scripts/template-minimal.sh
```

- 设计语言：纯白背景 + 大量留白 + 终端/代码风格
- 绿色 accent (#059669)
- 等宽字体 API 地址展示
- 极简卡片（细边框 + 无阴影）
- Logo: `web/public/logo-minimal.svg`

### 恢复默认

```bash
bash scripts/template-default.sh
```

将所有自定义选项重置为空，恢复 new-api 原始界面。

## 文件说明

```
scripts/
├── _common.sh              # 公共函数（依赖检查、API 调用），不可直接执行
├── template-apple.sh       # 苹果风模板
├── template-dark.sh        # 深色高雅风模板
├── template-minimal.sh     # 科技简约风模板
└── template-default.sh     # 恢复默认

web/public/
├── logo-apple.svg          # 苹果风 Logo（蓝紫渐变圆角矩形 + D）
├── logo-dark.svg           # 深色风 Logo（深色圆形 + 金色边框 + D）
└── logo-minimal.svg        # 简约风 Logo（绿色方框 + D）
```

## 工作原理

模板脚本通过 `PUT /api/option/` API 动态设置以下 6 个系统选项：

| 选项 | 说明 |
|------|------|
| `SystemName` | 系统名称，显示在标题栏等位置 |
| `Logo` | Logo 图片路径或 URL |
| `ServerAddress` | API 服务器地址 |
| `HomePageContent` | 首页自定义 HTML（支持 `<style>` 标签） |
| `Footer` | 页脚自定义 HTML |
| `About` | 关于页面自定义 HTML |

不修改任何源码文件，所有定制通过运行时配置完成。

## 注意事项

- **Logo 构建**：Logo SVG 位于 `web/public/` 目录。开发环境（`bun run dev`）可直接访问；生产环境需重新构建前端（`cd web && bun run build`），或将 Logo 选项改为外部图片 URL。
- **固定配色**：模板使用固定背景色，不跟随系统暗色/亮色主题切换。选择一套模板即代表接受该模板的整体配色方案。
- **认证失败**：如果令牌无效，脚本会在第一个选项失败后自动终止并提示检查令牌。
- **重复应用**：可随时重新运行任意模板脚本来切换风格，新模板会覆盖旧设置。

## 自定义模板

如需创建自己的模板，可以复制任意一个 `template-*.sh` 作为基础，修改其中的 HTML/CSS 内容。模板脚本的结构：

```bash
#!/bin/bash
SERVER="${DEVELOP_API_SERVER:-http://localhost:3000}"
TOKEN="${DEVELOP_API_TOKEN:-}"

# 令牌检查...

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "${_SCRIPT_DIR}/_common.sh"

# 设置选项（使用 set_option 函数）
echo "My API" | set_option "SystemName"
echo "/my-logo.svg" | set_option "Logo"
echo "https://api.example.com" | set_option "ServerAddress"
cat <<'HTMLEOF' | set_option "HomePageContent"
<style>/* 自定义 CSS */</style>
<div><!-- 自定义 HTML --></div>
HTMLEOF
cat <<'HTMLEOF' | set_option "Footer"
<style>.custom-footer + div { display: none !important; }</style>
<div><!-- 自定义页脚 --></div>
HTMLEOF
cat <<'HTMLEOF' | set_option "About"
<div><!-- 自定义关于页面 --></div>
HTMLEOF
```

关键点：
- `HomePageContent` 和 `About` 的 HTML 内会被 `marked.parse()` 处理，但块级 HTML 标签会被保留
- Footer 中 `<style>.custom-footer + div { display: none !important; }</style>` 用于隐藏默认页脚署名
- 建议为 CSS 类名添加唯一前缀（如 `da-xxx-`），避免与框架样式冲突
- 建议为首页和关于页面添加显式背景色包裹层，防止系统主题切换导致文字不可见
