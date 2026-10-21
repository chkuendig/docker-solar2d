#!/bin/bash
#=============================================================================
# install-webtemplate.sh — image-build-time template staging
#
# Runs inside the Docker compile stage. Downloads the official Windows MSI
# (optionally verifying it against a SHA256), extracts the webtemplate plus
# the Android/shared native components the Linux tree does not build, and —
# when WEBTEMPLATE_URL/WEBTEMPLATE_SHA256 are set — replaces the MSI's
# webtemplate with that verified artifact. With neither override variable
# set, the behavior is exactly the historical one: the MSI's template.
#
# A failed override never falls back to the MSI template: the point of an
# override is a patched engine, and silently shipping the unpatched one
# would defeat it.
#
# Environment inputs (all optional unless noted):
#   SOLAR2D_VERSION     required, e.g. 2026.3736
#   SOLAR2D_MSI_SHA256  verify the MSI before extraction (64 lowercase hex)
#   WEBTEMPLATE_URL     HTTPS URL of a patched webtemplate.zip
#   WEBTEMPLATE_SHA256  its checksum; both-or-neither with the URL
#   SOLAR2D_REF_SHA     required with an override: the fork commit the
#                       artifact's embedded webtemplate-provenance.json
#                       must carry, alongside the engine version
#   RESOURCES_DIR       where webtemplate.zip is staged
#   NATIVE_STAGING      where the MSI's Native/Corona pieces are staged
#   PROVENANCE_OUT      JSON record of what was actually staged
#=============================================================================
set -euo pipefail

fail() { echo "::error::install-webtemplate: $*" >&2; exit 1; }

: "${SOLAR2D_VERSION:?SOLAR2D_VERSION must be set (e.g. 2026.3736)}"
SOLAR2D_MSI_SHA256=${SOLAR2D_MSI_SHA256:-}
WEBTEMPLATE_URL=${WEBTEMPLATE_URL:-}
WEBTEMPLATE_SHA256=${WEBTEMPLATE_SHA256:-}
SOLAR2D_REF_SHA=${SOLAR2D_REF_SHA:-}
RESOURCES_DIR=${RESOURCES_DIR:-/opt/solar2d/platform/resources}
NATIVE_STAGING=${NATIVE_STAGING:-/opt/native-staging}
PROVENANCE_OUT=${PROVENANCE_OUT:-/opt/template-provenance.json}

sha256_of() { sha256sum "$1" | cut -d' ' -f1; }
is_hex64() { [[ $1 =~ ^[0-9a-f]{64}$ ]]; }

# Pairing and format are checked before anything is downloaded, so a bad
# combination costs nothing.
if { [ -n "$WEBTEMPLATE_URL" ] && [ -z "$WEBTEMPLATE_SHA256" ]; } ||
   { [ -z "$WEBTEMPLATE_URL" ] && [ -n "$WEBTEMPLATE_SHA256" ]; }; then
    fail "WEBTEMPLATE_URL and WEBTEMPLATE_SHA256 must be set together (URL '${WEBTEMPLATE_URL:+set}', sha256 '${WEBTEMPLATE_SHA256:+set}')"
fi
[ -z "$WEBTEMPLATE_SHA256" ] || is_hex64 "$WEBTEMPLATE_SHA256" \
    || fail "WEBTEMPLATE_SHA256 must be 64 lowercase hex digits, got '$WEBTEMPLATE_SHA256'"
[ -z "$SOLAR2D_MSI_SHA256" ] || is_hex64 "$SOLAR2D_MSI_SHA256" \
    || fail "SOLAR2D_MSI_SHA256 must be 64 lowercase hex digits, got '$SOLAR2D_MSI_SHA256'"
if [ -n "$WEBTEMPLATE_URL" ]; then
    [ -n "$SOLAR2D_REF_SHA" ] \
        || fail "a webtemplate override requires SOLAR2D_REF_SHA: the artifact's provenance manifest is cross-checked against it"
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# --- Official MSI: template + Android/shared native components -------------
MSI_URL="https://github.com/coronalabs/corona/releases/download/${SOLAR2D_VERSION#*.}/Solar2D-Windows-${SOLAR2D_VERSION}.msi"
echo "Downloading $MSI_URL"
wget -q "$MSI_URL" -O "$WORK/solar2d.msi" \
    || fail "could not download the official Windows MSI for $SOLAR2D_VERSION"
if [ -n "$SOLAR2D_MSI_SHA256" ]; then
    GOT=$(sha256_of "$WORK/solar2d.msi")
    [ "$GOT" = "$SOLAR2D_MSI_SHA256" ] \
        || fail "MSI sha256 mismatch: wanted $SOLAR2D_MSI_SHA256, got $GOT"
    echo "MSI sha256 verified: $GOT"
fi

EXTRACT="$WORK/msi"
mkdir "$EXTRACT"
(cd "$EXTRACT" && msiextract "$WORK/solar2d.msi") > /dev/null
MSI_WEBTEMPLATE=$(find "$EXTRACT" -name webtemplate.zip -print -quit)
[ -n "$MSI_WEBTEMPLATE" ] || fail "the MSI for $SOLAR2D_VERSION contains no webtemplate.zip"
[ -s "$MSI_WEBTEMPLATE" ] || fail "the MSI's webtemplate.zip is empty"
NATIVE=$(find "$EXTRACT" -type d -path "*/Native/Corona" -print -quit)
[ -n "$NATIVE" ] || fail "the MSI contains no Native/Corona directory"
mkdir -p "$NATIVE_STAGING"
cp -r "$NATIVE/android" "$NATIVE/shared" "$NATIVE_STAGING/"
test -f "$NATIVE_STAGING/android/resource/android-template.zip" \
    || fail "the MSI's Native/Corona/android is missing android-template.zip"
