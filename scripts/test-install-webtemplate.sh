#!/bin/bash
# Negative- and positive-path checks for install-webtemplate.sh, without
# network or an installer: wget and msiextract are PATH shims backed by
# fixtures, every checksum is a real sha256sum of those fixtures.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin" "$WORK/resources" "$WORK/native-staging"

# --- Fixtures ---------------------------------------------------------------
printf 'fake-msi-bytes' > "$WORK/solar2d.msi"
MSI_SHA=$(sha256sum "$WORK/solar2d.msi" | cut -d' ' -f1)

make_override() { # make_override OUT MODE [MANIFEST_JSON]
    local out=$1 mode=$2 manifest=${3:-}
    python3 - "$out" "$mode" "$manifest" <<'PY'
import sys
import zipfile

out, mode, manifest = sys.argv[1:4]
with zipfile.ZipFile(out, "w") as z:
    if mode == "placeholder":
        z.writestr("html/coronaHtml5App.wasm", b"")
    elif mode != "nowasm":
        z.writestr("html/coronaHtml5App.wasm", b"wasm-engine-bytes" * 8)
    z.writestr("html/coronaHtml5App.js", b"// js glue")
    z.writestr("html/index.html", b"<html></html>")
    z.writestr("html/resources/CORONA_LOGO.png", b"png")
    if mode == "traversal":
        z.writestr("../evil.txt", b"escape")
    if manifest:
        z.writestr("webtemplate-provenance.json", manifest)
PY
}
make_override "$WORK/good.zip" "" '{"engine_version": "2026.3736"}'
make_override "$WORK/placeholder.zip" placeholder
make_override "$WORK/nowasm.zip" nowasm
make_override "$WORK/traversal.zip" traversal
make_override "$WORK/wrongversion.zip" "" '{"engine_version": "2026.3734"}'
make_override "$WORK/wrongfork.zip" "" '{"engine_version": "2026.3736", "fork_sha": "deadbeef"}'
GOOD_SHA=$(sha256sum "$WORK/good.zip" | cut -d' ' -f1)
BAD_SHA=$(printf '0%.0s' {1..64})

# --- Shims ------------------------------------------------------------------
cat > "$WORK/bin/wget" <<'WGET'
#!/bin/bash
set -euo pipefail
[ "${1:-}" = -q ] || { echo "wget shim: unexpected flags $*" >&2; exit 2; }
url=$2 out=$4
printf '%s\n' "$url" >> "$WGET_CALLS"
case "$url" in
    *Solar2D-Windows-*.msi)  cat "$MSI_FIXTURE" > "$out" ;;
    https://example.com/good.zip)        cat "$GOOD_FIXTURE" > "$out" ;;
    https://example.com/placeholder.zip) cat "$PLACEHOLDER_FIXTURE" > "$out" ;;
    https://example.com/nowasm.zip)      cat "$NOWASM_FIXTURE" > "$out" ;;
    https://example.com/traversal.zip)   cat "$TRAVERSAL_FIXTURE" > "$out" ;;
    https://example.com/wrongversion.zip) cat "$WRONGVERSION_FIXTURE" > "$out" ;;
    https://example.com/wrongfork.zip)   cat "$WRONGFORK_FIXTURE" > "$out" ;;
    https://example.com/missing.zip)     exit 1 ;;
    *) echo "wget shim: unexpected url $url" >&2; exit 2 ;;
