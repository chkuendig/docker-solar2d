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

FORK_SHA=$(printf 'c%.0s' {1..40})
make_override() { # make_override OUT MODE [MANIFEST_JSON]
    local out=$1 mode=$2 manifest=${3:-}
    python3 - "$out" "$mode" "$manifest" <<'PY'
import sys
import zipfile

out, mode, manifest = sys.argv[1:4]

# The layout of the official webtemplate.zip (2026.3736): five html/ files,
# four fbinstant/ files and a populated res_widget/. The negatives below
# drop one piece of it; "oldlayout" is the pre-correction four-entry
# archive the validator used to accept.
REAL_LAYOUT = {
    "html/coronaHtml5App.wasm": b"wasm-engine-bytes" * 8,
    "html/coronaHtml5App.js": b"// js glue",
    "html/index.html": b"<html></html>",
    "html/index-debug.html": b"<html debug></html>",
    "html/index-nosplash.html": b"<html nosplash></html>",
    "fbinstant/fbapp-config.json": b'{"instant_games": {}}',
    "fbinstant/index.html": b"<html fb></html>",
    "fbinstant/gulpfile.js": b"// gulp",
    "fbinstant/css/style.css": b"body {}",
    "res_widget/widget_theme_ios.png": b"png",
}
SKIP = {
    "nowasm": {"html/coronaHtml5App.wasm"},
    "noindex": {"html/index.html"},
    "nodebug": {"html/index-debug.html"},
    "nofbapp": {"fbinstant/fbapp-config.json"},
    "nowidget": {"res_widget/widget_theme_ios.png"},
}
# The new-rule negatives also carry html/resources/CORONA_LOGO.png, the
# old validator's required entry, so each archive passes the old four-file
# check and only the new rules reject it (fail-first evidence).
LEGACY = {"nodebug", "nofbapp", "nowidget"}

with zipfile.ZipFile(out, "w") as z:
    if mode == "oldlayout":
        z.writestr("html/coronaHtml5App.wasm", b"wasm-engine-bytes" * 8)
        z.writestr("html/coronaHtml5App.js", b"// js glue")
        z.writestr("html/index.html", b"<html></html>")
        z.writestr("html/resources/CORONA_LOGO.png", b"png")
    else:
        skip = SKIP.get(mode, set())
        for name, data in REAL_LAYOUT.items():
            if name in skip:
                continue
            if mode == "placeholder" and name == "html/coronaHtml5App.wasm":
                z.writestr(name, b"")
            else:
                z.writestr(name, data)
        if mode == "nowidget":
            z.writestr("res_widget/", b"")   # directory entry, no pngs
        if mode in LEGACY:
            z.writestr("html/resources/CORONA_LOGO.png", b"png")
    if mode == "traversal":
        z.writestr("../evil.txt", b"escape")
    if manifest:
        z.writestr("webtemplate-provenance.json", manifest)
PY
}
GOOD_MANIFEST='{"engine_version": "2026.3736", "fork_sha": "'"$FORK_SHA"'"}'
make_override "$WORK/good.zip" "" "$GOOD_MANIFEST"
make_override "$WORK/placeholder.zip" placeholder
make_override "$WORK/nowasm.zip" nowasm
make_override "$WORK/traversal.zip" traversal
make_override "$WORK/wrongversion.zip" "" '{"engine_version": "2026.3734"}'
make_override "$WORK/wrongfork.zip" "" '{"engine_version": "2026.3736", "fork_sha": "deadbeef"}'
make_override "$WORK/nomanifest.zip" ""
make_override "$WORK/emptymanifest.zip" "" '{}'
make_override "$WORK/nofork.zip" "" '{"engine_version": "2026.3736"}'
make_override "$WORK/wrongtype.zip" "" '{"engine_version": 2026.3736, "fork_sha": "'"$FORK_SHA"'"}'
make_override "$WORK/noindex.zip" noindex "$GOOD_MANIFEST"
make_override "$WORK/nodebug.zip" nodebug "$GOOD_MANIFEST"
make_override "$WORK/nofbapp.zip" nofbapp "$GOOD_MANIFEST"
make_override "$WORK/nowidget.zip" nowidget "$GOOD_MANIFEST"
make_override "$WORK/oldlayout.zip" oldlayout "$GOOD_MANIFEST"
make_override "$WORK/corrupt.zip" "" "$GOOD_MANIFEST"
# A CRC-broken archive: flip one byte inside the stored wasm payload, past
# its local file header, so the zip opens and lists fine but fails an
# integrity test.
python3 - "$WORK/corrupt.zip" <<'PY'
import sys, zipfile

