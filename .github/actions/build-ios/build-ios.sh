#!/bin/bash
#=============================================================================
# build-ios.sh install | sign | build | cleanup
#
# The steps of the build-ios composite action, one subcommand per step so
# the cleanup step can run with `if: always()`. Runs on a macOS runner with
# Xcode; the Linux image plays no part here — iOS needs Apple's toolchain.
#
# Inputs arrive as environment variables set by action.yml; state that later
# steps need (the builder path, the keychain, the profile) travels through
# GITHUB_ENV.
#=============================================================================
set -euo pipefail

cmd=${1:?usage: build-ios.sh install|sign|build|cleanup}

fail() { echo "::error::$*" >&2; exit 1; }

case "$cmd" in
install)
    [ "$(uname -s)" = Darwin ] || fail "build-ios runs on macOS runners only (this is $(uname -s))"
    [[ $SOLAR2D_VERSION =~ ^[0-9]{4}\.[0-9]{4}$ ]] || fail "solar2d-version '$SOLAR2D_VERSION' is not YYYY.NNNN"
    [ -d "$GITHUB_WORKSPACE/$PROJECT" ] || fail "project directory '$PROJECT' not found under the workspace root"
    [ -f "$GITHUB_WORKSPACE/$PROJECT/main.lua" ] || fail "no main.lua in '$PROJECT'"
    [ -n "$APP_NAME" ] || fail "app-name is required"
    case "$APP_NAME$APP_VERSION$BUILD_VERSION" in *"]==]"*) fail "inputs may not contain ]==]" ;; esac
    case "$TARGET_DEVICE" in ""|iphone|ipad) ;; *) fail "target-device must be empty, iphone or ipad" ;; esac
    if [ "$PREFLIGHT" != true ] && { [ -z "${IOS_CERTIFICATE_BASE64:-}" ] || [ -z "${IOS_PROVISIONING_PROFILE_BASE64:-}" ]; }; then
        # No unsigned fallback exists, deliberately: the Apple packager
        # rejects a missing certificatePath before it looks at the target
        # device, so even a Simulator build needs a provisioning profile.
        fail "IOS_CERTIFICATE_BASE64 and IOS_PROVISIONING_PROFILE_BASE64 must be set in the step's env (there is no unsigned iOS build); set preflight: true to test the toolchain without them"
    fi
    command -v xcodebuild >/dev/null || fail "Xcode is not available on this runner"
    echo "Xcode: $(xcode-select -p) ($(xcodebuild -version | head -1))"

    # Solar2D ships no CLI installer. The DMG holds one "Corona-<build>" folder
    # that must be copied whole: CoronaBuilder lives at
    # Native/Corona/mac/bin/CoronaBuilder.app but finds its templates by
    # walking up to the sibling "Corona Simulator.app".
    TAG="${SOLAR2D_VERSION#*.}"
    DMG="$RUNNER_TEMP/solar2d-$SOLAR2D_VERSION.dmg"
    if [ -s "$DMG" ]; then
        echo "Using cached $DMG"
    else
        URL="https://github.com/coronalabs/corona/releases/download/${TAG}/Solar2D-macOS-${SOLAR2D_VERSION}.dmg"
        echo "Downloading $URL"
        curl -fsSL --retry 3 -o "$DMG" "$URL" || fail "could not download Solar2D $SOLAR2D_VERSION for macOS"
    fi
    MOUNT="$RUNNER_TEMP/solar2d-dmg"
    hdiutil attach -nobrowse -quiet -mountpoint "$MOUNT" "$DMG"
    SRC=$(find "$MOUNT" -maxdepth 1 -mindepth 1 -type d -name "Corona*" -print -quit)
    [ -n "$SRC" ] || { ls -la "$MOUNT"; fail "no Corona folder in the DMG"; }
    sudo rm -rf /Applications/Corona
    sudo cp -R "$SRC" /Applications/Corona
    hdiutil detach -quiet "$MOUNT"

    BUILDER=$(find /Applications/Corona -type f -name CoronaBuilder -perm +111 -print -quit)
    [ -n "$BUILDER" ] || { find /Applications/Corona -maxdepth 4 -name "*.app"; fail "CoronaBuilder not found under /Applications/Corona"; }
    [ -d "/Applications/Corona/Corona Simulator.app/Contents/Resources" ] \
        || fail "Corona Simulator.app missing — the builder cannot reach its templates"
    echo "CORONA_BUILDER=$BUILDER" >> "$GITHUB_ENV"
    echo "Solar2D $SOLAR2D_VERSION installed; builder: $BUILDER"
    ;;

