#!/bin/bash
# Transport and failure cleanup checks, without invoking a compiler.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
cleanup() {
    for pid in $(jobs -pr); do kill "$pid" 2>/dev/null || :; done
    wait || :
    rm -rf "$WORK"
}
trap cleanup EXIT
mkdir -p "$WORK/bin" "$WORK/workspace with spaces/project" "$WORK/output" "$WORK/cache"
printf fixture > "$WORK/workspace with spaces/project/main.lua"
printf built > "$WORK/output/index.html"
printf downloaded > "$WORK/cache/dependency"
# A real executable named java lets /proc selection run without a JDK.
cp "$(command -v python3)" "$WORK/java"
export JAVA_FIXTURE="$WORK/java" TEST_WORK="$WORK"
cat > "$WORK/bin/tar" <<'TAR'
#!/bin/bash
if [ "${FAIL_EXTRACT:-}" = 1 ] && [[ " $* " == *' -xf - '* ]] && [[ "$*" == *gradle* ]]; then
    /usr/bin/tar "$@"
    exit 1
fi
exec /usr/bin/tar "$@"
TAR
chmod +x "$WORK/bin/tar"
cat > "$WORK/bin/docker" <<'DOCKER'
#!/bin/bash
set -euo pipefail
printf '%q ' "$@" >> "$CALLS"; printf '\n' >> "$CALLS"
case "$1" in
    create) echo fake-id ;;
    exec)
        if [[ " $* " == *' /usr/local/bin/entrypoint.sh '* ]]; then
            if [ -n "${BUILD_SIGNAL:-}" ]; then kill -s "$BUILD_SIGNAL" "$PPID"; fi
            exit "${FAIL_BUILD:-0}"
        elif [ "${3:-}" = sh ] && [ "${4:-}" = -c ]; then
            # Execute the production scanner against real /proc processes.
            sh -c "$5"
        elif [[ " $* " == *' -xf - '* ]]; then
            tar -tf - >> "$UPLOADS"
        elif [[ " $* " == *' -cf - '* ]]; then
            case "$*" in
                *gradle*)
                    if [ -n "${FAIL_CACHE:-}" ]; then
                        echo "tar: File removed before we read it" >&2
                        exit 1
                    fi
                    if [ "${TRUNCATE_CACHE:-}" = 1 ]; then
                        tar -C "$CACHE_FIXTURE" -cf - . | head -c 2048
                        exit 1
                    fi
                    if [ -n "${CACHE_SIGNAL:-}" ]; then kill -s "$CACHE_SIGNAL" "$PPID"; fi
                    tar -C "$CACHE_FIXTURE" -cf - .
                    exit "${FAIL_PRODUCER:-0}" ;;
                *)
                    if [ -n "${FAIL_OUTPUT:-}" ]; then exit 1; fi
                    tar -C "$OUTPUT_FIXTURE" -cf - . ;;
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
set +e
FAIL_CACHE=1 bash "$ROOT/run-build.sh" build >"$WORK/out-cache-success" 2>&1
status=$?
set -e
[ "$status" = 0 ]
grep -q '::warning::' "$WORK/out-cache-success"
[ "$(cat "$GITHUB_WORKSPACE/out/index.html")" = built ]
grep -q 'rm -fv' "$CALLS"

: > "$CALLS"
set +e
FAIL_BUILD=42 FAIL_CACHE=1 bash "$ROOT/run-build.sh" build-android >"$WORK/out-cache-failed" 2>&1
status=$?
set -e
[ "$status" = 42 ]
grep -q '::warning::' "$WORK/out-cache-failed"
grep -q 'gradle' "$CALLS"
grep -q 'rm -fv' "$CALLS"

: > "$CALLS"
set +e
FAIL_OUTPUT=1 bash "$ROOT/run-build.sh" build >"$WORK/out-output" 2>&1
status=$?
set -e
[ "$status" -ne 0 ]
grep -q 'rm -fv' "$CALLS"

# Failed reception must preserve every byte and discard staging.
printf original > "$GITHUB_WORKSPACE/gradle/dependency"
mkdir -p "$GITHUB_WORKSPACE/gradle/old-only"
printf keep > "$GITHUB_WORKSPACE/gradle/old-only/file"
head -c 16384 /dev/zero > "$CACHE_FIXTURE/dependency"
cache_digest() {
    (cd "$GITHUB_WORKSPACE/gradle" && find . -type f -print0 | sort -z | xargs -0 sha256sum)
}
original=$(cache_digest)
for failure in FAIL_CACHE TRUNCATE_CACHE FAIL_EXTRACT FAIL_PRODUCER; do
    : > "$CALLS"
    env "$failure=1" bash "$ROOT/run-build.sh" build > "$WORK/reception" 2>&1
    grep -q '::warning::' "$WORK/reception"
    [ "$(cache_digest)" = "$original" ]
    [ -z "$(find "$GITHUB_WORKSPACE" -maxdepth 1 -name '.solar2d-gradle.*' -print)" ]
    grep -q 'rm -fv' "$CALLS"
