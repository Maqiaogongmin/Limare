#!/usr/bin/env bash
# Sign staged helper code without allowing a release-channel build to fall back to ad-hoc.
# The channel, not the Xcode configuration, decides: script/install_limare.sh builds the Release
# configuration as a development build signed with Apple Development, and needs no Developer ID.
set -euo pipefail

HELPER_PATH="${1:?usage: sign_helper.sh helper-path}"
case "${LIMARE_BUILD_CHANNEL:-}" in
  development)
    codesign --force --sign - --options runtime --timestamp=none "${HELPER_PATH}"
    ;;
  release)
    [[ "${CODE_SIGNING_ALLOWED:-YES}" != NO ]] || { echo 'error: Release helper signing cannot be disabled.' >&2; exit 1; }
    SIGNING_IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-${CODESIGN_IDENTITY:-}}}"
    [[ -n "${SIGNING_IDENTITY}" && "${SIGNING_IDENTITY}" != - ]] || { echo 'error: Release requires a Developer ID Application identity.' >&2; exit 1; }
    [[ -n "${DEVELOPMENT_TEAM:-}" ]] || { echo 'error: Release requires DEVELOPMENT_TEAM.' >&2; exit 1; }
    # Resolve the identity before signing. Keep private certificate descriptions out of logs.
    IDENTITIES="$(security find-identity -v -p codesigning)"
    MATCHED_IDENTITY="$(printf '%s\n' "${IDENTITIES}" | awk -v identity="${SIGNING_IDENTITY}" 'index($0, "Developer ID Application:") && (index($0, identity) || identity == "Developer ID Application") { print $2 }')"
    [[ "${MATCHED_IDENTITY}" =~ ^[[:xdigit:]]{40}$ ]] || { echo 'error: Release identity must resolve to exactly one valid Developer ID Application certificate.' >&2; exit 1; }
    codesign --force --sign "${MATCHED_IDENTITY}" --options runtime --timestamp "${HELPER_PATH}"
    SIGNATURE="$(codesign -dvvv "${HELPER_PATH}" 2>&1)"
    printf '%s\n' "${SIGNATURE}" | grep -q '^Authority=Developer ID Application:' || { echo 'error: Helper has no Developer ID Application signature.' >&2; exit 1; }
    printf '%s\n' "${SIGNATURE}" | grep -q '^Timestamp=' || { echo 'error: Helper has no secure timestamp.' >&2; exit 1; }
    printf '%s\n' "${SIGNATURE}" | grep -q 'flags=.*runtime' || { echo 'error: Helper has no Hardened Runtime.' >&2; exit 1; }
    ACTUAL_TEAM="$(printf '%s\n' "${SIGNATURE}" | sed -n 's/^TeamIdentifier=//p')"
    [[ "${ACTUAL_TEAM}" == "${DEVELOPMENT_TEAM}" ]] || { echo 'error: Helper signing team differs from the app team.' >&2; exit 1; }
    ;;
  *) echo 'error: LIMARE_BUILD_CHANNEL must be development or release.' >&2; exit 1 ;;
esac
codesign --verify --strict "${HELPER_PATH}"
