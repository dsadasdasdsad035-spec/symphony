# Tasks

## 1. 拆分 resolve 判定分支

- [x] 1.1 重写 `deploy/WORKFLOW.md` 的「开工前必须先确认问题真实存在」一节，按四条分支组织：①已由既有提交修复 ②根本不是 Bug ③能定位到真实缺陷 ④确认权限不在 agent。删除原文把「已被别的改动修好」与「需求变更/环境/数据问题」混为一条的禁令。验证：`grep -n "已被别的改动修好" deploy/WORKFLOW.md` 无输出，且一节内四条子标题齐全。
- [x] 1.2 在「已由既有提交修复」分支写入硬闸门：必须能指出一个具体 SHA，且经 GitLab API 确认该提交在目标分支上；说不出 SHA 一律回退为仅 `shanzhi_remark_bug`。验证：通读该分支，闸门句子存在、无「大概/看起来」之类的模糊放行措辞。
- [x] 1.3 在该分支写入 comment 模板，要求同时包含提交链接、提交备注（`git show -s --format=%s` 或 API `title`）、定位依据与核验结论，并指定 `resolution = "fixed"`。验证：模板中四个要素可逐一点名对应。

## 2. 写入检索与链接规范

- [x] 2.1 写明检索优先级：`shanzhi_bug_history` 历史备注 > 子模块本地 `git log`（仅当前检出分支祖先链）> GitLab `repository/commits?search=<关键词>&ref_name=<跟踪分支>`，并强调提交备注里不含 Bug 编号、只能语义匹配。验证：命令片段含 `--noproxy '*'`，可在工作区内原样粘贴执行且返回 200。
- [x] 2.2 写明链接格式 `http://192.168.175.55:9888/<project-path>/-/commit/<sha>`，并注明该 GitLab 版本 commit API 的 `web_url` 返回 `null`、不可依赖。验证：用任一已知 SHA 拼出的链接能在浏览器打开对应提交页。
- [x] 2.3 说明顶层仓库是浅克隆（`shallow=true`、`commits=1`）、子模块才是完整历史，避免 agent 在根目录 `git log` 空手而归。验证：文中明确点出该差异，且与实际 `git rev-parse --is-shallow-repository` 观察一致。

## 3. 补全仓库映射表

- [x] 3.1 在「各仓库的 GitLab 项目路径」表补 `sie-iidp-base-inner-web/` 行，分支名从工作区 `.gitmodules` 的 `submodule.<name>.branch` 实际读取后填入，不得臆测。验证：表内行数与 `.gitmodules` 的 7 个 path 一一对应，且每行 project path 均可被 GitLab API 解析。

## 4. 校验与上线

- [x] 4.1 同步 ConfigMap 并确认热加载生效。验证：`kubectl exec` 读取容器内 `/config/WORKFLOW.md`，能看到新的四条分支文本。
- [x] 4.2 确认本次未动摇既有限制：`require_confirmed` 仍为 `true`，且 agent 工具集未变。验证：`curl POST /mcp tools/list` 输出不含 `shanzhi_confirm_bug`；配置文件中 `require_confirmed: true` 仍在。
- [x] 4.3 确认无代码改动、无需重打镜像。验证：`git status --short` 仅显示 `deploy/WORKFLOW.md`（及本 change 的 openspec 文件），无 `elixir/` 变更。

## Workflow follow-up

- 本 change 完成后用 `openspec archive shanzhi-resolve-by-existing-commit` 归档。
- 归档前建议用一个真实的「已由他人修复」Bug 做一次端到端演练，确认 comment 渲染与 resolve 结果符合预期。
