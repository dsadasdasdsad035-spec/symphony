#!/usr/bin/env bash
# zcode 适配器兼容层。
#
# Symphony 的 zcode 适配器按 ZCode 桌面版自带的运行时协议启动：
#   zcode -p <prompt> --output-format stream-json --mode yolo --cwd <dir> [--resume <sid>]
# 但镜像里装的是社区 zcode-cli，它不认识 --output-format（只会打印 help），
# 只提供 --json 汇总输出。这里做一层翻译：
#
#   * 去掉 --output-format stream-json，追加 --json
#   * 把社区 CLI 的最终结果翻译成适配器认的一行 NDJSON：
#       {"type":"result","sessionId":...,"response":...,"usage":{...}}
#
# 代价：没有流式增量、也看不到工具调用明细（--json 只给汇总）。
# 非 Symphony 调用（TUI、login、app-server、--version 等）原样透传给真 CLI。
set -euo pipefail

REAL="${ZCODE_REAL_BIN:-/usr/local/bin/zcode-cli-real}"

if [ ! -x "${REAL}" ]; then
  printf 'zcode shim: 找不到真实 CLI %s（ZCODE_CLI_PKG 为空时会出现此情况）\n' "${REAL}" >&2
  exit 127
fi

stream_json=0
args=()
skip=0
for arg in "$@"; do
  if [ "${skip}" = "1" ]; then
    skip=0
    continue
  fi

  case "${arg}" in
    --output-format)
      stream_json=1
      skip=1
      ;;
    --output-format=*)
      stream_json=1
      ;;
    *)
      args+=("${arg}")
      ;;
  esac
done

if [ "${stream_json}" = "0" ]; then
  exec "${REAL}" "$@"
fi

out="$(mktemp)"
trap 'rm -f "${out}"' EXIT

set +e
"${REAL}" ${args[@]+"${args[@]}"} --json >"${out}"
status=$?
set -e

# 只取最后一个完整 JSON 对象，避免 CLI 在前面夹杂进度输出。
python3 - "${out}" <<'PY'
import json
import sys

raw = open(sys.argv[1], encoding="utf-8", errors="replace").read()

objects, index, decoder = [], 0, json.JSONDecoder()

while index < len(raw):
    while index < len(raw) and raw[index] in " \t\r\n":
        index += 1
    if index >= len(raw):
        break
    try:
        obj, index = decoder.raw_decode(raw, index)
    except ValueError:
        break
    objects.append(obj)

if not objects:
    print(json.dumps({"type": "error", "message": "zcode 未返回可解析的 JSON"}, ensure_ascii=False))
else:
    data = objects[-1]
    print(json.dumps({
        "type": "result",
        "sessionId": data.get("sessionId"),
        "response": data.get("response", ""),
        "usage": data.get("usage") or {},
    }, ensure_ascii=False))
PY

# CLI 自己失败时把退出码透传给适配器，别让上层误判成成功。
if [ "${status}" -ne 0 ]; then
  exit "${status}"
fi
