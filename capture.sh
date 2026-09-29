#!/bin/bash
#=============================================================================
# capture.sh <label> <contentWxH> [delay-ms]
#
# One screenshot of a Solar2D project from the headless simulator, offscreen
# (EGL/llvmpipe — no X server). Writes /output/<label>.png.
#
#   entrypoint: capture home 320x480 3000
#   env:        SOLAR2D_CAP_PROJECT (default /project), SOLAR2D_CAP_OUT
#               (default /output)
#
# Works on a scratch copy of the project, never the mounted original, because
# two things have to be patched for a deterministic headless capture:
#
#  - the content box is pinned by appending to config.lua (headless runs do
#    not report display.pixelWidth until the window is up);
#  - the simulator persists its window geometry in the sandbox's app.conf;
#    writing it before the run pins the surface the offscreen driver creates.
#
# Any other environment variables present in the container reach the project
# unchanged — projects select their own preview scenes and fixtures through
# env vars of their choosing.
#=============================================================================
set -euo pipefail

LABEL=${1:?usage: capture <label> <contentWxH> [delay-ms]}
SCREEN=${2:?usage: capture <label> <contentWxH> [delay-ms]}
DELAY=${3:-14000}
PROJECT="${SOLAR2D_CAP_PROJECT:-/project}"
OUT="${SOLAR2D_CAP_OUT:-/output}"

[[ $SCREEN =~ ^[0-9]+x[0-9]+$ ]] || {
    echo "capture: content box '$SCREEN' is not <width>x<height>" >&2
    exit 2
}
[[ $DELAY =~ ^[0-9]+$ ]] || {
    echo "capture: delay-ms '$DELAY' is not a number" >&2
    exit 2
}
[[ $LABEL =~ ^[A-Za-z0-9._-]+$ ]] || {
    echo "capture: label '$LABEL' may only contain letters, digits, dot, underscore, dash" >&2
    exit 2
}

[ -f "$PROJECT/main.lua" ] || {
    echo "capture: no main.lua in $PROJECT — is the project mounted?" >&2
    exit 2
}

WORK=$(mktemp -d /tmp/solar2d-cap-XXXXXX)
SRC="$WORK/project"
SANDBOX="$HOME/.Solar2D/Sandbox"
trap 'rm -rf "$WORK"' EXIT

cp -a "$PROJECT/." "$SRC/"
rm -rf "$SRC/.git"

# Pin the content box. Appended, so it works for any config.lua that builds
# application.content — table constructors run top to bottom, so a later
# assignment of width/height/scale wins wherever the table is defined.
DEVW=${SCREEN%x*}; DEVH=${SCREEN#*x}
cat >> "$SRC/config.lua" <<LUA

-- content-box pin (scratch copy only)
local _w, _h = tonumber(os.getenv("SOLAR2D_CAP_WIDTH")), tonumber(os.getenv("SOLAR2D_CAP_HEIGHT"))
if _w and _h and application and application.content then
    application.content.width, application.content.height, application.content.scale = _w, _h, "letterbox"
end
LUA

# Pin the window geometry the offscreen surface is created at.
mkdir -p "$SANDBOX/project"
printf 'h=%s\ntitle=project\nw=%s\nx=0\ny=0\n' "$DEVH" "$DEVW" > "$SANDBOX/project/app.conf"

# Capture hook. Prepended to main.lua (a project may end main.lua with
# `return`, which would make an appended block a syntax error blamed on the
# project), and self-contained. Scratch copy only; nothing here ships.
HOOK=$(mktemp /tmp/solar2d-cap-hook-XXXXXX)
cat > "$HOOK" <<'LUA'
-- capture hook (scratch copy only)
do
    local name = os.getenv("SOLAR2D_CAP_NAME")
    if name then
        local delay = tonumber(os.getenv("SOLAR2D_CAP_DELAY")) or 14000
        timer.performWithDelay(delay, function()
            print("[CAP] pixels " .. display.pixelWidth .. "x" .. display.pixelHeight
                .. " content " .. display.contentWidth .. "x" .. display.contentHeight
                .. " actual " .. display.actualContentWidth .. "x" .. display.actualContentHeight
                .. " origin " .. display.screenOriginX .. "," .. display.screenOriginY)
            display.save(display.currentStage, { filename = name .. ".png",
                baseDir = system.DocumentsDirectory,
                captureOffscreenArea = false, isFullResolution = false })
            timer.performWithDelay(2000, function() os.exit(0) end)
        end)
    end
end
LUA
cat "$HOOK" "$SRC/main.lua" > "$SRC/main.lua.tmp" && mv "$SRC/main.lua.tmp" "$SRC/main.lua"
rm -f "$HOOK"

mkdir -p "$OUT"
rm -f "$OUT/$LABEL.png"
find "$SANDBOX" -name "$LABEL.png" -delete 2>/dev/null || true

LOG="$WORK/capture.log"
export SOLAR2D_CAP_NAME="$LABEL" SOLAR2D_CAP_DELAY="$DELAY"
export SOLAR2D_CAP_WIDTH="$DEVW" SOLAR2D_CAP_HEIGHT="$DEVH"
export SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-offscreen}"
# Bounded: a project that errors before its first frame, or a hook that never
# fires, must hang CI for minutes — not forever.
TIMEOUT=$(( DELAY / 1000 + 60 ))
timeout --signal=TERM --kill-after=5s "$TIMEOUT" \
    Solar2DSimulator "$SRC/main.lua" > "$LOG" 2>&1 || true

