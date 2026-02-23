# CLAUDE.md

本文件为 Claude Code (claude.ai/code) 在本仓库中工作时提供指引。

## 项目概述

基于 Go (Gin + GORM) 和 React (Vite + Semi Design) 构建的 AI API 网关/代理。聚合 40+ 上游 AI 提供商 (OpenAI、Claude、Gemini、Azure、AWS Bedrock 等)，对外提供统一的 OpenAI 兼容 API，并包含用户管理、计费、限流和管理后台。

## 构建与开发命令

### 后端
```bash
go run main.go                    # 启动后端（默认端口 3000，可通过 PORT 环境变量覆盖）
go build -o new-api               # 编译二进制文件
go test ./...                     # 运行所有 Go 测试
go test ./relay/channel/claude/   # 运行指定包的测试
go test -run TestFuncName ./pkg/  # 按名称运行单个测试
```

注意：前端通过 `//go:embed web/dist` 嵌入到 Go 二进制中。执行 `go build` 前必须先构建前端。

### 前端（所有命令在 `web/` 目录下执行）
```bash
bun install                       # 安装依赖（使用 bun，不要用 npm/yarn）
bun run dev                       # Vite 开发服务器（API 代理到 localhost:3000）
bun run build                     # 生产构建 → web/dist/
bun run lint                      # Prettier 格式检查
bun run lint:fix                  # Prettier 自动格式化
bun run eslint                    # ESLint 检查
bun run i18n:extract              # 提取 i18n 字符串
bun run i18n:sync                 # 同步 i18n 翻译
bun run i18n:lint                 # 检查 i18n 文件
```

### 完整构建 (Makefile)
```bash
make all                          # 先构建前端，再启动后端
make build-frontend               # 仅构建前端
```

### Docker
```bash
docker build -t new-api .         # 多阶段构建：bun build → go build → debian-slim
```

## 架构

**请求流程：** Router → Middleware（认证、限流、分发）→ Controller → Service → Model/Relay

### Relay 系统（核心复杂度）

Relay 系统是本项目的核心——它通过统一接口将请求代理到 40+ AI 提供商。

- **`relay/channel/adapter.go`** 定义了两个关键接口：
  - `Adaptor` — 用于 chat/completion/embedding/image/audio 请求。每个提供商实现请求转换（OpenAI 格式 → 提供商格式）和响应转换（提供商格式 → OpenAI 格式）。
  - `TaskAdaptor` — 用于异步任务（图片/视频生成）。处理提交、轮询和计费调整的完整生命周期。
- **`relay/relay_adaptor.go`** — 工厂函数 `GetAdaptor(apiType)`，将 API 类型常量映射到对应的提供商适配器实例。
- **`relay/channel/{provider}/`** — 每个提供商目录（openai、claude、gemini、aws、ali、baidu 等）包含其 `Adaptor` 实现。
- **`relay/channel/task/{provider}/`** — 异步提供商的任务适配器（kling、suno、sora、hailuo 等）。

**添加新提供商：** 在 `relay/channel/` 下创建新目录，实现 `Adaptor` 接口，在 `constant/api_type.go` 中添加 API 类型常量，在 `constant/channel.go` 中添加渠道类型，最后在 `relay/relay_adaptor.go` 的 `GetAdaptor` switch 中注册。

### 路由组织 (`router/`)
- `api-router.go` — `/api/...` 端点（用户、令牌、渠道、模型管理）
- `relay-router.go` — `/v1/...` 端点（OpenAI 兼容的 relay API）
- `video-router.go` — 视频任务端点
- `dashboard.go` — 管理后台路由
- `web-router.go` — SPA 静态文件服务

### 中间件链
全局：`RequestId → PoweredBy → I18n → Logger → Sessions`，然后按路由组：`Gzip → GlobalAPIRateLimit → UserAuth/AdminAuth → TurnstileCheck → RateLimitPerModel → Distributor`

**分发器**（`middleware/distributor.go`）负责渠道选择和密钥分发，支持亲和性。

### 配置
- **环境变量加载：** 启动时 `godotenv` 加载 `.env`，然后 `common.InitEnv()` 读取环境变量
- **关键环境变量：** `SESSION_SECRET`、`SQLITE_PATH`、`SQL_DSN`（MySQL/PG）、`REDIS_CONN_STRING`、`PORT`、`DEBUG`、`MEMORY_CACHE_ENABLED`、`NODE_TYPE`（"slave" 表示从节点）
- **运行时配置：** `setting/` 子目录管理比率、模型、操作、系统和性能设置，通过 `model.InitOptionMap()` 从数据库加载

### 前端结构 (`web/`)
- React 18 + Vite + Semi Design UI (`@douyinfe/semi-ui`)
- 路由：React Router v6，位于 `web/src/App.jsx`，使用懒加载路由
- 国际化：`i18next`，以中文作为 key，翻译文件位于 `web/src/i18n/locales/{lang}.json`
- Prettier 配置：单引号、JSX 单引号（在 package.json 中配置）

## 规则

### 规则 1：JSON — 使用 `common/json.go` 封装函数

所有 JSON 操作必须使用 `common.Marshal`、`common.Unmarshal`、`common.UnmarshalJsonStr`、`common.DecodeJson`、`common.GetJsonType`。禁止直接调用 `encoding/json` 的序列化/反序列化方法。类型引用如 `json.RawMessage` 和 `json.Number` 可以使用。

### 规则 2：数据库 — 三数据库兼容（SQLite、MySQL、PostgreSQL）

所有数据库代码必须同时兼容三种数据库。

- 优先使用 GORM 方法而非原始 SQL。主键生成交给 GORM 处理。
- 保留字列名引用：使用 `model/main.go` 中的 `commonGroupCol`、`commonKeyCol`（PostgreSQL 用 `"column"`，MySQL/SQLite 用 `` `column` ``）。
- 布尔值：使用 `commonTrueVal`/`commonFalseVal`（PostgreSQL: `true`/`false`，其他: `1`/`0`）。
- 数据库检测标志：`common.UsingPostgreSQL`、`common.UsingSQLite`、`common.UsingMySQL`。
- SQLite 不支持 `ALTER COLUMN` — 只能用 `ADD COLUMN`。
- 禁止使用无跨库回退的数据库特定类型（用 `TEXT` 而非 `JSONB`）。
- 禁止使用无跨库等价方案的数据库特定函数。

### 规则 3：前端 — 使用 Bun

`bun install`、`bun run dev`、`bun run build`。不要用 npm/yarn/pnpm。

### 规则 4：新渠道 StreamOptions 支持

添加提供商时，确认其是否支持 `StreamOptions`。如果支持，将其添加到 `streamSupportedChannels`。

### 规则 5：受保护的项目信息

README、元数据、模块路径、Docker 配置等中对 **new-api**（项目名称）和 **QuantumNous**（组织名称）的引用受到严格保护，禁止删除、重命名或替换。
