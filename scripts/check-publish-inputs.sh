#!/bin/bash
#=============================================================================
# check-publish-inputs.sh — cheap validation of a Publish workflow dispatch
#
# Runs in the resolve job, before any expensive work: rejects impossible or
# dangerous input combinations so a candidate build cannot start on a bad
# interface (half a URL/checksum pair, a malformed or reserved tag, an
# override without its pins). Reads everything from environment variables;
# prints a summary or fails with ::error.
#
#   INPUT_SOLAR2D_VERSION       manual version input ("" = auto-detect)
#   INPUT_SOLAR2D_REF           manual fork branch input
#   INPUT_IMAGE_TAG             candidate tag input
#   INPUT_WEBTEMPLATE_URL       patched webtemplate URL input
#   INPUT_WEBTEMPLATE_SHA256    patched webtemplate checksum input
#   INPUT_SOLAR2D_MSI_SHA256    installer checksum input
#   RESOLVED_VERSION            version resolved by the workflow
#   RESOLVED_TAG                numeric tag resolved by the workflow
#   PATCHED_TEMPLATE_VERSION    the one version a patched template exists for
#=============================================================================
set -euo pipefail

fail() { echo "::error::publish inputs: $*" >&2; exit 1; }
note() { echo "publish inputs: $*"; }

INPUT_SOLAR2D_VERSION=${INPUT_SOLAR2D_VERSION:-}
INPUT_SOLAR2D_REF=${INPUT_SOLAR2D_REF:-}
INPUT_IMAGE_TAG=${INPUT_IMAGE_TAG:-}
INPUT_WEBTEMPLATE_URL=${INPUT_WEBTEMPLATE_URL:-}
INPUT_WEBTEMPLATE_SHA256=${INPUT_WEBTEMPLATE_SHA256:-}
INPUT_SOLAR2D_MSI_SHA256=${INPUT_SOLAR2D_MSI_SHA256:-}
RESOLVED_VERSION=${RESOLVED_VERSION:?RESOLVED_VERSION must be provided}
RESOLVED_TAG=${RESOLVED_TAG:?RESOLVED_TAG must be provided}
PATCHED_TEMPLATE_VERSION=${PATCHED_TEMPLATE_VERSION:-2026.3736}

is_hex64() { [[ $1 =~ ^[0-9a-f]{64}$ ]]; }

# A candidate tag must be a single, strictly-formed Docker tag. The tag is
# fed to metadata-action's CSV parser, which splits on commas and trims
# whitespace — "latest,priority=1000" or " latest" would smuggle a second
# label or resolve to a reserved name there. Strict syntax first, then the
# reserved comparison, which stays case-sensitive as Docker tags are.
if [ -n "$INPUT_IMAGE_TAG" ]; then
    [[ $INPUT_IMAGE_TAG =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] \
        || fail "image_tag must be a single Docker tag ([A-Za-z0-9_][A-Za-z0-9_.-]{0,127}, no commas, whitespace or control characters), got '$INPUT_IMAGE_TAG'"
fi

# A candidate tag must never collide with a tag that consumers resolve
# releases through — moving "latest" or the release alias from a candidate
# run would ship an unaccepted engine to everyone.
for reserved in latest stable release "$RESOLVED_TAG"; do
    if [ -n "$INPUT_IMAGE_TAG" ] && [ "$INPUT_IMAGE_TAG" = "$reserved" ]; then
        fail "image_tag '$INPUT_IMAGE_TAG' is reserved (latest/stable/release or the release tag '$RESOLVED_TAG'); a candidate needs its own tag"
    fi
done

[ -z "$INPUT_WEBTEMPLATE_SHA256" ] || is_hex64 "$INPUT_WEBTEMPLATE_SHA256" \
    || fail "webtemplate_sha256 must be 64 lowercase hex digits, got '$INPUT_WEBTEMPLATE_SHA256'"
[ -z "$INPUT_SOLAR2D_MSI_SHA256" ] || is_hex64 "$INPUT_SOLAR2D_MSI_SHA256" \
    || fail "solar2d_msi_sha256 must be 64 lowercase hex digits, got '$INPUT_SOLAR2D_MSI_SHA256'"

if { [ -n "$INPUT_WEBTEMPLATE_URL" ] && [ -z "$INPUT_WEBTEMPLATE_SHA256" ]; } ||
   { [ -z "$INPUT_WEBTEMPLATE_URL" ] && [ -n "$INPUT_WEBTEMPLATE_SHA256" ]; }; then
    fail "webtemplate_url and webtemplate_sha256 must be set together"
fi

if [ -n "$INPUT_WEBTEMPLATE_URL" ]; then
    # The URL is fed verbatim into build-args and image labels; anything
    # but a single https URL — a newline or tab smuggled through a dispatch
    # input — would be executed as more input there.
    [[ $INPUT_WEBTEMPLATE_URL =~ ^https://[^[:space:][:cntrl:]]+$ ]] \
        || fail "webtemplate_url must be a single https:// URL with no whitespace or control characters, got '$INPUT_WEBTEMPLATE_URL'"
    # An override template exists for exactly one engine version, so the
    # build must pin that version explicitly instead of auto-detecting, must
    # say which fork branch carries the patch, must verify the installer it
    # still extracts Android components from, and must land on a candidate
    # tag — never on latest or the release alias.
    [ "$INPUT_SOLAR2D_VERSION" = "$PATCHED_TEMPLATE_VERSION" ] \
        || fail "a webtemplate override requires solar2d_version=$PATCHED_TEMPLATE_VERSION explicitly (got '${INPUT_SOLAR2D_VERSION:-auto-detect}')"
    [ -n "$INPUT_SOLAR2D_REF" ] \
        || fail "a webtemplate override requires solar2d_ref (the fork branch carrying the patch)"
    [ -n "$INPUT_IMAGE_TAG" ] \
        || fail "a webtemplate override requires image_tag; it must not move latest or the release tag"
    is_hex64 "$INPUT_SOLAR2D_MSI_SHA256" \
        || fail "a webtemplate override requires solar2d_msi_sha256 so the extracted installer is verified"
    note "candidate build: patched webtemplate for $PATCHED_TEMPLATE_VERSION, tag $INPUT_IMAGE_TAG"
else
    note "no webtemplate override: the official MSI template will be used"
fi
[ -z "$INPUT_IMAGE_TAG" ] || note "candidate tag: $INPUT_IMAGE_TAG"