# A Lua syntax error does not stop the simulator: the file fails to load and
# the run carries on with the defaults — a capture that answers a different
# question than the one asked.
if grep -q '^ERROR: Syntax error' "$LOG"; then
    grep -A2 '^ERROR: Syntax error' "$LOG" >&2
    echo "capture: the simulator reported a Lua syntax error; full log in $LOG" >&2
    exit 1
fi

# The hook prints [CAP] on the frame it saves; its absence means the project
# never got that far. (Unanchored: Solar2D prints WARNING: with no trailing
# newline, so a ^-anchored match drops the line glued after it.)
grep -aoE '\[CAP\].*' "$LOG" >/dev/null || {
    echo "capture: the simulator printed no [CAP] frame for $LABEL; full log:" >&2
    tail -20 "$LOG" >&2
    exit 1
}

find "$SANDBOX" -name "$LABEL.png" -exec cp {} "$OUT/" \;
[ -f "$OUT/$LABEL.png" ] || {
    echo "capture: no $LABEL.png under $SANDBOX after the run; full log in $LOG" >&2
    exit 1
}

# A file is not a capture: the PNG signature, its IEND, a floor on the size
# (a uniform frame is ~5k at 320x480; a rendered screen does not come in
# under 8k) and the declared dimensions separate real captures from
# truncated or blank writes.
bytes=$(wc -c < "$OUT/$LABEL.png")
magic=$(od -An -tu1 -N8 "$OUT/$LABEL.png" | tr -s ' ' | sed 's/^ //;s/ *$//')
[ "$magic" = "137 80 78 71 13 10 26 10" ] || {
    echo "capture: $LABEL.png is not a PNG ($bytes bytes)" >&2
    exit 1
}
tail_bytes=$(od -An -tu1 -j "$((bytes - 8))" -N8 "$OUT/$LABEL.png" | tr -s ' ' | sed 's/^ //;s/ *$//')
[ "$tail_bytes" = "73 69 78 68 174 66 96 130" ] || {
    echo "capture: $LABEL.png stops before its IEND — the write did not finish ($bytes bytes)" >&2
    exit 1
}
[ "$bytes" -ge 8192 ] || {
    echo "capture: $LABEL.png is $bytes bytes, too small to hold a rendered screen" >&2
    exit 1
}
size=$(od -An -tu1 -j16 -N8 "$OUT/$LABEL.png" | awk '{
    printf "%dx%d\n", $1*16777216 + $2*65536 + $3*256 + $4, $5*16777216 + $6*65536 + $7*256 + $8 }')
case "$size" in
    ""|0x*|*x0)
        echo "capture: $LABEL.png declares no pixels ($size)" >&2
        exit 1 ;;
esac
[ "$size" = "$SCREEN" ] || echo "capture: WARNING $LABEL is $size, not the requested $SCREEN" >&2
echo "captured $LABEL.png $size"
