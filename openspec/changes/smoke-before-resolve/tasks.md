# Tasks

## 1. 镜像具备 UI 冒烟运行能力

- [x] 1.1 `deploy/Dockerfile` 增加 chromium 运行所需的 16 个系统库（libnss3、libnspr4、libatk-1.0-0、libatk-bridge2.0-0、libcups2、libdrm2、libxkbcommon0、libxcomposite1、libxdamage1、libxfixes3、libxrandr2、libgbm1、libasound2、libpango-1.0-0、libcairo2、libatspi2.0-0），在 root 构建阶段完成
- [x] 1.2 `deploy/Dockerfile` 安装 `playwright` Python 包并执行 `playwright install chromium`，浏览器落盘到 `/home/symphony/.cache/ms-playwright` 并归属工作用户
- [x] 1.3 构建镜像并在容器内验证：`python3 -c "from playwright.sync_api import sync_playwright"` 可导入，`chromium.launch()` 能起进程（无头），失败时报错需附缺库清单
  - 实测（arm64 验证镜像）：`import OK`，`chromium.launch(headless=True)` 成功，版本 `131.0.6778.33`，以 uid 1000 运行通过
- [x] 1.4 验证浏览器能访问 `http://192.168.181.104:30669/iidp/` 并拿到页面标题或 `#base` 节点，确认出网与目标环境可达
  - 实测：标题 `IIDP`，登录框 1 个，截图 264KB；默认 bridge 网络与 host 网络均返回 HTTP 200
- [x] 1.5 记录镜像体积与构建时长变化，若浏览器体积过大则评估改用 `chromium-headless-shell`
  - 实测：完整 chromium 542MB + 无头 shell 304MB，`chown -R` 还把整份目录复制进新层；改为 `gosu` 安装 + `--only-shell` 后浏览器目录 849MB → 307MB，镜像 5.5GB → 4.75GB（−750MB），构建约 15 分钟（含 npm 与 cursor-agent 层）

## 2. API 层冒烟脚本

> **已被 7 节取代**：2.1~2.5 的 `smoke_api.sh` 降级为内部工具（版本校验 + 手工排查），
> 接口层冒烟改为在 `iidp_uitest` 写 `testcase/api/` 用例。历史记录保留供追溯。

- [x] 2.1 新增 `deploy/smoke_api.sh`：登录 `POST {IIDP_BASE}/api/root/rpc/login/master`，密码按 base64 编码，取出 `result.data.token`
- [x] 2.2 支持以 `--model` / `--service` / `--app` / `--tag` / `--args` 参数发起业务 RPC 调用，断言返回无 `error` 字段或按预期返回错误
- [x] 2.3 未显式传参时打印可用的参数组合提示，避免 agent 猜 `app` 名（写模型名会报 `No app info in local and remote`）
- [x] 2.4 输出固定格式的结果（`PASS`/`FAIL` + 目标 + 场景 + 关键响应片段），便于直接粘贴进解决说明
- [x] 2.5 在容器内对着 `:30669` 实跑一次，确认成功路径与失败路径的输出都符合预期
  - 实测六个分支：有数据 PASS / 空结果 + `--min-rows` FAIL / 空结果无断言 PASS（带弱断言提示）/ 服务端 error FAIL / `--expect-error` PASS / 错模型名 FAIL(999)，参数缺失退出码 2
  - 期间修正两处会误导 agent 的问题：`search` 缺 `properties` 恒回空数组（新增 `--min-rows` 与告警）、提示里的 `app` 名改为真实应用名

## 3. UI 层冒烟入口

> **已被 7 节取代**：3.1~3.5 基于 `frontend_smoke.py` + 场景 JSON 的方案整体废弃，
> 界面层改为在 `iidp_uitest` 写 `testcase/iidp/iidp/` 用例。历史记录保留供追溯。

- [x] 3.1 新增 `deploy/smoke_ui.sh`：接收 `frontend-smoke.json` 路径，调用工作区内的 `frontend_smoke.py --host http://192.168.181.104:30669/iidp/ --backend http://192.168.181.104:30669`
- [x] 3.2 登录使用容器内的 `IIDP_USER` / `IIDP_PASSWORD`，不落盘、不回显
- [x] 3.3 脚本检测 `frontend_smoke.py` 与场景文件是否存在，缺失时给出明确提示而非堆栈
- [x] 3.4 失败时保底产出截图与 Console/网络日志路径，并把这些路径写入结果摘要
- [x] 3.5 在容器内对 `/iidp/` 跑一次最小场景（登录 + 一条导航），确认能拿到截图与 PASS
  - 实测 PASS，9 步全绿，截图含已登录界面；断言不成立时退出码 1 并产出 `step-XX-...-failed.png`
  - 期间修正登录时序坑：执行器点登录早于前端初始化完成，改为由脚本注入登录前奏（`--skip-login` + 4s 等待 + 等 `rpc/login` 响应），连续 3 次稳定通过，单次耗时从 35~75s 降到约 10s

