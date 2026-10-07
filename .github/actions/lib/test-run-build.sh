#!/bin/bash
# Transport and failure cleanup checks, without invoking a compiler.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/workspace with spaces/project" "$WORK/output" "$WORK/cache"
printf fixture > "$WORK/workspace with spaces/project/main.lua"
printf built > "$WORK/output/index.html"
printf downloaded > "$WORK/cache/dependency"
cat > "$WORK/bin/docker" <<'DOCKER'
#!/bin/bash
set -euo pipefail
printf '%q ' "$@" >> "$CALLS"; printf '\n' >> "$CALLS"
case "$1" in
    create) echo fake-id ;;
    exec)
        if [[ " $* " == *' /usr/local/bin/entrypoint.sh '* ]]; then
            exit "${FAIL_BUILD:-0}"
        elif [[ " $* " == *' -xf - '* ]]; then
            tar -tf - >> "$UPLOADS"
        elif [[ " $* " == *' -cf - '* ]]; then
            case "$*" in
                *gradle*) tar -C "$CACHE_FIXTURE" -cf - . ;;
                *) tar -C "$OUTPUT_FIXTURE" -cf - . ;;
            esac
        fi
        ;;
esac
DOCKER
chmod +x "$WORK/bin/docker"
export PATH="$WORK/bin:$PATH" CALLS="$WORK/calls" UPLOADS="$WORK/uploads"
export OUTPUT_FIXTURE="$WORK/output" CACHE_FIXTURE="$WORK/cache"
export GITHUB_WORKSPACE="$WORK/workspace with spaces" PROJECT=project OUTPUT=out
export IMAGE=fixture TRANSPORT=stream GRADLE_CACHE=gradle
export GITHUB_RUN_ID=123
export ANDROID_KEYSTORE_PASSWORD=secret-that-must-not-be-in-arguments
bash "$ROOT/run-build.sh" build --app-name Fixture
[ "$(cat "$GITHUB_WORKSPACE/out/index.html")" = built ]
[ "$(cat "$GITHUB_WORKSPACE/gradle/dependency")" = downloaded ]
grep -q 'project/main.lua' "$UPLOADS"
grep -q 'rm -fv' "$CALLS"
! grep -q 'secret-that-must-not-be-in-arguments' "$CALLS"
! grep -q -- '-v ' "$CALLS"
grep -q '^create --rm' "$CALLS"
grep -q 'com.solar2d.action.run-id=123' "$CALLS"
grep -q 'com.solar2d.action.keepalive-seconds=1800' "$CALLS"
grep -Fq 'exec\ sleep\ 1800' "$CALLS"

: > "$CALLS"
set +e
FAIL_BUILD=42 bash "$ROOT/run-build.sh" build-android
status=$?
set -e
[ "$status" = 42 ]
grep -q 'rm -fv' "$CALLS"
[ "$(cat "$GITHUB_WORKSPACE/gradle/dependency")" = downloaded ]

: > "$CALLS"
SOLAR2D_ACTION_KEEPALIVE_SECONDS=2700 bash "$ROOT/run-build.sh" build
grep -q 'com.solar2d.action.keepalive-seconds=2700' "$CALLS"
grep -Fq 'exec\ sleep\ 2700' "$CALLS"
for invalid in 0 -1 86401 99999999999999999999 '30; touch /tmp/unsafe' nope; do
    : > "$CALLS"
    if SOLAR2D_ACTION_KEEPALIVE_SECONDS="$invalid" bash "$ROOT/run-build.sh" build; then
        echo "invalid keepalive accepted: $invalid" >&2
        exit 1
    fi
    [ ! -s "$CALLS" ]
done
: > "$CALLS"
TRANSPORT=bind bash "$ROOT/run-build.sh" build
# Bind mode retains the simple one-container invocation.
grep -q '^run --rm' "$CALLS"
! grep -q '^create' "$CALLS"

: > "$CALLS"
if TRANSPORT=invalid bash "$ROOT/run-build.sh" build; then exit 1; fi
[ ! -s "$CALLS" ]
echo 'Build transport checks passed (stream, bind, failure cleanup, cache, secret forwarding)'
