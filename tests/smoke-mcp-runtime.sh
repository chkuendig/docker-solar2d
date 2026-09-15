#!/bin/bash
set -euo pipefail

IMAGE="${1:?usage: smoke-mcp-runtime.sh <image>}"
WORK_DIR="$(mktemp -d)"
PROJECT_DIR="$WORK_DIR/project"
CONTAINER="solar2d-mcp-smoke-$RANDOM"

cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir "$PROJECT_DIR"
cat > "$PROJECT_DIR/main.lua" <<'LUA'
display.setStatusBar(display.HiddenStatusBar)
display.newText({
    text = "MCP reload smoke test",
    x = display.contentCenterX,
    y = display.contentCenterY,
    fontSize = 24,
})
print("mcp-reload-smoke-ready")
LUA
cp "$PROJECT_DIR/main.lua" "$WORK_DIR/original-main.lua"

docker pull "$IMAGE"
docker run -d --init --name "$CONTAINER" \
  --cpus=1 --memory=1g --memory-swap=1g --pids-limit=128 \
  -v "$PROJECT_DIR:/project" \
  "$IMAGE" runtime >/dev/null

for _ in $(seq 1 100); do
  if docker exec "$CONTAINER" xdpyinfo -display :99 >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done
docker exec "$CONTAINER" xdpyinfo -display :99 >/dev/null

docker exec -i "$CONTAINER" python3 - <<'PY'
import asyncio
import os
import re

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


async def main() -> None:
    params = StdioServerParameters(
        command="entrypoint.sh",
        args=["session"],
        env={"DISPLAY": ":99", "HOME": "/root", "PATH": os.environ["PATH"]},
    )
    async with stdio_client(params) as streams:
        async with ClientSession(*streams) as session:
            await session.initialize()
            first = await session.call_tool(
                "run_solar2d_project", {"project_path": "/project"}
            )
            second = await session.call_tool(
                "run_solar2d_project",
                {"project_path": "/project", "reload": True},
            )

            first_text = first.content[0].text
            second_text = second.content[0].text
            assert "Launch path: fresh spawn" in first_text, first_text
            assert "Launch path: reload" in second_text, second_text
            first_pid = re.search(r"^PID: (\d+)$", first_text, re.MULTILINE)
            second_pid = re.search(r"^PID: (\d+)$", second_text, re.MULTILINE)
            assert first_pid and second_pid, (first_text, second_text)
            assert first_pid.group(1) == second_pid.group(1), (first_text, second_text)


asyncio.run(main())
PY

cmp "$WORK_DIR/original-main.lua" "$PROJECT_DIR/main.lua"
for helper in _mcp_logger.lua _mcp_screenshot.lua _mcp_touch.lua _mcp_touch_overlay.lua; do
  test ! -e "$PROJECT_DIR/$helper"
done

if docker exec "$CONTAINER" pgrep -f '[S]olar2DSimulator' >/dev/null; then
  echo "simulator survived MCP EOF" >&2
  exit 1
fi

echo "MCP fresh launch, in-place reload, EOF cleanup: passed"