done
printf downloaded > "$CACHE_FIXTURE/dependency"

# Execute the exact production command, with accelerated polling for tests.
python3 - "$ROOT/run-build.sh" "$WORK/scanner" <<'PYTHON'
import sys
s = open(sys.argv[1]).read().split('docker exec "$name" sh -c \'', 1)[1].split("'", 1)[0]
open(sys.argv[2], 'w').write(s)
PYTHON
cat > "$WORK/bin/sleep" <<'SLEEP'
#!/bin/bash
echo wait >> "$TEST_WORK/waits"
exec /usr/bin/sleep .2
SLEEP
chmod +x "$WORK/bin/sleep"
: > "$WORK/waits"
sh "$WORK/scanner"
[ ! -s "$WORK/waits" ]
# A non-JVM with the same argument must also be ignored.
(trap - EXIT; exec python3 -c 'import time; time.sleep(20)' org.gradle.launcher.daemon.bootstrap.GradleDaemon) &
decoy=$!
while [ "$(readlink /proc/"$decoy"/exe)" != "$(readlink -f "$(command -v python3)")" ]; do
    kill -0 "$decoy"
    /usr/bin/sleep .01
done
sh "$WORK/scanner"
[ ! -s "$WORK/waits" ]
kill "$decoy"
wait "$decoy" 2>/dev/null || :
# A Java executable with only a substring match is not a Gradle daemon.
(trap - EXIT; exec "$JAVA_FIXTURE" -c 'import time; time.sleep(20)' prefix.org.gradle.launcher.daemon.bootstrap.GradleDaemon.suffix) &
decoy=$!
while [ "$(readlink /proc/"$decoy"/exe)" != "$JAVA_FIXTURE" ]; do kill -0 "$decoy"; /usr/bin/sleep .01; done
sh "$WORK/scanner"
[ ! -s "$WORK/waits" ]
kill "$decoy"
wait "$decoy" 2>/dev/null || :
for lifetime in 1 20; do
    (trap - EXIT; exec "$JAVA_FIXTURE" -c 'import time,sys; time.sleep(float(sys.argv[1]))' "$lifetime" org.gradle.launcher.daemon.bootstrap.GradleDaemon) &
    daemon=$!
    # Wait until exec has installed the fixture executable.
    while [ "$(readlink /proc/"$daemon"/exe)" != "$JAVA_FIXTURE" ]; do kill -0 "$daemon"; /usr/bin/sleep .01; done
    : > "$CALLS"
    : > "$WORK/waits"
    bash "$ROOT/run-build.sh" build > "$WORK/daemon" 2>&1
    if [ "$lifetime" = 20 ]; then
        kill -0 "$daemon"
        grep -q '::warning::.*skipp' "$WORK/daemon"
        ! grep -q 'tar -C .*gradle.*-cf' "$CALLS"
        kill "$daemon"
    else
        grep -q 'tar -C .*gradle.*-cf' "$CALLS"
        [ -s "$WORK/waits" ]
    fi
    wait "$daemon" 2>/dev/null || :
done
rm "$WORK/bin/sleep"
# A complete archive followed by producer failure is still a failed pipeline.
for signal in INT TERM; do
    printf original > "$GITHUB_WORKSPACE/gradle/dependency"
    original=$(cache_digest)
    : > "$CALLS"
    set +e
    CACHE_SIGNAL="$signal" FAIL_PRODUCER=1 bash "$ROOT/run-build.sh" build > "$WORK/export-signal" 2>&1
    status=$?
    set -e
    expected=130
    [ "$signal" != TERM ] || expected=143
    [ "$status" = "$expected" ]
    [ "$(cache_digest)" = "$original" ]
    [ -z "$(find "$GITHUB_WORKSPACE" -maxdepth 1 -name '.solar2d-gradle.*' -print)" ]
    grep -q 'rm -fv' "$CALLS"
done
for signal in INT TERM; do
    : > "$CALLS"
    set +e
    BUILD_SIGNAL="$signal" bash "$ROOT/run-build.sh" build > "$WORK/signal" 2>&1
    status=$?
    set -e
    expected=130
    [ "$signal" != TERM ] || expected=143
    [ "$status" = "$expected" ]
    grep -q 'rm -fv' "$CALLS"
    [ -z "$(find "$GITHUB_WORKSPACE" -maxdepth 1 -name '.solar2d-gradle.*' -print)" ]
done

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
echo 'Build transport checks passed (24 action runs, 5 process-selection cases, 4 reception failures, 4 signal cases)'
