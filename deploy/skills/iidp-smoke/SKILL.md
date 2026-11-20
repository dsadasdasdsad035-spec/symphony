---
name: iidp-smoke
description:
  Use when 需要在开发环境为善治 Bug 写冒烟验证用例（UI 或 API 层），或要理解
  testcase/api 与 testcase/iidp 的目录约定、查 iidp_uitest 的页面方法签名、
  判断一段验证逻辑该写成 UI 用例还是接口用例时。触发词：冒烟、smoke、验证用例、
  uitest、drivers fixture、login_if_needed。
---

# IIDP 冒烟用例（iidp_uitest）

本 skill 只讲**怎么写用例**。跑用例用 `smoke_test.sh`，证据模板与硬闸门见 `WORKFLOW.md`。

## 零、先于用例：写 `smoke/smoke-requirement.json`

在缺陷工作区（`$SYMPHONY_WORKSPACE_ROOT/SF-xxxxx/`）创建：

```json
{
  "schema_version": 1,
  "required_layers": "UI",
  "rationale": "依据善治复现步骤判定",
  "repro_keywords": ["点击", "弹窗"]
}
```

- `API` / `UI` / `BOTH` 与善治描述一致；**界面为主不能标 API**。
- BOTH 需要各跑一层 `smoke_test.sh`，通行证合并进同一 `smoke-pass.json` 的 `passes[]`。
- 再写 uitest 用例、提 MR；发版后 `--issue SF-xxxxx --publish-report` 写通行证。

用例仓库在 `/data/workspaces/.uitest`（即 `$SYMPHONY_WORKSPACE_ROOT/.uitest`），
由 `smoke_test.sh` 首次运行时浅克隆。下文所有路径都相对这个仓库根。

```bash
cd "${SYMPHONY_WORKSPACE_ROOT:-$HOME/.cache}/.uitest"
```

---

## 一、先决定写哪一层

层级不是风格偏好，它决定 conftest 会不会起浏览器——判错的代价是白等一次登录。

| 缺陷表现 | 写哪 | 放哪 |
|---|---|---|
| 接口返回错、数据错、状态流转错、权限错 | 接口层 | `testcase/api/iidp/test_<号>_smoke.py` |
| 点击无反应、弹窗不弹、样式错位、路由错、微前端没挂上 | 界面层 | `testcase/iidp/iidp/test_<号>_smoke.py` |
| 既涉及接口又涉及界面 | 界面层 | 界面层可调接口封装，反之不行 |

**判层靠路径前缀，不是靠 marker**。`conftest.py` 的 `_is_non_ui_test()` 只认
`testcase/api/` 开头（以及 `stacks/*/tests/`），命中就跳过浏览器、trace、GIF 和
失败截图钩子。写了 `@pytest.mark.api` 但放在 `testcase/iidp/` 下，照样起浏览器。

纯 UI 缺陷不得只用接口层验：接口 200 只证明后端逻辑通，界面上该渲染的没渲染、
按钮该亮还是灰的，这些不在响应里。

---

## 二、界面层用例

### 骨架

```python
# -*- coding: utf-8 -*-
import allure


@allure.feature("<功能名>")
class Test_<缺陷号>:

    def test_<缺陷现象>(self, drivers):
        page, api, cdp = drivers        # drivers 已按 conf 里的 host 打开页面
        assert api.login_if_needed(api.username, api.passwd) is True

        api.click_menu('应用管理', '已安装应用')
        assert api.search_app_installed('sie-iidp-de-tool'), "搜索后未拿到应用行"
```

### 三条硬规则

1. **登录只用 `login_if_needed(username, passwd)`**。`login()` 非幂等——已登录状态下
   调用会卡在等登录页文本，然后往错误位置输入。单 class 内多条用例、或多个 class 串联
   时必踩。
2. **不要在用例里写口令**。`api.username` / `api.passwd` 已从 `config.local.ini`
   读好（默认 `implementer`），直接用。
3. **不要写原生定位**。`page.locator(...)`、`page.evaluate(...)`、`.fill()`、
   `.text_content()` 都会被 `selfcheck.py` 判为风险点并拦下。走元素库 index + 封装方法，
   规范见 `.claude/skills/framework-reference.md`。

### 挑方法：先查决策表，别自己拼

`stacks/iidp/skills/SKILL.md` 的「场景 → 方法快速决策表」是选型的唯一依据
（该文件 763 行、80KB+，**禁止整读**）：

```bash
# 找某一类操作的推荐方法
grep -nE "^\| .*表单下拉|^\| .*表格行内" stacks/iidp/skills/SKILL.md

# 只看决策表所在区间
sed -n '84,230p' stacks/iidp/skills/SKILL.md
```

