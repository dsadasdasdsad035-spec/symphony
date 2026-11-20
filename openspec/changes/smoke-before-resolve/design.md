# Design

## Context

见 `proposal.md` 的 Why。以下是塑造方案的现状事实，均已在容器内实测。

**开发环境的两副面孔**

```
http://192.168.181.104:30669/
  /            -> 200，但内容是 nginx 欢迎页（不是 SPA）
  /iidp/       -> 200，真正的前端壳（wujie 微前端，<div id="base">）
  /iidp/iidpPreload.bundle.js -> 200 / 29KB
  /api/root/rpc/...           -> JSON-RPC 网关
```

`:30669` 既是前端站点根，也是后端 RPC 网关。UI 冒烟的落点是 `/iidp/`，API 冒烟的落点是 `/api/root/rpc/`。

**API 层的调用契约（实测跑通）**

```
1) 登录
   POST {BASE}/api/root/rpc/login/master
   {"id":"1","jsonrpc":"2.0","method":"login",
    "params":{"app":"base","args":{},"login":"<user>",
              "password":"<base64(password)>","remember":true}}
   -> result.data.token

2) 业务调用
   POST {BASE}/api/root/rpc/service/?model=<model>&service=<service>
   headers: Authorization: Bearer <token>
   {"jsonrpc":"2.0","method":"service","params":{
      "args":{"filter":{...}},"context":{...},
      "model":"<model>","tag":"master","service":"<service>","app":"<真实应用名>"}}
```

三个实测坑：

| 坑 | 现象 |
|---|---|
| 密码未 base64 | `-32602 用户名或密码错误` |
| `app` 写成模型名 | `400 No app info in local and remote, invoke appName: <模型>.backend` |
| 缺 `filter` | `504 Filter.getParameter ... filter is null`（已进真实业务代码） |

第三条反而是有价值的信号：报错栈里会出现 `MetaAppStore.java:305` 这类**带文件名与行号的真实业务代码位置**，可用作「环境里的代码确实被执行到」的证据。

**UI 层的运行前提**

```
python3 -m pip          -> No module named pip
id                      -> uid=1000(symphony)，非 root
chromium 依赖库          -> 缺 16 个（libnss3 libnspr4 libatk-1.0 libatk-bridge-2.0
                           libcups libdrm libxkbcommon libXcomposite libXdamage
                           libXfixes libXrandr libgbm libasound libpango libcairo libatspi）
pypi / npm 出网          -> 200，构建期可下载
```

即：**运行期装不了，只能构建期烘进镜像**。

**已有但休眠的资产**

`.zcode/skills/iidp-smoke-test/`（含 `frontend_smoke.py`、`frontend-smoke.md` 场景格式）与 `scripts/hooks/push_smoke_full.sh` 已存在，但前者不在 codex agent 的读取路径上，后者要求本机 8060 引擎在线——容器里没有。

**结论：两条都不作为执行入口。** 桌面自己拼场景 JSON / curl 的路线，长期成本落在三处——
元素定位散在各场景里改版就碎、验证逻辑随 bug 一次性丢弃、评审无法复跑同一条命令。
改用团队已在维护的 `iidp_uitest`（`http://192.168.175.55:9888/xuchunxia/iidp_uitest.git`）：
元素库 1957 条、页面方法库按域拆分、pytest/Allure 留证都是现成的，Agent 只写用例。
该仓库约 1.1G，运行期浅克隆到 `${SYMPHONY_WORKSPACE_ROOT}/.uitest` 跨 issue 复用。

UI 与 API 两层统一走这一套：`testcase/api/<产品>/` 前缀由 `conftest._is_non_ui_test`
识别为纯 API（跳过浏览器/trace/GIF/截图钩子），其余按界面层起无头浏览器。
`smoke_api.sh` 因此降级为内部工具，只留「读版本号」和「手工排查单条 RPC」两个用途。

## Goals / Non-Goals

**Goals**

- 让「已解决」这个状态在善治里具备可核验的含义：要么有环境冒烟证据，要么有具名理由说明为何测不了。
- 证据格式稳定到将来可升级为机器校验，而无需重跑一轮设计。
- UI 冒烟在镜像内自足：不依赖运行期安装，不依赖工作区缓存。

**Non-Goals**

- 不新增 Symphony 侧代理工具，不改 `shanzhi_resolve_bug` 的输入 schema（闸门强度已定为软约束）。
- 不追求覆盖每一个 Bug；豁免是设计的一部分，不是缺陷。
- 不把冒烟做成 CI 流水线，仍是 agent 在单次派发内自行执行。
- 不解决「本地 dev server 冒烟」——明确排除，因为本地通过不证明环境产物正确。

## Decisions

### 决策 1：冒烟目标锁定开发环境，不接本地 dev server

**选择**：两层冒烟都打 `:30669`。

