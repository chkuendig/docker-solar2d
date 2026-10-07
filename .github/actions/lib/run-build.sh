#!/bin/bash
# Run a build with local bind mounts or client-side tar streams for a remote
# Docker daemon. Only requested inputs and outputs cross the stream boundary.
set -euo pipefail

TRANSPORT=${TRANSPORT:-bind}
case "$TRANSPORT" in bind|stream) ;; *) echo "::error::transport must be bind or stream"; exit 2 ;; esac
mkdir -p "$GITHUB_WORKSPACE/$OUTPUT"
paths=("$PROJECT")
[ -z "${HTML5_CUSTOM:-}" ] || paths+=("$HTML5_CUSTOM")
[ -z "${KEYSTORE:-}" ] || paths+=("$KEYSTORE")
envs=(-e HOME=/tmp -e BUILD_VERSION -e SENTRY_RELEASE
      -e ANDROID_KEYSTORE_BASE64 -e ANDROID_KEYSTORE_PASSWORD
      -e ANDROID_KEYSTORE_ALIAS -e ANDROID_KEYSTORE_ALIAS_PASSWORD)
if [ -n "${GRADLE_CACHE:-}" ]; then
    mkdir -p "$GITHUB_WORKSPACE/$GRADLE_CACHE"
    paths+=("$GRADLE_CACHE")
    envs+=(-e "GRADLE_USER_HOME=$GITHUB_WORKSPACE/$GRADLE_CACHE")
fi

if [ "$TRANSPORT" = bind ]; then
    mounts=(-v "$GITHUB_WORKSPACE:$GITHUB_WORKSPACE")
    [ -z "${HTML5_CUSTOM:-}" ] || mounts+=(-v "$GITHUB_WORKSPACE/$HTML5_CUSTOM:/html5-custom")
    docker run --rm --user "$(id -u):$(id -g)" "${mounts[@]}" "${envs[@]}" \
        --tmpfs /artifacts:rw,noexec,nosuid,nodev,size=16m,mode=1777 "$IMAGE" "$@"
    exit
fi

# A bounded holder lets docker exec receive stdin for tar without confusing it
# with the builder's own input. A killed runner cannot leave it running forever.
name="solar2d-action-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}-$$-${RANDOM}"
created=false
cleanup() {
    local status=$?
    trap - EXIT
    if [ "$created" = true ]; then
        # Restore Gradle downloads even after a failed build. The cache contains
        # dependencies, never the signing work directory or the whole project.
        if [ -n "${GRADLE_CACHE:-}" ]; then
            if ! docker exec "$name" tar -C "$GITHUB_WORKSPACE/$GRADLE_CACHE" -cf - . \
                | tar --no-same-owner -C "$GITHUB_WORKSPACE/$GRADLE_CACHE" -xf -; then
                [ "$status" -ne 0 ] || status=1
            fi
        fi
        docker rm -fv "$name" >/dev/null || { [ "$status" -ne 0 ] || status=1; }
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

docker create --name "$name" --label com.solar2d.action.ephemeral=true \
    --user "$(id -u):$(id -g)" "${envs[@]}" \
    --tmpfs /artifacts:rw,noexec,nosuid,nodev,size=16m,mode=1777 \
    --entrypoint /bin/sh "$IMAGE" -c 'exec sleep 1800' >/dev/null
created=true
docker start "$name" >/dev/null
# Workspace ancestors may be owned by root in the image. Prepare them once as
# root, then all uploads, builds and downloads run as the runner's uid.
docker exec --user 0 "$name" mkdir -p "$GITHUB_WORKSPACE" /html5-custom
docker exec --user 0 "$name" chown "$(id -u):$(id -g)" "$GITHUB_WORKSPACE" /html5-custom
(cd "$GITHUB_WORKSPACE" && tar -cf - -- "${paths[@]}") \
    | docker exec -i "$name" tar --no-same-owner -C "$GITHUB_WORKSPACE" -xf -
if [ -n "${HTML5_CUSTOM:-}" ]; then
    docker exec "$name" cp -a "$GITHUB_WORKSPACE/$HTML5_CUSTOM/." /html5-custom/
fi
docker exec "$name" /usr/local/bin/entrypoint.sh "$@"
docker exec "$name" tar -C "$GITHUB_WORKSPACE/$OUTPUT" -cf - . \
    | tar --no-same-owner -C "$GITHUB_WORKSPACE/$OUTPUT" -xf -