高频几条（完整以决策表为准）：

| 要做什么 | 方法 |
|---|---|
| 打开菜单（两级） | `click_menu('一级', '二级')` |
| 打开菜单（三级及以上 / 重名层级） | `open_menu_by_path(*path)` |
| 切到已打开的页签 | `switch_menu_tab('页签名')`（返回 False 说明没开） |
| 带 label 的表单填写 | `form_input(input={...}, selection={...}, diag={...}, textarea={...})` |
| 只有 placeholder 的搜索框 | `common_input_with_placeholder(placeholder, value, input_index=0)` |
| 页面文本按钮 | `click_btn('按钮文本', btn_index=0)` |
| 弹窗 / 抽屉底部按钮 | `click_div_btn(...)` / `click_drawer_btn(...)` |
| 表格行内按钮 | `click_btn_in_grid('按钮文本', header_name='操作', row_index=0)` |
| 表格整列取值做断言 | `get_all_cell_by_header(column_name, visible_text=True)` |
| 保存/删除后等提示 | `loading_is_finish('新增成功')` |

### 查签名：不要靠猜

```bash
# 按方法名精确取源码
python .claude/tools/extract_method.py form_input

# 按关键词列出候选（只出签名 + docstring 首行）
python .claude/tools/extract_method.py -k search --sig

# 限定域文件
python .claude/tools/extract_method.py -f stacks/iidp/page_api/api_meta_app.py --sig
```

### 断言

- 每条 `test_` 至少一个 `assert`（`selfcheck.py` 会查）。
- 断言落在**稳定事实**上：查询结果、回显值、列表行数。不断言"弹窗出现了"这种中间态。
- 中间步骤不断言，多个验证点先取齐值再统一断言——fail-fast 会丢掉后续证据。
- 反向用例（预期被拦截）先关弹窗再断言，不要留着遮罩影响后续。

### 文件头与租户前置

需要租户环境时，用 `stacks/iidp/skills/testcase-templates-iidp.md` 第 3 节的
标准 `prepare` fixture（登录平台管理员 → 查/建 `ui自动化测试租户` → 授权 →
退出 → 租户管理员登录 → 切租户 → 进首页）。普通冒烟一般不需要，别照抄。

---

## 三、接口层用例

### 骨架

```python
# -*- coding: utf-8 -*-
import base64
import requests
import pytest
from tools.operate_config import OperateConfig


@pytest.mark.api
def test_<缺陷号>_<现象>():
    conf = OperateConfig()
    env = conf.get_node_value('ENV', 'env')
    login_url = conf.get_node_value(env, 'login_url')   # 由 host 派生，不要手拼
    api_url = conf.get_node_value(env, 'api_url')
    user = conf.get_node_value(env, 'username', default='implementer')
    pwd = conf.get_node_value(env, 'passwd', default='Implementer_2023')

    r = requests.post(login_url, json={
        "id": "guid", "jsonrpc": "2.0", "method": "login",
        "params": {"app": "base", "args": {}, "login": user,
                   "password": base64.b64encode(pwd.encode()).decode(),
                   "remember": False},
    }, timeout=30)
    assert r.status_code == 200
    token = r.json()['result']['data']['token']

    r2 = requests.post(api_url, json={
        "id": "guid", "jsonrpc": "2.0", "method": "service",
        "params": {"args": {"useDisplayForModel": True,
                            "filter": [["name", "=", "<目标名>"]],
                            "limit": 2, "offset": 0, "order": "",
                            "properties": ["name", "version"]},
                   "context": {"uid": "", "timeZone": "UTC+8", "lang": "zh-CN"},
                   "model": "<model>", "tag": "master", "service": "search",
                   "app": "<真实应用名>"},
    }, headers={"Authorization": "Bearer " + token}, timeout=30)
    body = r2.json()
    assert 'error' not in body, f"RPC 报错: {body.get('error')}"
    assert len(body['result']['data']) >= 1, f"返回空数组: {body}"
```

### 四个必踩坑

| 现象 | 原因 | 处理 |
|---|---|---|
| `-32602 用户名或密码错误` | 口令传了明文 | 必须 base64 |
| `search` 恒返回 `[]`，接口 200 无报错 | 入参缺 `properties` | 查询类必须带 `properties` + `useDisplayForModel` |
| `400 No app info in local and remote` | `app` 填了模型名 | `app` 填真实应用名，`tag` 用 `master` |
| 用例跑得很慢、还起了浏览器 | 文件不在 `testcase/api/` 下 | 挪进 `testcase/api/iidp/` |

