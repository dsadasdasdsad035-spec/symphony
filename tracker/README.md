# Symphony Tracker

轻量 **Linear 风格**工单系统：SQLite 存储、Fastify API、React 看板 UI。可与 Symphony 通过 `GET /api/symphony/issues` 对接（按 `symphony` 标签筛选可派发工单）。

## 测试

```bash
cd tracker
npm test                      # Tracker HTTP + Elixir issue_feed 单元测试
npm run test:full             # 另校验 ~/.config/symphony/WORKFLOW.md
npm run test:full-chain       # 全链路：API + Playwright 看板 + Orchestrator 派发 fake agent
./scripts/e2e-test.sh --full-chain
./scripts/e2e-test.sh --no-elixir   # 仅 API，不跑 mix test
```

**已覆盖（`test:full-chain`）**：

| 环节 | 验证内容 |
|------|----------|
| Tracker API | CRUD、Symphony 列表、标签过滤 |
| Vite + Playwright | 新建工单、看板卡片、详情弹窗、API 回读 |
| Symphony Elixir | `issue_feed` 轮询 → Orchestrator `running` → 工作区目录 + fake codex 一轮 |
| 配置（可选） | 本机 `WORKFLOW.md` 为 `issue_feed` |

**仍不覆盖**：真实 Codex/Cursor 进程、向 GitHub 推 PR、生产环境 `npm start` 静态托管（可手工补测）。

## 启动

```bash
cd tracker
npm install
npm run dev
```

- API：`http://127.0.0.1:4780`
- 前端：`http://127.0.0.1:4781`（Vite 代理 `/api` 到后端）

生产（API + 静态看板，需先构建前端）：

```bash
npm run build
npm run start
```

浏览器打开 `http://127.0.0.1:4780` 即可使用看板（开发时仍推荐 `npm run dev` 分离端口）。

## 环境变量

| 变量 | 默认 | 说明 |
|------|------|------|
| `TRACKER_PORT` | `4780` | API 端口 |
| `TRACKER_HOST` | `127.0.0.1` | 绑定地址 |
| `TRACKER_PUBLIC_URL` | `http://127.0.0.1:4780` | 工单 `url` 字段前缀 |
| `TRACKER_DB_PATH` | `tracker/data/tracker.db` | SQLite 路径 |
| `TRACKER_API_TOKEN` | 空 | 设置后，写操作需 `Authorization: Bearer <token>` |
| `TRACKER_ACTIVE_STATES` | `backlog,todo,in_progress,in_review` | Symphony 轮询默认状态 |

## API 摘要

- `GET /api/v1/projects` — 项目列表
- `GET /api/v1/projects/:slug/issues` — 工单列表
- `POST /api/v1/projects/:slug/issues` — 创建工单（body: `title`, `description`, `state`, `labels[]`）
- `PATCH /api/v1/issues/:id` — 更新
- `POST /api/v1/issues/:id/comments` — 评论
- `GET /api/symphony/issues?project=comic&label=symphony` — Symphony 兼容列表

默认项目 `comic`（名称 `ai-comic-drama`）。新工单建议打上标签 `symphony` 以便编排器拾取。

## Symphony `WORKFLOW.md`

见 [`WORKFLOW.issue-feed.example.md`](./WORKFLOW.issue-feed.example.md)。Elixir 适配器种类为 **`issue_feed`**。
