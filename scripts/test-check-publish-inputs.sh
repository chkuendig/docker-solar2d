#!/bin/bash
# Negative- and positive-path checks for check-publish-inputs.sh.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

SHA=$(printf 'a%.0s' {1..64})
SHA2=$(printf 'b%.0s' {1..64})

run() { env -i \
    INPUT_SOLAR2D_VERSION="${INPUT_SOLAR2D_VERSION:-}" \
    INPUT_SOLAR2D_REF="${INPUT_SOLAR2D_REF:-}" \
    INPUT_IMAGE_TAG="${INPUT_IMAGE_TAG:-}" \
    INPUT_WEBTEMPLATE_URL="${INPUT_WEBTEMPLATE_URL:-}" \
    INPUT_WEBTEMPLATE_SHA256="${INPUT_WEBTEMPLATE_SHA256:-}" \
    INPUT_SOLAR2D_MSI_SHA256="${INPUT_SOLAR2D_MSI_SHA256:-}" \
    RESOLVED_VERSION="${RESOLVED_VERSION:-2026.3736}" \
    RESOLVED_TAG="${RESOLVED_TAG:-3736}" \
    bash "$ROOT/check-publish-inputs.sh" > "$WORK/out.log" 2>&1
}

expect_ok() {
    local desc=$1
    run || { echo "FAIL (expected success): $desc" >&2; sed 's/^/    /' "$WORK/out.log" >&2; exit 1; }
    echo "ok: $desc"
}

expect_fail() {
    local desc=$1 pattern=$2
    local status=0
    run || status=$?
    [ "$status" != 0 ] || { echo "FAIL (expected failure): $desc" >&2; exit 1; }
    grep -qi -- "$pattern" "$WORK/out.log" || {
        echo "FAIL: '$desc' failed without mentioning '$pattern'" >&2
        sed 's/^/    /' "$WORK/out.log" >&2
        exit 1
    }
    echo "ok: $desc (rejected)"
}

# The default dispatch — nothing set — is exactly today's interface.
unset INPUT_SOLAR2D_VERSION INPUT_SOLAR2D_REF INPUT_IMAGE_TAG \
      INPUT_WEBTEMPLATE_URL INPUT_WEBTEMPLATE_SHA256 INPUT_SOLAR2D_MSI_SHA256
expect_ok "default dispatch (no optional inputs)"

INPUT_SOLAR2D_VERSION=2026.3736
expect_ok "plain version override, still no webtemplate override"

# Reserved candidate tags.
INPUT_IMAGE_TAG=latest
expect_fail "candidate tag 'latest'" 'reserved'
INPUT_IMAGE_TAG=3736
expect_fail "candidate tag equals the release tag" 'reserved'
INPUT_IMAGE_TAG=release
expect_fail "candidate tag 'release'" 'reserved'

# Strict single-tag syntax: metadata-action parses the tag line as CSV, so
# "latest,priority=1000" or " latest" would smuggle extra labels or alias a
# reserved name there. These must be rejected by format, before (and
# independently of) the reserved-name comparison.
INPUT_IMAGE_TAG='latest,priority=1000'
expect_fail "candidate tag with a CSV label payload" 'single Docker tag'
INPUT_IMAGE_TAG='stable,priority=1000'
expect_fail "CSV payload against 'stable'" 'single Docker tag'
INPUT_IMAGE_TAG='3736,priority=1000'
expect_fail "release tag plus CSV payload" 'single Docker tag'
INPUT_IMAGE_TAG=' latest'
expect_fail "candidate tag with leading whitespace" 'single Docker tag'
INPUT_IMAGE_TAG='Latest'
expect_ok "reserved comparison is case-sensitive: 'Latest' is a distinct, valid tag"
INPUT_IMAGE_TAG=

# Pairing and format.
INPUT_WEBTEMPLATE_URL=https://example.com/webtemplate.zip
expect_fail "URL without checksum" 'set together'
INPUT_WEBTEMPLATE_URL=
INPUT_WEBTEMPLATE_SHA256=$SHA
expect_fail "checksum without URL" 'set together'
INPUT_WEBTEMPLATE_URL=https://example.com/webtemplate.zip
# Correct length, valid hex digits, uppercase: hashes are lowercase-only
# (the form sha256sum prints), so this must be rejected on content, not
# length.
INPUT_WEBTEMPLATE_SHA256=$(printf 'A%.0s' {1..64})
expect_fail "uppercase checksum" '64 lowercase hex'
INPUT_WEBTEMPLATE_SHA256=${SHA}0
expect_fail "wrong-length checksum" '64 lowercase hex'
INPUT_WEBTEMPLATE_SHA256=$SHA
INPUT_SOLAR2D_MSI_SHA256=nope
expect_fail "malformed MSI checksum" '64 lowercase hex'
INPUT_SOLAR2D_MSI_SHA256=$(printf 'B%.0s' {1..64})
expect_fail "uppercase MSI checksum" '64 lowercase hex'
INPUT_SOLAR2D_MSI_SHA256=$SHA2

# An override is a candidate acceptance build: every pin is required.
INPUT_SOLAR2D_VERSION=
expect_fail "override with auto-detected version" "solar2d_version=2026.3736 explicitly"
INPUT_SOLAR2D_VERSION=2026.3734
expect_fail "override pinned to the wrong version" "solar2d_version=2026.3736 explicitly"
INPUT_SOLAR2D_VERSION=2026.3736
INPUT_SOLAR2D_REF=
expect_fail "override without solar2d_ref" 'requires solar2d_ref'
INPUT_SOLAR2D_REF=linux-3736
INPUT_IMAGE_TAG=
expect_fail "override without image_tag" 'requires image_tag'
INPUT_IMAGE_TAG=candidate-3736-a1b2c3d
INPUT_SOLAR2D_MSI_SHA256=
expect_fail "override without MSI checksum" 'requires solar2d_msi_sha256'

# And the complete, correctly pinned candidate passes.
INPUT_SOLAR2D_MSI_SHA256=$SHA2
expect_ok "fully pinned candidate override"
grep -q 'candidate build' "$WORK/out.log"

# A webtemplate_url that is not one clean https URL must be rejected even
# with every other pin present: publish.yml feeds it verbatim into
# build-args, so an embedded newline injects a second assignment there.
INPUT_WEBTEMPLATE_URL=$'https://example.com/t.zip\nSOLAR2D_REF_SHA=x'
expect_fail "webtemplate_url with an embedded newline (input injection)" 'single https:// URL'
INPUT_WEBTEMPLATE_URL=$'https://example.com/t.zip\tSOLAR2D_REF_SHA=x'
expect_fail "webtemplate_url with a tab" 'single https:// URL'
INPUT_WEBTEMPLATE_URL='http://example.com/t.zip'
expect_fail "webtemplate_url that is not https" 'single https:// URL'
INPUT_WEBTEMPLATE_URL=' https://example.com/t.zip'
expect_fail "webtemplate_url with leading whitespace" 'single https:// URL'
INPUT_WEBTEMPLATE_URL=https://example.com/webtemplate.zip
expect_ok "fully pinned candidate override with a clean https URL"

echo 'check-publish-inputs checks passed (default, tag syntax, reserved tags, pairing, override pins, URL shape)'