path = sys.argv[1]
with zipfile.ZipFile(path) as z:
    info = z.getinfo("html/coronaHtml5App.wasm")
    off = info.header_offset + 30 + len(info.filename) + len(info.extra)
with open(path, "r+b") as f:
    f.seek(off + 5)
    byte = f.read(1)
    f.seek(off + 5)
    f.write(bytes([byte[0] ^ 0xFF]))
PY
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
    https://example.com/nomanifest.zip)  cat "$NOMANIFEST_FIXTURE" > "$out" ;;
    https://example.com/emptymanifest.zip) cat "$EMPTYMANIFEST_FIXTURE" > "$out" ;;
    https://example.com/nofork.zip)      cat "$NOFORK_FIXTURE" > "$out" ;;
    https://example.com/wrongtype.zip)   cat "$WRONGTYPE_FIXTURE" > "$out" ;;
    https://example.com/noindex.zip)     cat "$NOINDEX_FIXTURE" > "$out" ;;
    https://example.com/nodebug.zip)     cat "$NODEBUG_FIXTURE" > "$out" ;;
    https://example.com/nofbapp.zip)     cat "$NOFBAPP_FIXTURE" > "$out" ;;
    https://example.com/nowidget.zip)    cat "$NOWIDGET_FIXTURE" > "$out" ;;
    https://example.com/oldlayout.zip)   cat "$OLDLAYOUT_FIXTURE" > "$out" ;;
    https://example.com/corrupt.zip)     cat "$CORRUPT_FIXTURE" > "$out" ;;
    https://example.com/missing.zip)     exit 1 ;;
    *) echo "wget shim: unexpected url $url" >&2; exit 2 ;;
esac
WGET
cat > "$WORK/bin/msiextract" <<'MSIEXTRACT'
#!/bin/bash
set -euo pipefail
printf 'msiextract %s\n' "$*" >> "$MSIEXTRACT_CALLS"
mkdir -p payload Native/Corona/android/resource Native/Corona/android/lib/gradle Native/Corona/shared
[ "${MSI_MISSING_WEBTEMPLATE:-}" != 1 ] && printf 'msi-webtemplate-bytes' > payload/webtemplate.zip
printf 'template' > Native/Corona/android/resource/android-template.zip
printf 'aar' > Native/Corona/android/lib/gradle/Corona.aar
printf 'shared' > Native/Corona/shared/resource.bin
MSIEXTRACT
chmod +x "$WORK/bin/wget" "$WORK/bin/msiextract"
export PATH="$WORK/bin:$PATH"
export WGET_CALLS="$WORK/wget-calls" MSIEXTRACT_CALLS="$WORK/msiextract-calls" MSI_FIXTURE="$WORK/solar2d.msi"
export GOOD_FIXTURE="$WORK/good.zip" PLACEHOLDER_FIXTURE="$WORK/placeholder.zip"
export NOWASM_FIXTURE="$WORK/nowasm.zip" TRAVERSAL_FIXTURE="$WORK/traversal.zip"
export WRONGVERSION_FIXTURE="$WORK/wrongversion.zip" WRONGFORK_FIXTURE="$WORK/wrongfork.zip"
export NOMANIFEST_FIXTURE="$WORK/nomanifest.zip" EMPTYMANIFEST_FIXTURE="$WORK/emptymanifest.zip"
export NOFORK_FIXTURE="$WORK/nofork.zip" WRONGTYPE_FIXTURE="$WORK/wrongtype.zip"
export NOINDEX_FIXTURE="$WORK/noindex.zip" NODEBUG_FIXTURE="$WORK/nodebug.zip"
export NOFBAPP_FIXTURE="$WORK/nofbapp.zip" NOWIDGET_FIXTURE="$WORK/nowidget.zip"
export OLDLAYOUT_FIXTURE="$WORK/oldlayout.zip" CORRUPT_FIXTURE="$WORK/corrupt.zip"
export SOLAR2D_VERSION=2026.3736
export RESOURCES_DIR="$WORK/resources" NATIVE_STAGING="$WORK/native-staging"
export PROVENANCE_OUT="$WORK/provenance.json"

