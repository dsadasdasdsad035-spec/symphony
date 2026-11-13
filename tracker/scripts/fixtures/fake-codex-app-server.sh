#!/bin/sh
# 模拟 codex app-server：读 4 行 JSON-RPC 后正常结束（供 Symphony E2E 派发验收）
count=0
while IFS= read -r line; do
  count=$((count + 1))
  case "$count" in
    1) printf '%s\n' '{"id":1,"result":{}}' ;;
    2) ;;
    3) printf '%s\n' '{"id":2,"result":{"thread":{"id":"thread-e2e"}}}' ;;
    4)
      printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-e2e"}}}'
      printf '%s\n' '{"method":"turn/completed"}'
      exit 0
      ;;
    *) ;;
  esac
done