sign)
    if [ "$PREFLIGHT" = true ]; then
        echo "::notice::preflight: signing skipped"
        exit 0
    fi
    # A dedicated keychain, deleted in cleanup. Importing into the login
    # keychain would leave the signing key on the runner.
    KEYCHAIN="$RUNNER_TEMP/solar2d-build.keychain-db"
    KEYCHAIN_PASSWORD=$(uuidgen)
    security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
    security set-keychain-settings -lut 3600 "$KEYCHAIN"
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
    echo "BUILD_KEYCHAIN=$KEYCHAIN" >> "$GITHUB_ENV"

    printf '%s' "$IOS_CERTIFICATE_BASE64" | base64 -d > "$RUNNER_TEMP/cert.p12"
    # A p12 written by OpenSSL 3 without -legacy fails here with "MAC
    # verification failed during PKCS12 import (wrong password?)": the
    # algorithms, not the password, are what macOS rejects.
    security import "$RUNNER_TEMP/cert.p12" -k "$KEYCHAIN" \
        -P "${IOS_CERTIFICATE_PASSWORD:-}" -T /usr/bin/codesign -T /usr/bin/security \
        || { rm -f "$RUNNER_TEMP/cert.p12"; fail "certificate import failed (if OpenSSL made the p12, re-export it with -legacy)"; }
    rm -f "$RUNNER_TEMP/cert.p12"
    # Without this codesign blocks on a GUI prompt and the job hangs.
    security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" > /dev/null
    # Keep the login keychain in the search list: Apple's intermediate
    # certificates live there and the identity is invalid without them.
    security list-keychains -d user -s "$KEYCHAIN" login.keychain-db
    security default-keychain -s "$KEYCHAIN"

    PROFILE_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"
    mkdir -p "$PROFILE_DIR"
    PROFILE="$RUNNER_TEMP/profile.mobileprovision"
    printf '%s' "$IOS_PROVISIONING_PROFILE_BASE64" | base64 -d > "$PROFILE"
    UUID=$(security cms -D -i "$PROFILE" | plutil -extract UUID raw -o - -)
    [ -n "$UUID" ] || fail "the provisioning profile has no UUID — is the secret a .mobileprovision?"
    cp "$PROFILE" "$PROFILE_DIR/$UUID.mobileprovision"
    echo "INSTALLED_PROFILE=$PROFILE_DIR/$UUID.mobileprovision" >> "$GITHUB_ENV"
    echo "PROVISION_PROFILE=$PROFILE" >> "$GITHUB_ENV"

    # plutil renders the date as "2027-08-06T21:48:30Z" or
    # "2027-08-06 21:48:30 +0000" depending on the OS build; the first ten
    # characters compare correctly either way.
    EXPIRY=$(security cms -D -i "$PROFILE" | plutil -extract ExpirationDate raw -o - -)
    echo "Profile $UUID expires $EXPIRY"
    if [ "$(date -u +%Y-%m-%d)" \> "$(printf '%.10s' "$EXPIRY")" ]; then
        fail "the provisioning profile expired on $EXPIRY"
    fi
    security find-identity -v -p codesigning "$KEYCHAIN"
    ;;

build)
    PROJECT_DIR="$GITHUB_WORKSPACE/$PROJECT"
    OUTPUT_DIR="$GITHUB_WORKSPACE/$OUTPUT"
    mkdir -p "$OUTPUT_DIR"

    # Same _G.BUILD_VERSION contract as the HTML5 and Android builds. A
    # version.lua the project already has is restored in cleanup.
    VERSION_FILE="$PROJECT_DIR/version.lua"
    if [ -f "$VERSION_FILE" ]; then
        cp "$VERSION_FILE" "$RUNNER_TEMP/version.lua.orig"
        echo "RESTORE_VERSION_LUA=$RUNNER_TEMP/version.lua.orig" >> "$GITHUB_ENV"
    fi
    echo "VERSION_FILE=$VERSION_FILE" >> "$GITHUB_ENV"
    cat > "$VERSION_FILE" <<LUA
