#!/bin/bash
set -euo pipefail

case "${1:-}" in
  build)
    shift
    exec build-html5.sh "$@"
    ;;
  build-android)
    shift
    exec build-android.sh "$@"
    ;;
  capture)
    shift
    exec capture.sh "$@"
    ;;
  simulate)
    shift
    PROJECT="${1:-/project/main.lua}"
    # Rendering goes through EGL offscreen (Mesa llvmpipe): no X server, one
    # process less than an Xvfb path. The image sets SDL_VIDEODRIVER=offscreen
    # image-wide; run with -e SDL_VIDEODRIVER=x11 plus your own DISPLAY and X
    # socket for the interactive path.
    exec Solar2DSimulator "$PROJECT"
    ;;
  mcp)
    shift
    exec python3 /usr/local/lib/python3.11/dist-packages/server.py
    ;;
  session)
    shift
    # No display warm-up to wait for: every simulator this server spawns
    # renders offscreen through its own EGL pbuffer.
    exec timeout --signal=TERM --kill-after=5s \
      "${SOLAR2D_MCP_SESSION_TIMEOUT:-20m}" \
      python3 /usr/local/lib/python3.11/dist-packages/server.py
    ;;
  runtime)
    # Keeps the container warm for docker exec MCP clients. Video recording
    # no longer needs a shared X display: the engine frame tap streams frames
    # from each simulator's own EGL surface (SOLAR2D_VIDEO_PIPE).
    shift
    echo "Solar2D runtime ready (offscreen EGL)" >&2
    exec sleep infinity
    ;;
  *)
    echo "Solar2D Docker Image"
    echo ""
    echo "Commands:"
    echo "  build          Build HTML5 (WebAssembly) output"
    echo "  build-android  Build Android APK + AAB"
    echo "  capture        One screenshot from the headless simulator (no X)"
    echo "  simulate       Run the simulator headless (offscreen EGL)"
    echo "  mcp            Run one solar2d-mcp server in a disposable container"
    echo "  runtime        Keep a warm container for docker exec MCP clients"
    echo "  session        Run one bounded MCP session inside a warm runtime"
    echo ""
    echo "Usage:"
    echo "  docker run -v \$(pwd)/corona:/project -v \$(pwd)/output:/output solar2d build --app-name MyApp"
    echo "  docker run -v \$(pwd)/corona:/project -v \$(pwd)/output:/output solar2d build-android --app-name MyApp --package com.example.myapp"
    echo "  docker run -v \$(pwd)/corona:/project -v \$(pwd)/captures:/output solar2d capture home 320x480"
    echo "  docker run -v \$(pwd)/corona:/project solar2d simulate"
    echo "  docker run -d --init --name solar2d-runtime solar2d runtime"
    exit 0
    ;;
esac