## 4. 版本可见性前置校验

- [x] 4.1 确认通过哪个 API 能读到环境中指定应用的当前版本号（市场行或已安装行），把接口与字段写进 `deploy/WORKFLOW.md` 的对照表
- [x] 4.2 `smoke_ui.sh` 增加 `--expect-version` 参数：传入时先比对环境版本，一致才继续；不一致则轮询等待，超时以非 0 退出并说明
- [x] 4.3 接口读不到版本时降级为固定时长等待，并在结果里注明「版本未经校验」
- [x] 4.4 在容器内验证滞后场景：故意传一个错误版本号，确认脚本不会继续断言而是等待后失败
  - 实测：`--expect-version 999.9.9` 轮询 15s 后退出码 3，输出「环境版本未就绪」，产物目录为空（不产出误导性截图）；命中版本时正常放行并注明「已校验」

## 5. WORKFLOW.md 流程改造

- [x] 5.1 改写「工作方式」第 5 条验证要求：从「编译、单测或可复现步骤至少跑通一项」改为「必须有针对开发环境的冒烟证据，或具名豁免」
- [x] 5.2 新增「冒烟」章节，写明两层冒烟的适用边界、执行命令、目标地址，以及界面类缺陷不得仅以接口层替代
- [x] 5.3 在「发布到开发环境」与「交付方式」两节之间插入冒烟环节，明确失败分支：冒烟失败只 `shanzhi_remark_bug` 记录，不 resolve
- [x] 5.4 写入三个实测坑：密码需 base64、RPC 的 `app` 必须是真实应用名且 `tag=master`、UI 必须传显式场景文件
- [x] 5.5 写入证据五字段模板（类型/目标/场景/结果/证据引用）与豁免枚举（界面在宿主内无法直达、需要特定环境数据、不可稳定复现、其他并说明）
- [x] 5.6 指出 `.zcode/skills/iidp-smoke-test/` 的位置与用法，因为 codex agent 不会自动读取该路径下的 skill
- [x] 5.7 在「续改模式」一节补充：返工后同样需要重跑冒烟，不能沿用上一轮的证据

## 6. 上线与验证

- [ ] 6.1 构建并推送新镜像，更新 `deploy/k8s/deployment.yaml` 的 tag，滚动完成后确认 Pod 正常
- [ ] 6.2 通过 ConfigMap 同步 `WORKFLOW.md`，确认热加载生效（`/config/WORKFLOW.md` 可见新章节）
- [ ] 6.3 用一个真实善治 Bug 走完整流程，检查生成的解决说明里证据段落是否齐全、格式是否符合模板
- [ ] 6.4 构造一个 UI 无法覆盖的场景，确认豁免段落含枚举原因与替代验证，而非笼统表述
- [x] 6.5 复盘首轮真实执行数据，判断是否具备升级为硬闸门的条件，并把结论写回 `openspec/changes/smoke-before-resolve/design.md` 的风险表
  - 结论：已由变更 `smoke-hard-gate-ui-mandatory` 落地硬闸门（`ResolveGate` + `smoke-pass.json` + WORKFLOW 八段式）；软闸门阶段结束。

## 7. 冒烟统一到 iidp_uitest（UI + API 同一仓库）

背景：自己写 scenario JSON / curl 拼接存在三处长期成本——元素定位散落在场景文件里改版就碎、
断言逻辑随 bug 一次性丢弃无法复用、评审无法复跑。`iidp_uitest`（`http://192.168.175.55:9888/xuchunxia/iidp_uitest.git`）
把元素库（1957 条）、页面方法库（按域拆分）、pytest/Allure 留证都做完了，直接复用。

- [x] 7.1 确认 `iidp_uitest` 的纯 API 能力：`testcase/api/<产品>/` + `@pytest.mark.api` 时
  conftest 的 `_is_non_ui_test` 跳过浏览器/trace/GIF/截图钩子
  - 实测 `testcase/api/iidp/test_smoke_probe_api.py`：0.23s 通过，全程无浏览器进程
- [x] 7.2 `deploy/smoke_ui.sh` 改名 `deploy/smoke_test.sh`，成为 UI/API 两层唯一入口；
  层级按用例路径自动判定（`testcase/api/` → API，其余 → UI），结果里写明「类型: API/UI」
- [x] 7.3 加层级一致性核对：`@pytest.mark.api` 标了但不在 `testcase/api/` 下时告警
  （框架仍会启浏览器，与直觉相反，必须提前说清）