esac
WGET
cat > "$WORK/bin/msiextract" <<'MSIEXTRACT'
#!/bin/bash
set -euo pipefail
mkdir -p payload Native/Corona/android/resource Native/Corona/android/lib/gradle Native/Corona/shared
[ "${MSI_MISSING_WEBTEMPLATE:-}" != 1 ] && printf 'msi-webtemplate-bytes' > payload/webtemplate.zip
printf 'template' > Native/Corona/android/resource/android-template.zip
printf 'aar' > Native/Corona/android/lib/gradle/Corona.aar
printf 'shared' > Native/Corona/shared/resource.bin
MSIEXTRACT
chmod +x "$WORK/bin/wget" "$WORK/bin/msiextract"
export PATH="$WORK/bin:$PATH"
export WGET_CALLS="$WORK/wget-calls" MSI_FIXTURE="$WORK/solar2d.msi"
export GOOD_FIXTURE="$WORK/good.zip" PLACEHOLDER_FIXTURE="$WORK/placeholder.zip"
export NOWASM_FIXTURE="$WORK/nowasm.zip" TRAVERSAL_FIXTURE="$WORK/traversal.zip"
export WRONGVERSION_FIXTURE="$WORK/wrongversion.zip" WRONGFORK_FIXTURE="$WORK/wrongfork.zip"
export SOLAR2D_VERSION=2026.3736
export RESOURCES_DIR="$WORK/resources" NATIVE_STAGING="$WORK/native-staging"
export PROVENANCE_OUT="$WORK/provenance.json"

PLACEHOLDER_CONTENTS=placeholder
reset_case() {
    rm -rf "$RESOURCES_DIR" "$NATIVE_STAGING"
    mkdir -p "$RESOURCES_DIR" "$NATIVE_STAGING"
    printf '%s' "$PLACEHOLDER_CONTENTS" > "$RESOURCES_DIR/webtemplate.zip"   # the source tree's 0-byte placeholder, made detectable
    rm -f "$PROVENANCE_OUT" "$WGET_CALLS"
    unset SOLAR2D_MSI_SHA256 WEBTEMPLATE_URL WEBTEMPLATE_SHA256 SOLAR2D_REF_SHA || true
}

expect_ok() { # expect_ok DESC -- env assignments via preceding exports
    local desc=$1
    if ! bash "$ROOT/install-webtemplate.sh" > "$WORK/out.log" 2>&1; then
        echo "FAIL (expected success): $desc" >&2
        sed 's/^/    /' "$WORK/out.log" >&2
        exit 1
    fi
    echo "ok: $desc"
}

expect_fail() { # expect_fail DESC GREP...
    local desc=$1; shift
    local status=0
    bash "$ROOT/install-webtemplate.sh" > "$WORK/out.log" 2>&1 || status=$?
    if [ "$status" = 0 ]; then
        echo "FAIL (expected failure): $desc" >&2
        exit 1
    fi
    local pattern
    for pattern in "$@"; do
        grep -qi -- "$pattern" "$WORK/out.log" || {
            echo "FAIL: '$desc' failed without mentioning '$pattern'" >&2
            sed 's/^/    /' "$WORK/out.log" >&2
            exit 1
        }
    done
    echo "ok: $desc (rejected)"
}

staged() { cat "$RESOURCES_DIR/webtemplate.zip"; }
staged_unchanged() {
    [ "$(staged)" = "$PLACEHOLDER_CONTENTS" ] || {
        echo "FAIL: staged template changed although the run must not touch it" >&2
        exit 1
    }
}

# --- Default path: no override set, behavior identical to the old RUN ---------
reset_case
expect_ok "default: MSI template, no checksums supplied"
[ "$(staged)" = msi-webtemplate-bytes ]
grep -q '"origin": "msi"' "$PROVENANCE_OUT"
grep -qF "\"engine_version\": \"2026.3736\"" "$PROVENANCE_OUT"
test -f "$NATIVE_STAGING/android/lib/gradle/Corona.aar"

reset_case
export SOLAR2D_MSI_SHA256=$MSI_SHA
expect_ok "default: MSI template, verified installer"
grep -q 'MSI sha256 verified' "$WORK/out.log"

# --- Installer verification negatives ----------------------------------------
reset_case
export SOLAR2D_MSI_SHA256=$BAD_SHA
expect_fail "MSI sha mismatch" 'MSI sha256 mismatch'
staged_unchanged

reset_case
export SOLAR2D_MSI_SHA256="not-hex"
expect_fail "MSI sha malformed" '64 lowercase hex'
[ ! -s "$WGET_CALLS" ]   # format errors happen before any download

