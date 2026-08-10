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
  simulate)
    shift
    PROJECT="${1:-/project/main.lua}"
    Xvfb :99 -screen 0 640x1390x24 +extension GLX +render -noreset &>/dev/null &
    sleep 1
    export DISPLAY=:99
    exec Solar2DSimulator "$PROJECT"
    ;;
  mcp)
    shift
    Xvfb :99 -screen 0 640x1390x24 +extension GLX +render -noreset &>/dev/null &
    sleep 1
    export DISPLAY=:99
    exec python3 /usr/local/lib/python3.11/dist-packages/server.py
    ;;
  *)
    echo "Solar2D Docker Image"
    echo ""
    echo "Commands:"
    echo "  build          Build HTML5 (WebAssembly) output"
    echo "  build-android  Build Android APK + AAB"
    echo "  simulate       Run the simulator with hot-reload (headless via Xvfb)"
    echo "  mcp            Run the solar2d-mcp server (stdio, launches simulator internally)"
    echo ""
    echo "Usage:"
    echo "  docker run -v \$(pwd)/corona:/project -v \$(pwd)/output:/output solar2d build --app-name MyApp"
    echo "  docker run -v \$(pwd)/corona:/project -v \$(pwd)/output:/output solar2d build-android --app-name MyApp --package com.example.myapp"
    echo "  docker run -v \$(pwd)/corona:/project solar2d simulate"
    exit 0
    ;;
esac
