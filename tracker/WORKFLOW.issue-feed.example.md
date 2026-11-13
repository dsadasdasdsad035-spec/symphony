# 复制到 ~/.config/symphony/WORKFLOW.md 的 tracker 段示例

先启动 Tracker：`cd tracker && npm run dev`（或 `npm run build && npm run start` 一体化）。

```yaml
---
tracker:
  kind: issue_feed
  endpoint: http://127.0.0.1:4780
  project_slug: comic
  required_labels:
    - symphony
  active_states:
    - backlog
    - todo
    - in_progress
    - in_review
  terminal_states:
    - done
    - cancelled
  provider:
    base_url: http://127.0.0.1:4780
    project: comic
    # api_token: $TRACKER_API_TOKEN   # 若 Tracker 设置了 TRACKER_API_TOKEN
polling:
  interval_ms: 30000
workspace:
  root: ~/code/symphony-workspaces
---
```

（上方 `---` 之后保留你现有的 agent / codex / prompt 配置。）
