#!/bin/bash
#=============================================================================
# walk.sh <steps-file>
#
# Drive a Solar2D project through a list of input steps in the headless
# simulator (offscreen EGL, no X server) and collect a named screenshot per
# step — for flows a single timed frame cannot show: taps open menus, keys
# navigate, text lands in fields. `capture` is the one-step special case.
#
#   entrypoint: walk /path/to/steps
#   env:        SOLAR2D_WALK_PROJECT    project dir (default /project)
#               SOLAR2D_WALK_OUT        output dir (default /output)
#               SOLAR2D_WALK_SCREEN     content box WxH (default 320x480)
#               SOLAR2D_WALK_VIDEO      1 = also record walk.mp4 (frame tap)
#               SOLAR2D_WALK_EXPECT_MS  timeout for expect steps (default 30000)
#
# Steps, one per line; blank lines and #-comments allowed:
#
#   wait <ms>                 let the app run (fails early if it exits)
#   expect <marker>           block until the app prints <marker> on stdout
#   fail <marker>             abort the walk the moment <marker> is printed
#   snap <label>              save <label>.png (letters, digits, dot, _, -)
#   tap|wtap|drag|key|text …  any input-FIFO command, verbatim: content
#                             coordinates, dispatched as real SDL events
#
# Every input step waits for its "[INPUT]" ack on stdout and fails if the
# engine ignored it; a drag additionally waits for its own duration. Every
# snap waits for the hook's "[WALK] snap" line. A step that never acks fails
# the walk instead of silently desynchronising the labels.
#
# `key` takes SDL key names (return, escape, left, f13, a, …). The app sees
# Solar2D key names, which differ for some keys: SDL "return" arrives as
# keyName "enter".
#
# Works on a scratch copy of the project, never the mounted original: the
# content box is pinned by appending to config.lua, the window geometry is
# pre-written into the sandbox's app.conf, and the snap hook is prepended to
# main.lua. Any other environment variables reach the project unchanged, so
# projects pick their own preview scenes and fixtures through env vars of
# their choosing.
#=============================================================================
set -euo pipefail

STEPS=${1:?usage: walk <steps-file>}
PROJECT="${SOLAR2D_WALK_PROJECT:-/project}"
OUT="${SOLAR2D_WALK_OUT:-/output}"
SCREEN="${SOLAR2D_WALK_SCREEN:-320x480}"
WANT_VIDEO="${SOLAR2D_WALK_VIDEO:-0}"
EXPECT_MS="${SOLAR2D_WALK_EXPECT_MS:-30000}"
SNAP_KEY="${SOLAR2D_WALK_SNAP_KEY:-f13}"
SNAP_CODE="${SOLAR2D_WALK_SNAP_CODE:-1073741928}"

[[ $SCREEN =~ ^[0-9]+x[0-9]+$ ]] || {
    echo "walk: content box '$SCREEN' is not <width>x<height>" >&2
    exit 2
}
[[ $EXPECT_MS =~ ^[0-9]+$ ]] || {
    echo "walk: SOLAR2D_WALK_EXPECT_MS '$EXPECT_MS' is not a number" >&2
    exit 2
}
[ -f "$STEPS" ] || {
    echo "walk: steps file '$STEPS' not found" >&2
    exit 2
}
[ -f "$PROJECT/main.lua" ] || {
    echo "walk: no main.lua in $PROJECT — is the project mounted?" >&2
    exit 2
}