PLACEHOLDER_CONTENTS=placeholder
reset_case() {
    rm -rf "$RESOURCES_DIR" "$NATIVE_STAGING"
    mkdir -p "$RESOURCES_DIR" "$NATIVE_STAGING"
    printf '%s' "$PLACEHOLDER_CONTENTS" > "$RESOURCES_DIR/webtemplate.zip"   # the source tree's 0-byte placeholder, made detectable
    rm -f "$PROVENANCE_OUT" "$WGET_CALLS" "$MSIEXTRACT_CALLS"
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
[ -s "$MSIEXTRACT_CALLS" ]   # the extraction log works — see the mismatch case below

reset_case
export SOLAR2D_MSI_SHA256=$MSI_SHA
expect_ok "default: MSI template, verified installer"
grep -q 'MSI sha256 verified' "$WORK/out.log"

# --- Installer verification negatives ----------------------------------------
reset_case
export SOLAR2D_MSI_SHA256=$BAD_SHA
expect_fail "MSI sha mismatch" 'MSI sha256 mismatch'
staged_unchanged
# Verification must happen before extraction: a mismatched installer is
# never unpacked. (Moving the check after msiextract would leave this log
# nonempty and fail here.)
[ ! -s "$MSIEXTRACT_CALLS" ]

reset_case
export SOLAR2D_MSI_SHA256="not-hex"
expect_fail "MSI sha malformed" '64 lowercase hex'
[ ! -s "$WGET_CALLS" ]   # format errors happen before any download

reset_case
export SOLAR2D_MSI_SHA256=$(printf 'A%.0s' {1..64})
expect_fail "MSI sha uppercase (correct length, wrong case)" '64 lowercase hex'
[ ! -s "$WGET_CALLS" ]

reset_case
export MSI_MISSING_WEBTEMPLATE=1
expect_fail "MSI without a webtemplate" 'no webtemplate'
unset MSI_MISSING_WEBTEMPLATE

# --- Override happy path -------------------------------------------------------
reset_case
export WEBTEMPLATE_URL=https://example.com/good.zip WEBTEMPLATE_SHA256=$GOOD_SHA
expect_fail "override without SOLAR2D_REF_SHA (no provenance cross-check possible)" 'requires SOLAR2D_REF_SHA'
staged_unchanged
[ ! -s "$WGET_CALLS" ]

reset_case
export WEBTEMPLATE_URL=https://example.com/good.zip WEBTEMPLATE_SHA256=$GOOD_SHA SOLAR2D_REF_SHA=$FORK_SHA
expect_ok "override: verified real-layout artifact replaces the MSI template"
cmp -s "$RESOURCES_DIR/webtemplate.zip" "$WORK/good.zip"
grep -q '"origin": "webtemplate-override"' "$PROVENANCE_OUT"
grep -qF "\"sha256\": \"$GOOD_SHA\"" "$PROVENANCE_OUT"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$PROVENANCE_OUT"

# Atomic install: the live template path must never see a partial write.
# The cp shim simulates an interrupted copy whenever the destination is the
# live webtemplate.zip — a direct copy would leave a truncated file there,
# the staged .incoming + rename never touches it.
reset_case
export WEBTEMPLATE_URL=https://example.com/good.zip WEBTEMPLATE_SHA256=$GOOD_SHA SOLAR2D_REF_SHA=$FORK_SHA
REAL_CP=$(command -v cp)
export REAL_CP
mkdir -p "$WORK/bin"
cat > "$WORK/bin/cp" <<'CP'
#!/bin/bash
set -uo pipefail
last=${*: -1:1}
if [ "$last" = "$RESOURCES_DIR/webtemplate.zip" ]; then
    printf partial > "$last"
    echo "cp shim: interrupted copy onto the live template" >&2
    exit 1
fi
exec "$REAL_CP" "$@"
CP
chmod +x "$WORK/bin/cp"
expect_ok "override: install is atomic — an interrupted copy never reaches the live path"
cmp -s "$RESOURCES_DIR/webtemplate.zip" "$WORK/good.zip"
[ ! -e "$RESOURCES_DIR/.webtemplate.zip.incoming" ]
rm -f "$WORK/bin/cp"

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
# Correct length, valid hex, uppercase: hashes are lowercase-only (the form
# sha256sum prints), so this must be rejected on content, not on length.
export WEBTEMPLATE_URL=https://example.com/good.zip WEBTEMPLATE_SHA256=$(printf 'A%.0s' {1..64})
expect_fail "uppercase checksum" '64 lowercase hex'
[ ! -s "$WGET_CALLS" ]

reset_case
export WEBTEMPLATE_URL=https://example.com/good.zip WEBTEMPLATE_SHA256=${GOOD_SHA}0
expect_fail "wrong-length checksum" '64 lowercase hex'

# --- Override negatives: never fall back to the MSI template -------------------
override_env() { # override_env URL SHA
    export WEBTEMPLATE_URL=$1 WEBTEMPLATE_SHA256=$2 SOLAR2D_REF_SHA=$FORK_SHA
}

reset_case
override_env https://example.com/good.zip $BAD_SHA
expect_fail "override checksum mismatch" 'sha256 mismatch' 'NOT falling back'
staged_unchanged

reset_case
override_env https://example.com/missing.zip $BAD_SHA
expect_fail "override artifact missing (download fails)" 'could not download' 'NOT falling back'
staged_unchanged

reset_case
override_env https://example.com/placeholder.zip "$(sha256sum "$WORK/placeholder.zip" | cut -d' ' -f1)"
expect_fail "placeholder zip (empty wasm)" 'rejected' 'coronaHtml5App.wasm'
staged_unchanged

reset_case
override_env https://example.com/nowasm.zip "$(sha256sum "$WORK/nowasm.zip" | cut -d' ' -f1)"
expect_fail "zip without the wasm entry" "missing entry 'html/coronaHtml5App.wasm'"
staged_unchanged

reset_case
override_env https://example.com/traversal.zip "$(sha256sum "$WORK/traversal.zip" | cut -d' ' -f1)"
expect_fail "zip with traversal entry" "unsafe entry"
staged_unchanged

reset_case
override_env https://example.com/corrupt.zip "$(sha256sum "$WORK/corrupt.zip" | cut -d' ' -f1)"
expect_fail "zip with a CRC-broken entry" 'zip integrity check failed'
staged_unchanged

reset_case
override_env https://example.com/noindex.zip "$(sha256sum "$WORK/noindex.zip" | cut -d' ' -f1)"
expect_fail "real layout without the template's html/index.html" "missing entry 'html/index.html'"
staged_unchanged

# New-rule negatives: each fixture carries html/resources/CORONA_LOGO.png,
# so the pre-correction validator accepted it — these fail on 32e140c.
reset_case
override_env https://example.com/nodebug.zip "$(sha256sum "$WORK/nodebug.zip" | cut -d' ' -f1)"
expect_fail "real layout without html/index-debug.html" "missing entry 'html/index-debug.html'"
staged_unchanged

reset_case
override_env https://example.com/nofbapp.zip "$(sha256sum "$WORK/nofbapp.zip" | cut -d' ' -f1)"
expect_fail "real layout without fbinstant/fbapp-config.json" "missing entry 'fbinstant/fbapp-config.json'"
staged_unchanged

reset_case
override_env https://example.com/nowidget.zip "$(sha256sum "$WORK/nowidget.zip" | cut -d' ' -f1)"
expect_fail "real layout with an empty res_widget/ (no widget png)" 'res_widget'
staged_unchanged

reset_case
override_env https://example.com/oldlayout.zip "$(sha256sum "$WORK/oldlayout.zip" | cut -d' ' -f1)"
expect_fail "old four-entry layout (CORONA_LOGO.png, no index-debug/fbinstant/res_widget)" "missing entry 'html/index-debug.html'"
staged_unchanged

# Provenance manifest: required, well-formed, and matching — an unattributed
# override must never reach Resources.
reset_case
override_env https://example.com/nomanifest.zip "$(sha256sum "$WORK/nomanifest.zip" | cut -d' ' -f1)"
expect_fail "zip without a provenance manifest" 'missing webtemplate-provenance.json'
staged_unchanged

reset_case
override_env https://example.com/emptymanifest.zip "$(sha256sum "$WORK/emptymanifest.zip" | cut -d' ' -f1)"
expect_fail "provenance manifest without any fields" 'engine_version must be a nonempty string'
staged_unchanged

reset_case
override_env https://example.com/nofork.zip "$(sha256sum "$WORK/nofork.zip" | cut -d' ' -f1)"
expect_fail "provenance manifest without fork_sha" 'fork_sha must be a nonempty string'
staged_unchanged

reset_case
override_env https://example.com/wrongtype.zip "$(sha256sum "$WORK/wrongtype.zip" | cut -d' ' -f1)"
expect_fail "provenance engine_version of the wrong type" 'engine_version must be a nonempty string'
staged_unchanged

reset_case
override_env https://example.com/wrongversion.zip "$(sha256sum "$WORK/wrongversion.zip" | cut -d' ' -f1)"
expect_fail "manifest engine_version mismatch" 'engine_version 2026.3734 does not match SOLAR2D_VERSION 2026.3736'
staged_unchanged

reset_case
override_env https://example.com/wrongfork.zip "$(sha256sum "$WORK/wrongfork.zip" | cut -d' ' -f1)"
export SOLAR2D_REF_SHA=cafebabe
expect_fail "manifest fork_sha mismatch" 'fork_sha deadbeef does not match SOLAR2D_REF_SHA cafebabe'
staged_unchanged

echo 'install-webtemplate checks passed (default, msi verify order, override, pairing, hashes, zip integrity/layout, provenance manifest, atomic install)'