地址别写死：`login_url` / `api_url` / `upload_api_url` 都从 `host` 派生。

---

## 四、提交前自检

```bash
# 界面层必跑（会拦原生定位、缺断言、方法误用；--fix 自动修可确定项）
python stacks/iidp/selfcheck.py testcase/iidp/iidp/test_<号>_smoke.py --fix
```

接口层框架没有对应的 selfcheck（`selfcheck_api.py` 不存在），对照上面「四个必踩坑」自查。

`smoke_test.sh` 跑界面层用例前会先执行这一步，有风险点直接拒跑。

---

## 五、跑失败怎么改

不要反复整类重跑。读现场证据 → 改文件 → 单条续跑：

```bash
# 首次：跑整个 class，建立业务状态
python -m pytest testcase/iidp/iidp/test_x.py::Test_x -v -s --alluredir report/tmp

# 修复后：单条续跑，自动带回上次的 global_data
python -m pytest testcase/iidp/iidp/test_x.py::Test_x::test_y -v -s \
  --alluredir report/tmp --resume
```

证据在 `report/screenshot`、`report/dom`、`report/trace`。
完整调试红线见 `.claude/skills/debug-reference.md`。

---

## 六、提交用例

```bash
git checkout -b smoke/<善治缺陷号>-<简短描述>
git add -A
git commit -m "test: <缺陷号> <验的是什么行为>"
git push -u origin HEAD
```

到 GitLab 提 MR，链接贴进 resolve 备注。分支名带缺陷号，评审能对上号；
合入后后续同类缺陷直接跑现成用例。

### 报告也要发出去（`--publish-report`）

善治备注只能写 HTML 文本，没有附件接口，所以报告要跟代码走：发到**修复这个 bug 的
MR 评论**上。用例在 uitest，验证结果贴着代码，评审在同一个 MR 里既看 diff 也看运行结果。

```bash
smoke_test.sh --case testcase/api/iidp/test_xxx_smoke.py \
  --publish-report --mr-dir <改动所在的子目录> --mr <MR 序号>
```

- `--mr-dir` 指**本次改动所在的子目录**（如 `sie-snest`、`sie-iidp-ai-agent-web`），
  脚本读该目录的 `origin` 得到项目路径——不要手填项目路径，手填时最容易顺着
  cwd 填成聚合仓库 `mijiuye/iidp-aios`。
- **聚合仓库的指针 MR 不是目标**：它的 diff 只有一行 `Subproject commit`。
  只有缺陷本身只改根仓库（`openspec/`、`docs/`、`AGENTS.md`）时才发到聚合仓库，
  那时用 `--mr-dir .`。脚本发布前会核对目标 MR 的改动，全是指针推进就拒绝发送、
  退出码 4，并告诉你该用哪个子目录。
- `--gl-project <项目路径>` 仍可用，与 `--mr-dir` 同时给出时以 `--mr-dir` 为准。
  **不能是 uitest**——发到用例仓库，改代码的 MR 里就没有验证证据，脚本会直接拒绝。
- 改了多个仓库时发给承载该缺陷的那个，其余 MR 里贴一行链接指回该评论。
- 脚本会把报告作为评论发出，截图先上传成 GitLab 的 `/uploads/...` 图，评论里直接显示。
- 同时生成 `evidence.html`：一段带结论、版本、耗时、评论链接和 MR 链接的 HTML，
  整段作为 `shanzhi_remark_bug` 的 comment 即可。
- MR 还没建时不带 `--mr-dir/--gl-project/--mr`，只产出本地 `report.md` 与 `evidence.html`；
  工作区 resolve 后会被销毁，**交付前必须把报告发出去**。

缓存目录被别人 `git pull` 更新过，**你的用例写在分支上，别提交到 master**。
`smoke_test.sh` 运行期间对缓存目录加了 `flock`，手工改代码时若正撞上别的冒烟在跑，
等它结束再提交。

---

## 七、不要做的事

- 不要为了一次验证新建独立脚本框架、场景 JSON 或 curl 组合——用例就放上面两个目录。
- 不要给 `stacks/iidp/page_api/` 加新方法（那是框架资产，要改走 uitest 的 MR 评审）；
  冒烟要的新操作先用现有方法拼。
- 不要在 `.uitest` 里改 `conf/active.ini` / `config.local.ini`——`smoke_test.sh`
  会在运行时生成并在退出时还原，你的改动会被覆盖。
- 不要把 UI 用例写成"打开菜单、截个图"就算验证——必须有 `assert`。
