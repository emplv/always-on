#!/bin/zsh
# Uploads the notarized release DMGs to the download server behind alwayson.emplv.com:
# the versioned files, plus the stable names the landing page links to
# (AlwaysOn.dmg, AlwaysOn-Lite.dmg).
#
#   ./release.sh && ./release.sh --lite
#   PUBLISH_HOST=user@host ./publish.sh
#
# PUBLISH_HOST: the server's SSH login. It isn't stored here because this repo is public.
# The server's Caddy (emplv.com repo, deploy/emplv-com.caddy) serves /srv/alwayson/downloads
# at https://alwayson.emplv.com/downloads/.
set -euo pipefail
cd "${0:A:h}"

: "${PUBLISH_HOST:?set PUBLISH_HOST=user@host}"
REMOTE_DIR=/srv/alwayson/downloads
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
FILES=("build/AlwaysOn-$VERSION.dmg" "build/AlwaysOn-Lite-$VERSION.dmg")

for file in "${FILES[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "error: $file missing; run ./release.sh and ./release.sh --lite first" >&2
    exit 1
  fi
  if ! xcrun stapler validate "$file" >/dev/null 2>&1; then
    echo "error: $file isn't notarized and stapled; Gatekeeper would block it" >&2
    exit 1
  fi
done

echo "==> Uploading $VERSION to $PUBLISH_HOST:$REMOTE_DIR"
ssh "$PUBLISH_HOST" "sudo install -d -m 755 -o \$(id -un) $REMOTE_DIR"
scp "${FILES[@]}" "$PUBLISH_HOST:$REMOTE_DIR/"

# Swap the stable names in with a rename, so a download never gets a half-copied file.
ssh "$PUBLISH_HOST" "set -e; cd $REMOTE_DIR
  for name in AlwaysOn AlwaysOn-Lite; do
    cp -f \$name-$VERSION.dmg .\$name.dmg.tmp && mv -f .\$name.dmg.tmp \$name.dmg
  done
  chmod 644 *.dmg && ls -la"

echo "==> Checking the public URLs"
for name in AlwaysOn AlwaysOn-Lite; do
  curl -fsSI "https://alwayson.emplv.com/downloads/$name.dmg" | head -1
done