WORK=$(mktemp -d /tmp/solar2d-walk-XXXXXX)
LOG="$WORK/walk.log"
SRC="$WORK/project"
SANDBOX="$HOME/.Solar2D/Sandbox"
SIM_PID=""
FFMPEG_PID=""
cleanup() {
    [ -n "$SIM_PID" ] && kill "$SIM_PID" 2>/dev/null || true
    [ -n "$FFMPEG_PID" ] && kill "$FFMPEG_PID" 2>/dev/null || true
    # The simulator's full output stays with the snapshots, success or not:
    # it carries the app's markers and every ack, and is the first thing to
    # read when a walk fails or a frame surprises.
    [ -f "$LOG" ] && mkdir -p "$OUT" && cp "$LOG" "$OUT/walk.log" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

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
rm -f "$SANDBOX/project/Documents/"_walk-*.png 2>/dev/null || true

# The snap hook: an unused key saves a numbered frame and says so on stdout.
# Prepended (a main.lua ending in `return` must not become a syntax error);
# the key rides the genuine input path, so snaps are frame-accurate to the
# walk's own event stream. Scratch copy only; nothing here ships.
HOOK=$(mktemp /tmp/solar2d-walk-hook-XXXXXX)
cat > "$HOOK" <<'LUA'
-- walk hook (scratch copy only)
do
    local _snapKey = os.getenv("SOLAR2D_WALK_SNAP_KEY") or "f13"
    -- Solar2D's Linux keyName mapping calls F13 "unknown"; the native code
    -- (SDL SDLK_F13) identifies it regardless.
    local _snapCode = tonumber(os.getenv("SOLAR2D_WALK_SNAP_CODE") or "1073741928")
    local _snapN = 0
    local function onKey(e)
        if e.phase == "down" and (e.keyName == _snapKey or
            (e.keyName == "unknown" and tonumber(e.nativeKeyCode) == _snapCode)) then
            _snapN = _snapN + 1
            if _snapN == 1 then
                print("[WALK] geometry pixels " .. display.pixelWidth .. "x" .. display.pixelHeight
                    .. " content " .. display.contentWidth .. "x" .. display.contentHeight
                    .. " actual " .. display.actualContentWidth .. "x" .. display.actualContentHeight
                    .. " origin " .. display.screenOriginX .. "," .. display.screenOriginY)
            end
            local name = string.format("_walk-%04d.png", _snapN)
            display.save(display.currentStage, { filename = name,
                baseDir = system.DocumentsDirectory,
                captureOffscreenArea = false, isFullResolution = false })
            print("[WALK] snap " .. _snapN .. " " .. name)
            return true
        end
        return false
    end
    Runtime:addEventListener("key", onKey)
end
LUA
cat "$HOOK" "$SRC/main.lua" > "$SRC/main.lua.tmp" && mv "$SRC/main.lua.tmp" "$SRC/main.lua"
rm -f "$HOOK"

INPUT_FIFO="$WORK/input.fifo"
VIDEO_FIFO="$WORK/video.fifo"
mkfifo "$INPUT_FIFO"

export SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-offscreen}"
export SOLAR2D_CAP_WIDTH="$DEVW" SOLAR2D_CAP_HEIGHT="$DEVH"
export SOLAR2D_WALK_SNAP_KEY="$SNAP_KEY"
export SOLAR2D_WALK_SNAP_CODE="$SNAP_CODE"
export SOLAR2D_INPUT_PIPE="$INPUT_FIFO"

mkdir -p "$OUT"

if [ "$WANT_VIDEO" = "1" ]; then
    mkfifo "$VIDEO_FIFO"
    export SOLAR2D_VIDEO_PIPE="$VIDEO_FIFO"
    export SOLAR2D_VIDEO_FPS=15
    # The offscreen surface is the content box plus the simulator's 19px menu
    # bar on top; frames arrive bottom-up (GL readback). Flip, crop the menu
    # away so the video is exactly the content box, pad to even dimensions
    # (yuv420p needs them; content boxes are often odd). Fragmented MP4 so a
    # killed walk still leaves everything so far playable.
    rm -f "$OUT/walk.mp4"
    ffmpeg -y -loglevel error \
        -f rawvideo -pixel_format bgr0 -video_size "${DEVW}x$((DEVH + 19))" -framerate 15 \
        -use_wallclock_as_timestamps 1 -i "$VIDEO_FIFO" \
        -vf "vflip,crop=${DEVW}:${DEVH}:0:19,pad=ceil(iw/2)*2:ceil(ih/2)*2,format=yuv420p" -fps_mode cfr -r 15 \
        -c:v libx264 -preset ultrafast -crf 20 \
        -movflags +frag_keyframe+empty_moov+default_base_moof -frag_duration 1000000 -flush_packets 1 \
        "$OUT/walk.mp4" > "$WORK/ffmpeg.log" 2>&1 &
    FFMPEG_PID=$!
    # Hold a write end open so ffmpeg never sees EOF between the engine's
    # reconnects; the engine's own writer is the one that carries frames.
    exec 8>"$VIDEO_FIFO"
