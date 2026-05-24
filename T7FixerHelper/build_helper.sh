#!/bin/bash
# Builds the privileged helper tool, embeds it in the app bundle at
# Contents/MacOS/<helper-name>, copies the launchd plist to
# Contents/Library/LaunchDaemons/<helper-name>.plist, and signs it.
#
# Invoked by an Xcode Run Script Build Phase in the main app target.
set -euo pipefail

HELPER_NAME="net.mnmldsgn.t7fixer.helper"
HELPER_SRC="${SRCROOT}/T7FixerHelper"
APP_BUNDLE="${TARGET_BUILD_DIR}/${WRAPPER_NAME}"
HELPER_DEST_DIR="${APP_BUNDLE}/Contents/MacOS"
LAUNCHD_DEST_DIR="${APP_BUNDLE}/Contents/Library/LaunchDaemons"
HELPER_OUT="${HELPER_DEST_DIR}/${HELPER_NAME}"

mkdir -p "$HELPER_DEST_DIR" "$LAUNCHD_DEST_DIR"

# Collect helper Swift sources
SOURCES=()
while IFS= read -r f; do
    SOURCES+=("$f")
done < <(find "$HELPER_SRC" -name "*.swift" -type f)

if [ ${#SOURCES[@]} -eq 0 ]; then
    echo "error: no helper Swift sources found in $HELPER_SRC" >&2
    exit 1
fi

# Pick an arch. Xcode passes ARCHS which may contain multiple (e.g. "arm64 x86_64").
# For the helper we compile for the first arch only; lipo-merge later if needed.
ARCH="${ARCHS%% *}"
if [ -z "$ARCH" ] || [ "$ARCH" = "undefined_arch" ]; then
    ARCH="$(uname -m)"
fi

DEPLOY_TARGET="${MACOSX_DEPLOYMENT_TARGET:-15.7}"

echo "Building helper: arch=$ARCH target=macos$DEPLOY_TARGET"

xcrun -sdk macosx swiftc \
    -target "${ARCH}-apple-macos${DEPLOY_TARGET}" \
    -O \
    -emit-executable \
    -o "$HELPER_OUT" \
    -Xlinker -sectcreate \
    -Xlinker __TEXT \
    -Xlinker __info_plist \
    -Xlinker "${HELPER_SRC}/Info.plist" \
    "${SOURCES[@]}"

cp -f "${HELPER_SRC}/${HELPER_NAME}.plist" "${LAUNCHD_DEST_DIR}/${HELPER_NAME}.plist"

# Sign if a signing identity is available (skipped for ad-hoc dev builds with no identity).
SIGN_ID="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-}}"
if [ -n "$SIGN_ID" ] && [ "$SIGN_ID" != "" ]; then
    echo "Signing helper with identity: $SIGN_ID"
    codesign --force \
        --sign "$SIGN_ID" \
        --identifier "$HELPER_NAME" \
        --entitlements "${HELPER_SRC}/Helper.entitlements" \
        --timestamp=none \
        --options runtime \
        "$HELPER_OUT"
else
    echo "warning: no signing identity, helper left unsigned (won't load via SMAppService)"
fi

echo "Helper installed at $HELPER_OUT"
