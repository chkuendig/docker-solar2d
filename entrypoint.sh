#!/bin/bash
set -euo pipefail

XVFB_PID=""

start_xvfb() {
  if xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
    return
  fi

  Xvfb "$DISPLAY" -screen 0 640x1390x24 +extension GLX +render -noreset >/tmp/xvfb.log 2>&1 &
  XVFB_PID=$!

  for _ in $(seq 1 100); do
    if xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
      return
    fi
    if ! kill -0 "$XVFB_PID" 2>/dev/null; then
      echo "Xvfb exited before display $DISPLAY became ready" >&2
      wait "$XVFB_PID"
      return 1
    fi
    sleep 0.1
  done

  echo "Timed out waiting for Xvfb display $DISPLAY" >&2
  stop_xvfb
  return 1
}

stop_xvfb() {
  if [ -n "$XVFB_PID" ] && kill -0 "$XVFB_PID" 2>/dev/null; then
    kill "$XVFB_PID"
    wait "$XVFB_PID" 2>/dev/null || true
  fi
}

case "${1:-}" in
  build)
    shift
    exec build-html5.sh "$@"
    ;;
  build-android)
    shift
    exec build-android.sh "$@"
    ;;
  simulate)
    shift
    PROJECT="${1:-/project/main.lua}"
    start_xvfb
    exec Solar2DSimulator "$PROJECT"
    ;;
  mcp)
    shift
    start_xvfb
    exec python3 /usr/local/lib/python3.11/dist-packages/server.py
    ;;
  session)
    shift
    if ! xdpyinfo -display "$DISPLAY" >/dev/null 2>&1; then
      echo "Solar2D runtime display $DISPLAY is not ready" >&2
      exit 69
    fi
    exec timeout --signal=TERM --kill-after=5s \
      "${SOLAR2D_MCP_SESSION_TIMEOUT:-20m}" \
      python3 /usr/local/lib/python3.11/dist-packages/server.py
    ;;
  runtime)
    shift
    start_xvfb
    echo "Solar2D runtime ready on $DISPLAY" >&2
    trap 'exit 0' INT TERM HUP
    trap stop_xvfb EXIT
    wait "$XVFB_PID"
    ;;
  *)
    echo "Solar2D Docker Image"
    echo ""
    echo "Commands:"
    echo "  build          Build HTML5 (WebAssembly) output"
    echo "  build-android  Build Android APK + AAB"
    echo "  simulate       Run the simulator with hot-reload (headless via Xvfb)"
    echo "  mcp            Run one solar2d-mcp server in a disposable container"
    echo "  runtime        Keep one Xvfb display warm for docker exec MCP clients"
    echo "  session        Run one bounded MCP session inside a warm runtime"
    echo ""
    echo "Usage:"
    echo "  docker run -v \$(pwd)/corona:/project -v \$(pwd)/output:/output solar2d build --app-name MyApp"
    echo "  docker run -v \$(pwd)/corona:/project -v \$(pwd)/output:/output solar2d build-android --app-name MyApp --package com.example.myapp"
    echo "  docker run -v \$(pwd)/corona:/project solar2d simulate"
    echo "  docker run -d --init --name solar2d-runtime solar2d runtime"
    exit 0
    ;;
esac