fi

# Line-buffered: the walk greps this log live, and stdout is block-buffered
# when it is not a TTY — without this, boot and app markers sit in the
# buffer until exit.
timeout --signal=TERM --kill-after=5s 600 \
    stdbuf -oL -eL Solar2DSimulator "$SRC/main.lua" > "$LOG" 2>&1 &
SIM_PID=$!

LOG_OFFSET=0
LAST_HIT=""
FAIL_PATTERNS=""
NEXT_SNAP=0

die_with_log() {
    echo "walk: $1" >&2
    tail -5 "$LOG" >&2
    exit 1
}

check_health() {
    # The simulator must be alive, must not have reported a Lua syntax error
    # (it carries on with defaults after one — a walk that answers a
    # different question than the one asked), and no fail-marker may have
    # appeared anywhere in the log.
    kill -0 "$SIM_PID" 2>/dev/null || die_with_log "simulator exited during: $1"
    if grep -aq 'ERROR: Syntax error' "$LOG"; then
        grep -aA2 'ERROR: Syntax error' "$LOG" >&2
        die_with_log "the simulator reported a Lua syntax error"
    fi
    if [ -n "$FAIL_PATTERNS" ]; then
        while IFS= read -r fp; do
            [ -n "$fp" ] || continue
            if grep -aqF -- "$fp" "$LOG"; then
                die_with_log "fail-marker seen: $fp"
            fi
        done <<< "$FAIL_PATTERNS"
    fi
}

wait_ms() {
    # Sleep in slices so a crash or fail-marker ends the walk now, not at the
    # next ack timeout.
    local ms=$1 what=$2
    local end=$(( $(date +%s%N) / 1000000 + ms ))
    while [ "$(( $(date +%s%N) / 1000000 ))" -lt "$end" ]; do
        check_health "$what"
        sleep 0.1
    done
}

