#!/usr/bin/env bash
#
# macos-dmg.sh
#
# signs a bundled Kraken.app with a Developer ID Application certificate and the hardened runtime, notarizes and
# staples it, then wraps it in a signed, notarized and stapled dmg that opens without a gatekeeper warning
#
# usage: Tools/Distribute/macos-dmg.sh <app> <out dir> [identity] [notary profile]
#
# one time setup:
#   1. Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application
#   2. an app specific password from account.apple.com, then
#      xcrun notarytool store-credentials kraken-notary --apple-id <apple id> --team-id 3Y6K453V6S

set -euo pipefail

app="${1:?usage: macos-dmg.sh <app> <out dir> [identity] [notary profile]}"
out="${2:?usage: macos-dmg.sh <app> <out dir> [identity] [notary profile]}"
search="${3:-Developer ID Application}"
profile="${4:-kraken-notary}"

fail() { echo "error: $*" >&2; exit 1; }

[[ -d "$app/Contents" ]] || fail "$app is not a macOS app bundle, run make bundle first"

# the certificate by its hash, so a second matching name never picks the wrong one
identity="$(security find-identity -v -p codesigning | grep "$search" | head -1 | awk '{print $2}')"
[[ -n "$identity" ]] || fail "no '$search' certificate in the keychain, see the setup steps at the top of this script"
xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1 \
  || fail "no notarytool credentials named '$profile', see the setup steps at the top of this script"

name="$(basename "$app" .app)"
version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")"
mkdir -p "$out"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# usd loads render delegate plugins signed by other teams, such as hdPrman from a RenderMan install
entitlements="$work/entitlements.plist"
cat > "$entitlements" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.cs.disable-library-validation</key>
  <true/>
</dict>
</plist>
PLIST

sign() { codesign --force --timestamp --options runtime --sign "$identity" "$@"; }

echo "signing $name $version"

# loose mach-o files first, deepest paths first, then frameworks as whole bundles, then the app itself
while IFS= read -r -d '' file; do
  [[ "$file" == *.framework/* ]] && continue
  file -b "$file" | grep -q "Mach-O" || continue
  [[ "$file" == "$app/Contents/MacOS/$name" ]] && continue
  sign "$file"
done < <(find "$app/Contents" -depth -type f -print0)

while IFS= read -r -d '' framework; do
  sign "$framework"
done < <(find "$app/Contents" -depth -type d -name "*.framework" -print0)

sign --entitlements "$entitlements" "$app"
codesign --verify --deep --strict --verbose=2 "$app"

# waits for the notary service and stops with its log when it turns the upload down
notarize() {
  local file="$1" result status id
  # notarytool's upload now and then recurses deep enough to overflow its stack on macOS 27 and dies with a bus
  # error, the same upload goes through when tried again
  local tries=0
  until result="$(xcrun notarytool submit "$file" --keychain-profile "$profile" --no-progress --wait \
                    --output-format json)"; do
    tries=$((tries + 1))
    [[ $tries -lt 3 ]] || fail "notarytool kept failing on $(basename "$file")"
    echo "notarytool failed, trying again"
  done
  status="$(plutil -extract status raw -o - - <<< "$result")"
  id="$(plutil -extract id raw -o - - <<< "$result")"
  if [[ "$status" != "Accepted" ]]; then
    xcrun notarytool log "$id" --keychain-profile "$profile" >&2 || true
    fail "notarization of $(basename "$file") came back $status"
  fi
}

echo "notarizing $name.app"
zip="$out/$name-notarize.zip"
ditto -c -k --keepParent "$app" "$zip"
notarize "$zip"
rm -f "$zip"
xcrun stapler staple "$app"

echo "building the dmg"
dmg="$out/$name-$version.dmg"
stage="$work/stage"
mkdir -p "$stage"
ditto "$app" "$stage/$name.app"
ln -s /Applications "$stage/Applications"
rm -f "$dmg"
hdiutil create -volname "$name $version" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg" >/dev/null
codesign --force --timestamp --sign "$identity" "$dmg"

echo "notarizing the dmg"
notarize "$dmg"
xcrun stapler staple "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"

echo "done: $dmg"
