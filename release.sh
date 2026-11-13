#!/bin/zsh
# Builds a Developer ID signed, notarized, stapled "build/AlwaysOn-<version>.dmg" for
# distribution outside the App Store.
#
#   ./release.sh                 # build, sign, notarize, staple
#   ./release.sh --lite          # same for the Lite build -> build/AlwaysOn-Lite-<version>.dmg
#   ./release.sh --no-notarize   # build and sign only (Gatekeeper will block it on other Macs)
#
# Env overrides:
#   SIGN_ID          codesign identity (default: first "Developer ID Application" in keychain)
#   NOTARY_PROFILE   notarytool keychain profile (default: AlwaysOn). Create it once with:
#                    xcrun notarytool store-credentials AlwaysOn --apple-id <id> --team-id <team>
set -euo pipefail
cd "${0:A:h}"

NOTARIZE=1
LITE=0
for arg in "$@"; do
  case "$arg" in
    --no-notarize) NOTARIZE=0 ;;
    --lite) LITE=1 ;;
    *) echo "usage: $0 [--lite] [--no-notarize]" >&2; exit 2 ;;
  esac
done

NOTARY_PROFILE="${NOTARY_PROFILE:-AlwaysOn}"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
if (( LITE )); then
  APP="build/lite/Always On.app"
  DMG="build/AlwaysOn-Lite-$VERSION.dmg"
  STAGE="build/dmg-lite"
  BUILD_ARGS=(--lite)
else
  APP="build/Always On.app"
  DMG="build/AlwaysOn-$VERSION.dmg"
  STAGE="build/dmg"
  BUILD_ARGS=()
fi

SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning \
  | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)}"
if [[ -z "$SIGN_ID" ]]; then
  echo "error: no \"Developer ID Application\" identity in keychain; set SIGN_ID" >&2
  exit 1
fi

if (( NOTARIZE )) && ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  cat >&2 <<EOF
error: notarytool profile "$NOTARY_PROFILE" missing or invalid. Create it once with:
  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <apple-id> --team-id <team-id>
(it prompts for an app-specific password from account.apple.com), or rerun with --no-notarize.
EOF
  exit 1
fi

echo "==> Building"
./build.sh "${BUILD_ARGS[@]}"

echo "==> Signing app with: $SIGN_ID"
codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "==> Creating $DMG"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Always On" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$SIGN_ID" "$DMG"

if (( ! NOTARIZE )); then
  echo "Built $DMG (signed, NOT notarized)"
  exit 0
fi

echo "==> Notarizing (usually a few minutes)"
result=$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --output-format plist)
submission_status=$(plutil -extract status raw - <<<"$result")
if [[ "$submission_status" != "Accepted" ]]; then
  submission_id=$(plutil -extract id raw - <<<"$result")
  echo "error: notarization $submission_status; log:" >&2
  xcrun notarytool log "$submission_id" --keychain-profile "$NOTARY_PROFILE" >&2
  exit 1
fi

echo "==> Stapling"
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

echo "Built $DMG (signed, notarized, stapled)"