wait_for_log() {
    # wait_for_log <pattern> <timeout-ms> <what> — succeeds when the pattern
    # appears in the log after the current offset; the matched line is left
    # in LAST_HIT. The offset then advances to the end of that line, never
    # to the end of the file: the app's reaction to an input lands within a
    # frame of the dispatch ack, in the same poll interval, and must stay
    # visible to the next expect.
    local pattern=$1 tmo=$2 what=$3
    local end=$(( $(date +%s%N) / 1000000 + tmo ))
    local hit
    while [ "$(( $(date +%s%N) / 1000000 ))" -lt "$end" ]; do
        check_health "$what"
        hit=$(tail -c +$((LOG_OFFSET + 1)) "$LOG" | grep -abF -m1 -- "$pattern" || true)
        if [ -n "$hit" ]; then
            local rel=${hit%%:*}
            LAST_HIT=${hit#*:}
            LOG_OFFSET=$((LOG_OFFSET + rel + ${#LAST_HIT} + 1))
            return 0
        fi
        sleep 0.1
    done
    die_with_log "timed out waiting for: $what"
}

# Boot: the simulator announces its platform line once the project loads.
wait_for_log "Platform:" 60000 "simulator boot"

# The FIFO's reader end lives inside the simulator; opening the write end
# blocks until it exists, so only now. Held open for the whole walk so plain
# echo never races the engine's EOF-driven reopen.
exec 9>"$INPUT_FIFO"

while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        ""|\#*) continue ;;
        wait\ *)
            MS=${line#wait }
            [[ $MS =~ ^[0-9]+$ ]] || { echo "walk: 'wait' needs milliseconds, got '$MS'" >&2; exit 2; }
            wait_ms "$MS" "wait $MS"
            ;;
        expect\ *)
            MARKER=${line#expect }
            wait_for_log "$MARKER" "$EXPECT_MS" "expect '$MARKER'"
            ;;
        fail\ *)
            FP=${line#fail }
            FAIL_PATTERNS="${FAIL_PATTERNS}${FAIL_PATTERNS:+$'\n'}$FP"
            check_health "fail '$FP'"
            ;;
        snap\ *)
            LABEL=${line#snap }
            [[ $LABEL =~ ^[A-Za-z0-9._-]+$ ]] || {
                echo "walk: snap label '$LABEL' may only contain letters, digits, dot, underscore, dash" >&2
                exit 2
            }
            NEXT_SNAP=$((NEXT_SNAP + 1))
            echo "key $SNAP_KEY" >&9
            wait_for_log "[WALK] snap $NEXT_SNAP " 15000 "snap $LABEL"
            rm -f "$OUT/$LABEL.png"
            cp "$SANDBOX/project/Documents/$(printf '_walk-%04d.png' "$NEXT_SNAP")" "$OUT/$LABEL.png"
            echo "walk: snapped $LABEL.png"
            ;;
        tap\ *|wtap\ *|drag\ *|key\ *|text\ *)
            echo "$line" >&9
            wait_for_log "[INPUT] " 10000 "input '$line'"
            case "$LAST_HIT" in
                *ignored*) die_with_log "the simulator ignored: $line" ;;
            esac
            # A drag acks when it starts and runs for its duration (default
            # 300ms); settle before the next step so a snap shows its end.
            if [[ $line =~ ^drag\ +[-0-9.]+\ +[-0-9.]+\ +[-0-9.]+\ +[-0-9.]+(\ +([0-9]+))?$ ]]; then
                wait_ms $(( ${BASH_REMATCH[2]:-300} + 100 )) "drag settle"
            fi
            ;;
        *)
            echo "walk: unknown step: $line" >&2
            exit 2
            ;;
    esac
done < "$STEPS"

kill "$SIM_PID" 2>/dev/null || true
wait "$SIM_PID" 2>/dev/null || true
SIM_PID=""
exec 9>&-

if [ -n "$FFMPEG_PID" ]; then
    exec 8>&-
    wait "$FFMPEG_PID" 2>/dev/null || true
    FFMPEG_PID=""
    [ -s "$OUT/walk.mp4" ] || {
        tail -5 "$WORK/ffmpeg.log" >&2
        echo "walk: walk.mp4 is empty — see ffmpeg's output above" >&2
        exit 1
    }
fi

# A file is not a capture: the PNG signature, its IEND, and the declared
# dimensions separate real captures from truncated or empty writes. Size is
# advisory only — a solid-colour screen is a legitimate capture and
# compresses to ~1.6k at 320x480.
COUNT=0
for png in "$OUT"/*.png; do
    [ -f "$png" ] || continue
    name=$(basename "$png")
    bytes=$(wc -c < "$png")
    magic=$(od -An -tu1 -N8 "$png" | tr -s ' ' | sed 's/^ //;s/ *$//')
    [ "$magic" = "137 80 78 71 13 10 26 10" ] || {
        echo "walk: $name is not a PNG ($bytes bytes)" >&2
        exit 1
    }
    tail_bytes=$(od -An -tu1 -j "$((bytes - 8))" -N8 "$png" | tr -s ' ' | sed 's/^ //;s/ *$//')
    [ "$tail_bytes" = "73 69 78 68 174 66 96 130" ] || {
        echo "walk: $name stops before its IEND — the write did not finish ($bytes bytes)" >&2
        exit 1
    }
    size=$(od -An -tu1 -j16 -N8 "$png" | awk '{
        printf "%dx%d\n", $1*16777216 + $2*65536 + $3*256 + $4, $5*16777216 + $6*65536 + $7*256 + $8 }')
    case "$size" in
        ""|0x*|*x0)
            echo "walk: $name declares no pixels ($size)" >&2
            exit 1 ;;
    esac
    [ "$size" = "$SCREEN" ] || echo "walk: WARNING $name is $size, not the requested $SCREEN" >&2
    COUNT=$((COUNT + 1))
done

SUFFIX=""
[ "$WANT_VIDEO" = "1" ] && SUFFIX=" + walk.mp4"
echo "walk: done, $COUNT snapshot(s)$SUFFIX"
[ "$COUNT" -gt 0 ] || {
    echo "walk: no snapshots were taken — the steps file has no snap step" >&2
    exit 1
}
