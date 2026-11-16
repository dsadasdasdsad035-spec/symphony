#!/usr/bin/env python3
"""善治 MCP 服务自检：按 MCP 协议走一遍 initialize / tools/list / tools/call。

只依赖标准库，直接跑在镜像里：
    python3 /opt/shanzhi-mcp/bin/mcp-probe

凭证来自 entrypoint 生成的 config.json（SF_MCP_CONFIG 指向它）。
"""

import json
import os
import subprocess
import sys

LAUNCHER = "/opt/shanzhi-mcp/bin/shanzhi-mcp"


def main() -> int:
    cfg = os.environ.get("SF_MCP_CONFIG", os.path.expanduser("~/.config/shanzhi-mcp/config.json"))
    if not os.path.exists(cfg):
        print(f"缺少配置文件: {cfg}（检查 .env 的 SF_USERNAME / SF_PASSWORD）", file=sys.stderr)
        return 2

    proc = subprocess.Popen(
        [LAUNCHER],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env={**os.environ, "SF_MCP_CONFIG": cfg},
    )

    def send(payload: dict) -> None:
        assert proc.stdin is not None
        proc.stdin.write(json.dumps(payload) + "\n")
        proc.stdin.flush()

    def recv() -> dict:
        assert proc.stdout is not None
        while True:
            line = proc.stdout.readline()
            if not line:
                detail = proc.stderr.read()[:600] if proc.stderr else ""
                raise SystemExit(f"服务进程提前退出:\n{detail}")
            line = line.strip()
            if line.startswith("{"):
                return json.loads(line)

    try:
        send(
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {},
                    "clientInfo": {"name": "symphony-probe", "version": "1"},
                },
            }
        )
        info = recv()["result"]["serverInfo"]
        send({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})

        send({"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}})
        tools = [tool["name"] for tool in recv()["result"]["tools"]]

        send(
            {
                "jsonrpc": "2.0",
                "id": 3,
                "method": "tools/call",
                "params": {"name": "list_projects", "arguments": {}},
            }
        )
        result = recv()["result"]
        text = (result.get("content") or [{}])[0].get("text", "")

        print(f"服务: {info.get('name')} {info.get('version')}")
        print(f"工具: {', '.join(tools)}")
        ok = not result.get("isError")
        print(f"list_projects: {'成功' if ok else '失败'} | {text[:160].replace(chr(10), ' ')}")
        return 0 if ok else 1
    finally:
        proc.terminate()


if __name__ == "__main__":
    sys.exit(main())