- [x] 7.4 运行时浅克隆仓库到 `${SYMPHONY_WORKSPACE_ROOT}/.uitest` 并跨 issue 复用；
  `--depth 1 --single-branch`，带 `GITLAB_TOKEN` 时自动注入 URL
- [x] 7.5 `conf/active.ini` 与 `config.local.ini` 按 `$IIDP_BASE` / `$IIDP_USER` / `$IIDP_PASSWORD`
  临时生成（口令文件 0600，退出还原 active.ini 并删除临时文件）
- [x] 7.6 `deploy/Dockerfile` 补齐 uitest 依赖：`playwright==1.55.0`（与仓库锁定版本一致）、
  `xlrd`（`stacks/iidp/page_api/api.py` 顶层 import）、`paho-mqtt`/`tornado`/`python-docx`/`python-pptx`；
  `PIP_INDEX_URL` 默认清华源（直连 pythonhosted 实测读超时）
- [x] 7.7 `smoke_api.sh` 降级为内部工具：只给 `smoke_test.sh` 读版本号、给人工排查打单条 RPC，
  WORKFLOW.md 里明确写「不要用它充当接口层冒烟」
- [x] 7.8 更新 `deploy/WORKFLOW.md`：选层表改为「用例放哪」、新增用例仓库说明、
  UI/API 两层各一段最小用例范例、坑表换成 uitest 相关（登录时序、`login_if_needed`、`properties`）
- [x] 7.9 更新 `deploy/k8s/apply.sh` 的 ConfigMap key（`smoke_ui.sh` → `smoke_test.sh`）
  与 `deploy/entrypoint.sh` 的环境变量（`SMOKE_UI_SH` → `SMOKE_TEST_SH`）
- [x] 7.10 本地实跑两层：API 层 PASS 0.2s，UI 层 PASS 10.7s（含截图 1 张）
- [x] 7.11 盘点 uitest 自带资产，挑出对冒烟可用的：`stacks/iidp/skills/SKILL.md` 决策表、
  `testcase-templates-iidp.md`、`.claude/skills/framework-reference.md`、`debug-reference.md`、
  `stacks/iidp/selfcheck.py`、`.claude/tools/extract_method.py`。`api-testing` 不用——
  它带 protocol_ready 门禁 + workflow YAML + 用例评审，是建体系的流程，冒烟会卡在门禁里
- [x] 7.12 新增 skill `deploy/skills/iidp-smoke/SKILL.md`（引用式：具体规则指向缓存仓库原文件，
  仓库更新即生效），Dockerfile 烘到 `$HOME/{.codex,.claude,.cursor}/skills/iidp-smoke`
- [x] 7.13 `smoke_test.sh` 界面层接入 `selfcheck.py` 门禁：命中风险点即拒跑、退出码 1、
  日志落 `selfcheck.log`；找不到 selfcheck.py 时降级为告警不阻断
  - 实测：原生 locator 的探针被拦（退出码 1，未进 pytest）；合规探针放行并跑绿 41s
- [x] 7.14 重建镜像并推 `v9`，容器内跑通两层
  - 镜像 1.7GB（不含 cursor-agent 约省 700MB；chromium 只装 headless shell 再省 540MB）
  - 容器内实测：codex-cli 0.169.0（平台二进制在位）、claude 2.1.326、zcode 在位、
    三处 skill 路径均可读、Python 依赖齐全、chromium headless shell 在位
  - 接口层 PASS 17.8s；界面层 PASS 45.9s（内含 1 张截图）；自检门禁正常放行合规用例
- [x] 7.15 克隆认证方式修正：`http.extraHeader=PRIVATE-TOKEN` 对 git 传输无效
  （会退化成交互式问用户名，容器里直接 "could not read Username"）；改用
  `Authorization: Basic base64(oauth2:<token>)`，token 不落 URL 不进 .git/config
- [x] 7.16 npm 源改华为云镜像：codex 的平台二进制是 167MB optional 依赖，
  registry.npmjs.org 实测 331KB/s 且断流，华为云 2.08MB/s、137s 装完
- [x] 7.17 cursor-agent 改为可跳过：其 130MB 安装包在本网络反复截断；
  置空 `CURSOR_INSTALL_URL` 即跳过，下载失败也只告警不中断构建
- [x] 7.18 codex 安装加固：optional 依赖下载失败是静默的（exit 0 但缺二进制），
  改为装完即验 `codex --version` + 最多 3 次重试 + 缺失则整层明确失败
- [ ] 7.19 用真实 bug 走一轮：Agent 写用例 → 提交 uitest 分支 → 提 MR → 冒烟 → resolve 备注里贴 MR 链接
  > 报告**发到哪个仓库**的 MR，已由变更 `fix-smoke-report-target` 单独立规：
  > 用 `--mr-dir <改动所在子目录>` 推导目标，聚合仓库的指针 MR 会被拒绝。此处只跟端到端流程。