**理由**：Bug 的价值在于「环境里那个地方坏了」。本地 `npm start` 起的是当前工作区源码，与 `publish_dev.sh` 推进去的产物之间存在构建、缓存、上架三道差异。用本地通过去证明环境已修好，是本末倒置。

**替代方案**：本地 dev server（skill 的默认设计）。放弃原因如上；且本地 dev server 是长驻进程，会跨轮次占用 `:8085`，下一轮派发时端口冲突，需要额外的生命周期管理——为一个不可信的信号付这个代价不值得。

### 决策 2：API 层直接 curl，不经 Symphony 代理

**选择**：agent 自己在 shell 里 curl，凭据取自容器已有的 `IIDP_USER` / `IIDP_PASSWORD`（已验证在 agent 子进程环境里可见）。

**理由**：软闸门不要求 Symphony 侧知道执行结果，代理层带来的唯一收益（防伪造）在软闸门下不成立。少一层实现，就少一处会坏的组件。

**替代方案**：新增 `run_smoke` 代理工具。留作将来升级硬闸门的路径——本设计的证据格式已按可解析设计，升级时无需改提示词措辞。

### 决策 3：playwright + chromium 构建期烘进镜像

**选择**：`deploy/Dockerfile` 中 `apt-get install` 16 个库、`pip install playwright`、`playwright install chromium`，浏览器落到 `/home/symphony/.cache/ms-playwright`（工作用户可写）。

**理由**：运行期无 root、无 pip，实测不可行；每工作区 `npm i playwright` 需 2~3 个 turn 的固定开销，在 `max_turns=30` 下占 10% 预算，且 217G 磁盘按工作区摊 200MB 不划算。

**替代方案**：
- 每工作区安装 —— 无 root 装不了系统库，直接排除。
- 用 puppeteer + 系统 chrome —— 容器内同样没有 chrome 二进制，且系统库里也没 chrome 的依赖。

### 决策 4：UI 冒烟用显式场景文件，不猜

**选择**：沿用 skill 既有的 `frontend-smoke.json` 格式（`steps` 数组 + 稳定语义选择器：`role`/`label`/`placeholder`/`text`，必要时 `selector`）。

**理由**：从自然语言描述正则推断点击路径，在 wujie 微前端的嵌套 DOM 里极不稳定；显式场景至少让失败原因是「选择器过期」而不是「猜错了」。

**替代方案**：由 Bug 描述自动生成场景。放弃：错误率不可接受，且失败不可归因。

### 决策 5：闸门落在提示词，证据格式固定

**选择**：`WORKFLOW.md` 约定证据段落必须含「类型 / 目标 / 场景 / 结果 / 证据引用」五个字段，结果只允许 PASS 与 FAIL；豁免必须给枚举化的未覆盖原因 + 替代验证。

**理由**：五字段固定是为了将来硬闸门能直接解析；枚举原因是为了防止「环境问题」「无法验证」这类无信息量的糊弄。

**替代方案**：自由文本备注。放弃：既不可解析，也无法区分「认真评估后测不了」和「偷懒」。

### 决策 6：UI 冒烟前校验版本可见性

**选择**：跑 UI 断言前，先通过 API 读环境中该应用的版本号，与发版报告比对；不一致则等待重试，超时则按豁免处理并说明。

**理由**：宿主加载的是市场里的产物，存在缓存窗口。若在旧产物上断言，会得到一个**假的 PASS**，其危害大于没有证据——因为它会让「已解决」看起来比实际更可靠。

**替代方案**：不校验，直接跑。放弃：失败模式是静默的错误通过，最不可接受的一类缺陷。

## Risks / Trade-offs

| 风险 | 影响 | 处置 |
|---|---|---|
| 软闸门可被规避（编造证据或跳过） | 证据可信度依赖 agent 自觉 | **已升级**（2026-11，`smoke-hard-gate-ui-mandatory`）：`ResolveGate` + `smoke-pass.json` + `SMOKE_RESOLVE_GATE`；豁免不绕闸 |
| 镜像体积与构建时长上升 | 拉镜像变慢，Pod 冷启动变慢 | 浏览器只在构建期落盘；如后续发现过大，可换 `chromium-headless-shell` |
| UI 冒烟吃轮次 | `max_turns=30` 下可能挤占修复预算 | 场景限制在 1~5 条核心路径；必要时提高 `max_turns` 或把 UI 冒烟放末轮 |
| 微前端嵌套 DOM 导致选择器脆弱 | 误报 FAIL，可能挡住正确的修复 | 优先语义选择器；失败时先判断是选择器问题还是真实缺陷，选择器问题按无法覆盖处理并说明 |
| 沙箱/网络限制导致浏览器起不来 | UI 冒烟不可用 | 冒烟执行的报错原文写进证据；若为环境限制，走豁免并注明 |
| 版本校验本身失效（接口不返回版本） | 决策 6 的保护落空 | 此时降级为「等待固定时长后重试」，并在证据里注明版本未经校验 |
