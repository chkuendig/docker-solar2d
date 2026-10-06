#!/bin/bash
#=============================================================================
# capture.sh <label> <contentWxH> [delay-ms]
#
# One screenshot of a Solar2D project from the headless simulator: the
# one-step walk `wait <delay-ms>` / `snap <label>`. Everything else —
# scratch copy, content-box and window pinning, the snap hook, PNG
# validation — is walk.sh's. Writes <SOLAR2D_CAP_OUT>/<label>.png.
#
#   entrypoint: capture home 320x480 3000
#   env:        SOLAR2D_CAP_PROJECT (default /project), SOLAR2D_CAP_OUT
#               (default /output)
#=============================================================================
set -euo pipefail

LABEL=${1:?usage: capture <label> <contentWxH> [delay-ms]}
SCREEN=${2:?usage: capture <label> <contentWxH> [delay-ms]}
DELAY=${3:-14000}

[[ $DELAY =~ ^[0-9]+$ ]] || {
    echo "capture: delay-ms '$DELAY' is not a number" >&2
    exit 2
}
[[ $LABEL =~ ^[A-Za-z0-9._-]+$ ]] || {
    echo "capture: label '$LABEL' may only contain letters, digits, dot, underscore, dash" >&2
    exit 2
}

STEPS=$(mktemp /tmp/solar2d-cap-steps-XXXXXX)
trap 'rm -f "$STEPS"' EXIT
printf 'wait %s\nsnap %s\n' "$DELAY" "$LABEL" > "$STEPS"

export SOLAR2D_WALK_PROJECT="${SOLAR2D_CAP_PROJECT:-/project}"
export SOLAR2D_WALK_OUT="${SOLAR2D_CAP_OUT:-/output}"
export SOLAR2D_WALK_SCREEN="$SCREEN"
export SOLAR2D_WALK_VIDEO=0
walk.sh "$STEPS"