test -f "$NATIVE_STAGING/android/lib/gradle/Corona.aar" \
    || fail "the MSI's Native/Corona/android is missing lib/gradle/Corona.aar"
MSI_TEMPLATE_SHA=$(sha256_of "$MSI_WEBTEMPLATE")
MSI_SHA=$(sha256_of "$WORK/solar2d.msi")

# --- Template selection -----------------------------------------------------
mkdir -p "$RESOURCES_DIR"
TEMPLATE_ORIGIN=msi
if [ -z "$WEBTEMPLATE_URL" ]; then
    cp "$MSI_WEBTEMPLATE" "$RESOURCES_DIR/webtemplate.zip"
else
    OVERRIDE="$WORK/webtemplate-override.zip"
    echo "Downloading patched webtemplate: $WEBTEMPLATE_URL"
    wget -q "$WEBTEMPLATE_URL" -O "$OVERRIDE" \
        || fail "could not download the webtemplate override — NOT falling back to the MSI template"
    GOT=$(sha256_of "$OVERRIDE")
    [ "$GOT" = "$WEBTEMPLATE_SHA256" ] \
        || fail "webtemplate sha256 mismatch: wanted $WEBTEMPLATE_SHA256, got $GOT — NOT falling back to the MSI template"

    # Shape and provenance checks before the file is allowed near Resources:
    # a placeholder, corrupt or unattributed archive must fail the build here.
    python3 - "$OVERRIDE" <<'PYVALIDATE' || fail "the override zip failed validation (errors above)"
import json, os, sys, zipfile

path = sys.argv[1]
version = os.environ.get("SOLAR2D_VERSION", "")
ref_sha = os.environ.get("SOLAR2D_REF_SHA", "")

def bad(msg):
    print(f"::error::install-webtemplate: webtemplate override rejected: {msg}", file=sys.stderr)
    sys.exit(1)

with zipfile.ZipFile(path) as z:
    corrupt = z.testzip()
    if corrupt is not None:
        bad(f"zip integrity check failed at entry '{corrupt}' (CRC mismatch)")
    names = z.namelist()
    for name in names:
        if name.startswith(("/", "\\")) or ".." in name.split("/"):
            bad(f"unsafe entry '{name}'")
    # The exact entries the default MSI template carries — a patched
    # template is a rebuild of that layout, not an arbitrary zip that
    # happens to contain a wasm somewhere.
    for name in ("html/coronaHtml5App.wasm", "html/coronaHtml5App.js",
                 "html/index.html", "html/resources/CORONA_LOGO.png"):
        if name not in names:
            bad(f"missing entry '{name}'")
        if z.getinfo(name).file_size == 0:
            bad(f"entry '{name}' is empty")

    # Provenance is not optional for an override: the manifest is what ties
    # the artifact to the engine version and fork commit it was built for.
    if "webtemplate-provenance.json" not in names:
        bad("missing webtemplate-provenance.json — an override must carry its provenance manifest")
    try:
        manifest = json.loads(z.read("webtemplate-provenance.json"))
    except ValueError as e:
        bad(f"webtemplate-provenance.json is not valid JSON: {e}")
    if not isinstance(manifest, dict):
        bad("webtemplate-provenance.json must be a JSON object")
    for field, env_name, expected in (
        ("engine_version", "SOLAR2D_VERSION", version),
        ("fork_sha", "SOLAR2D_REF_SHA", ref_sha),
    ):
        value = manifest.get(field)
        if not isinstance(value, str) or not value:
            bad(f"provenance {field} must be a nonempty string in webtemplate-provenance.json")
        if expected and value != expected:
            bad(f"provenance {field} {value} does not match {env_name} {expected}")
PYVALIDATE

    # Atomic install: a half-written template must never be visible to CMake.
    cp "$OVERRIDE" "$RESOURCES_DIR/.webtemplate.zip.incoming"
    mv -f "$RESOURCES_DIR/.webtemplate.zip.incoming" "$RESOURCES_DIR/webtemplate.zip"
    TEMPLATE_ORIGIN=webtemplate-override
fi

# --- Provenance record ------------------------------------------------------
# The effective hash is measured from the staged file, never trusted from an
# argument: this JSON is the record of what actually went into the build.
EFFECTIVE_SHA=$(sha256_of "$RESOURCES_DIR/webtemplate.zip")
EFFECTIVE_BYTES=$(stat -c %s "$RESOURCES_DIR/webtemplate.zip")
python3 - "$PROVENANCE_OUT" "$SOLAR2D_VERSION" "$SOLAR2D_REF_SHA" "$MSI_SHA" \
    "$MSI_TEMPLATE_SHA" "$TEMPLATE_ORIGIN" "$WEBTEMPLATE_URL" \
    "$WEBTEMPLATE_SHA256" "$EFFECTIVE_SHA" "$EFFECTIVE_BYTES" <<'PYPROV'
import json, sys

out, version, ref_sha, msi_sha, msi_template_sha, origin, url, wanted, effective, size = sys.argv[1:11]
record = {
    "engine_version": version,
    "engine_fork_sha": ref_sha,
    "msi_sha256": msi_sha,
    "msi_webtemplate_sha256": msi_template_sha,
    "webtemplate": {
        "origin": origin,
        "override_url": url,
        "requested_sha256": wanted,
        "sha256": effective,
        "bytes": int(size),
    },
}
with open(out, "w") as f:
    json.dump(record, f, indent=2, sort_keys=True)
    f.write("\n")
PYPROV

echo "webtemplate staged: origin=$TEMPLATE_ORIGIN sha256=$EFFECTIVE_SHA bytes=$EFFECTIVE_BYTES"
echo "provenance written to $PROVENANCE_OUT"