reset_case
export MSI_MISSING_WEBTEMPLATE=1
expect_fail "MSI without a webtemplate" 'no webtemplate'
unset MSI_MISSING_WEBTEMPLATE

# --- Override happy path -------------------------------------------------------
reset_case
export WEBTEMPLATE_URL=https://example.com/good.zip WEBTEMPLATE_SHA256=$GOOD_SHA
expect_ok "override: verified artifact replaces the MSI template"
cmp -s "$RESOURCES_DIR/webtemplate.zip" "$WORK/good.zip"
grep -q '"origin": "webtemplate-override"' "$PROVENANCE_OUT"
grep -qF "\"sha256\": \"$GOOD_SHA\"" "$PROVENANCE_OUT"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$PROVENANCE_OUT"

# --- Pairing / format negatives (before any download) -------------------------
reset_case
export WEBTEMPLATE_URL=https://example.com/good.zip
expect_fail "URL without checksum" 'set together'
staged_unchanged

reset_case
export WEBTEMPLATE_SHA256=$GOOD_SHA
expect_fail "checksum without URL" 'set together'
[ ! -s "$WGET_CALLS" ]
staged_unchanged

reset_case
export WEBTEMPLATE_URL=https://example.com/good.zip WEBTEMPLATE_SHA256=ABCDEF
expect_fail "malformed checksum" '64 lowercase hex'
[ ! -s "$WGET_CALLS" ]

reset_case
export WEBTEMPLATE_URL=https://example.com/good.zip WEBTEMPLATE_SHA256=${GOOD_SHA}0
expect_fail "wrong-length checksum" '64 lowercase hex'

# --- Override negatives: never fall back to the MSI template -------------------
reset_case
export WEBTEMPLATE_URL=https://example.com/good.zip WEBTEMPLATE_SHA256=$BAD_SHA
expect_fail "override checksum mismatch" 'sha256 mismatch' 'NOT falling back'
staged_unchanged

reset_case
export WEBTEMPLATE_URL=https://example.com/missing.zip WEBTEMPLATE_SHA256=$BAD_SHA
expect_fail "override artifact missing (download fails)" 'could not download' 'NOT falling back'
staged_unchanged

reset_case
export WEBTEMPLATE_URL=https://example.com/placeholder.zip
make_override "$WORK/placeholder.zip" placeholder
export WEBTEMPLATE_SHA256=$(sha256sum "$WORK/placeholder.zip" | cut -d' ' -f1)
expect_fail "placeholder zip (empty wasm)" 'rejected' 'coronaHtml5App.wasm'
staged_unchanged

reset_case
export WEBTEMPLATE_URL=https://example.com/nowasm.zip
export WEBTEMPLATE_SHA256=$(sha256sum "$WORK/nowasm.zip" | cut -d' ' -f1)
expect_fail "zip without the wasm entry" "missing entry 'html/coronaHtml5App.wasm'"
staged_unchanged

reset_case
export WEBTEMPLATE_URL=https://example.com/traversal.zip
export WEBTEMPLATE_SHA256=$(sha256sum "$WORK/traversal.zip" | cut -d' ' -f1)
expect_fail "zip with traversal entry" "unsafe entry"
staged_unchanged

reset_case
export WEBTEMPLATE_URL=https://example.com/wrongversion.zip
export WEBTEMPLATE_SHA256=$(sha256sum "$WORK/wrongversion.zip" | cut -d' ' -f1)
expect_fail "manifest engine_version mismatch" 'engine_version 2026.3734 does not match SOLAR2D_VERSION 2026.3736'
staged_unchanged

reset_case
export WEBTEMPLATE_URL=https://example.com/wrongfork.zip
export WEBTEMPLATE_SHA256=$(sha256sum "$WORK/wrongfork.zip" | cut -d' ' -f1)
export SOLAR2D_REF_SHA=cafebabe
expect_fail "manifest fork_sha mismatch" 'fork_sha deadbeef does not match SOLAR2D_REF_SHA cafebabe'
staged_unchanged

echo 'install-webtemplate checks passed (default, msi verify, override, pairing, hashes, zip shape, manifest)'