-- Auto-generated by the build-ios action — do not edit
_G.BUILD_VERSION = "${BUILD_VERSION}"
LUA

    # certificatePath is the provisioning profile, not the certificate: the
    # builder reads the bundle id from it and resolves the signing identity
    # from the keychain to match, so no bundle id appears in the inputs.
    PARAMS="$RUNNER_TEMP/ios_params.lua"
    {
        echo "local params ="
        echo "{"
        echo "    platform = 'ios',"
        echo "    appName = [==[${APP_NAME}]==],"
        echo "    appVersion = [==[${APP_VERSION}]==],"
        echo "    dstPath = [==[${OUTPUT_DIR}]==],"
        echo "    projectPath = [==[${PROJECT_DIR}]==],"
        [ -z "$TARGET_DEVICE" ] || echo "    targetDevice = '${TARGET_DEVICE}',"
        if [ "$PREFLIGHT" = true ]; then
            echo "    certificatePath = [==[<provisioning profile>]==],"
        else
            echo "    certificatePath = [==[${PROVISION_PROFILE}]==],"
        fi
        echo "}"
        echo "return params"
    } > "$PARAMS"
    cat "$PARAMS"

    if [ "$PREFLIGHT" = true ]; then
        [ -x "$CORONA_BUILDER" ] || fail "CoronaBuilder is not executable: $CORONA_BUILDER"
        echo "::notice::preflight: toolchain installed and params validated; no build was made"
        echo "ipa=" >> "$GITHUB_OUTPUT"
        exit 0
    fi

    "$CORONA_BUILDER" build --lua "$PARAMS"
    rm -f "$PARAMS"
    ls -lR "$OUTPUT_DIR"

    # The builder emits an .ipa for App Store profiles but a bare .app for
    # ad-hoc and development profiles. An IPA is a zip with the bundle under
    # Payload/, so make one when it is missing.
    cd "$OUTPUT_DIR"
    if ! ls ./*.ipa >/dev/null 2>&1; then
        APP=""
        for candidate in *.app; do
            [ -d "$candidate" ] || continue
            APP="$candidate"
            break
        done
        [ -n "$APP" ] || fail "the builder produced neither an .ipa nor an .app in $OUTPUT"
        rm -rf Payload && mkdir Payload
        cp -R "$APP" Payload/
        zip -qry "${APP_NAME}.ipa" Payload
        rm -rf Payload
    fi
    IPA=$(ls ./*.ipa | head -1)
    ls -lh "$IPA"
    echo "ipa=${OUTPUT}/$(basename "$IPA")" >> "$GITHUB_OUTPUT"
    ;;

cleanup)
    if [ -n "${BUILD_KEYCHAIN:-}" ] && [ -f "$BUILD_KEYCHAIN" ]; then
        security list-keychains -d user -s login.keychain-db || true
        security default-keychain -s login.keychain-db || true
        security delete-keychain "$BUILD_KEYCHAIN" || true
    fi
    [ -z "${INSTALLED_PROFILE:-}" ] || rm -f "$INSTALLED_PROFILE"
    [ -z "${PROVISION_PROFILE:-}" ] || rm -f "$PROVISION_PROFILE"
    rm -f "$RUNNER_TEMP/ios_params.lua"
    if [ -n "${VERSION_FILE:-}" ]; then
        if [ -n "${RESTORE_VERSION_LUA:-}" ] && [ -f "$RESTORE_VERSION_LUA" ]; then
            mv "$RESTORE_VERSION_LUA" "$VERSION_FILE"
        else
            rm -f "$VERSION_FILE"
        fi
    fi
    ;;

*)
    fail "unknown subcommand '$cmd'"
    ;;
esac
