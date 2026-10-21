#!/bin/bash
# Checks the Dockerfile's build-argument guards without a docker build: the
# guard RUN's shell body is extracted from the Dockerfile and executed under
# the argument combinations it must police.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)

# Extract the RUN that rejects SOLAR2D_PRS + WEBTEMPLATE_URL, joining
# Dockerfile line continuations into a single shell command.
body=$(awk '
    /RUN if \[ -n "\$SOLAR2D_PRS" \] && \[ -n "\$WEBTEMPLATE_URL" \]/ { inrun=1 }
    inrun {
        line = $0
        if (inrun == 1) { sub(/^RUN /, "", line); inrun = 2 }
        if (line ~ /\\$/) { sub(/\\$/, "", line); printf "%s ", line }
        else { print line; exit }
    }
' "$ROOT/../Dockerfile")
[ -n "$body" ] || {
    echo "FAIL: no SOLAR2D_PRS/WEBTEMPLATE_URL guard RUN found in the Dockerfile" >&2
    exit 1
}

run_guard() { # run_guard SOLAR2D_PRS WEBTEMPLATE_URL
    env SOLAR2D_PRS="$1" WEBTEMPLATE_URL="$2" bash -c "$body" > /dev/null 2>&1
}

run_guard "" "" \
    || { echo "FAIL: guard rejected a plain build (no PRs, no override)" >&2; exit 1; }
run_guard "891 935" "" \
    || { echo "FAIL: guard rejected PRs without a template override" >&2; exit 1; }
run_guard "" "https://example.com/t.zip" \
    || { echo "FAIL: guard rejected a template override without PRs" >&2; exit 1; }
if run_guard "891" "https://example.com/t.zip"; then
    echo "FAIL: the Dockerfile accepted SOLAR2D_PRS together with a webtemplate override" >&2
    exit 1
fi

echo 'Dockerfile guard checks passed (SOLAR2D_PRS is mutually exclusive with a template override)'
