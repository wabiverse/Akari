#!/usr/bin/env bash
#
# ios-testflight.sh
#
# bundles Kraken for iOS signed with an Apple Distribution certificate and an App Store provisioning profile, gives
# it a fresh build number, packs it into an ipa and uploads it to App Store Connect for TestFlight
#
# usage: Tools/Distribute/ios-testflight.sh <profile.mobileprovision> <out dir> [identity] [build number]
#
# one time setup:
#   1. Xcode > Settings > Accounts > Manage Certificates > + > Apple Distribution
#   2. developer.apple.com > Profiles > + > App Store Connect, app id foundation.wabi.usd, download it
#   3. App Store Connect > Apps > + for foundation.wabi.usd
#   4. App Store Connect > Users and Access > Integrations > App Store Connect API > new key with App Manager access,
#      put AuthKey_<key id>.p8 in ~/.appstoreconnect/private_keys and export ASC_KEY_ID and ASC_ISSUER_ID
#      (without them the ipa is still made, upload it with the Transporter app)

set -euo pipefail

profile="${1:?usage: ios-testflight.sh <profile.mobileprovision> <out dir> [identity] [build number]}"
out="${2:?usage: ios-testflight.sh <profile.mobileprovision> <out dir> [identity] [build number]}"
search="${3:-Apple Distribution}"
build="${4:-$(date +%Y%m%d%H%M)}"
config="${BUILD_CONFIG:-release}"
name="${APP_NAME:-Kraken}"

fail() { echo "error: $*" >&2; exit 1; }

[[ -f "$profile" ]] || fail "no provisioning profile at $profile, see the setup steps at the top of this script"
identity="$(security find-identity -v -p codesigning | grep "$search" | head -1 | awk '{print $2}')"
[[ -n "$identity" ]] || fail "no '$search' certificate in the keychain, see the setup steps at the top of this script"

mkdir -p "$out"
out="$(cd "$out" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# the profile's own entitlements, so the app claims exactly what App Store Connect expects and never get-task-allow
security cms -D -i "$profile" > "$work/profile.plist"
/usr/libexec/PlistBuddy -x -c "Print :Entitlements" "$work/profile.plist" > "$work/entitlements.plist"
[[ "$(/usr/libexec/PlistBuddy -c "Print :Entitlements:get-task-allow" "$work/profile.plist" 2>/dev/null)" != "true" ]] \
  || fail "$profile is a development profile, TestFlight needs an App Store Connect distribution profile"

export SWIFT_COLLECTIVE_DYNAMIC_LIBRARIES=1 SWIFTUSD_BUILD_FROM_SOURCE=1
swift-bundler bundle -c "$config" -p iOS --codesign --identity "$identity" --provisioning-profile "$profile" \
  --entitlements "$work/entitlements.plist" "$name"

app=".build/bundler/apps/$name/$name.app"
[[ -f "$app/Info.plist" ]] || fail "the bundle did not come out at $app"

# app store connect only takes the icon from a compiled asset catalog
xcrun actool "${ICON:-Branding/Akari.icon}" --compile "$app" --platform iphoneos --minimum-deployment-target 18.0 \
  --app-icon Akari --target-device iphone --target-device ipad --output-partial-info-plist "$work/icon.plist" >/dev/null
for key in CFBundleIcons CFBundleIcons~ipad CFBundleIconName; do
  /usr/libexec/PlistBuddy -c "Delete :$key" "$app/Info.plist" 2>/dev/null || true
done
/usr/libexec/PlistBuddy -c "Merge $work/icon.plist" -c "Add :CFBundleIconName string Akari" "$app/Info.plist"

# swiftpm links without an sdk path in SDKROOT, so every binary records its deployment target as its sdk
sdk="$(xcrun --sdk iphoneos --show-sdk-version)"
while IFS= read -r -d '' file; do
  file -b "$file" | grep -q "Mach-O" || continue
  minos="$(otool -l "$file" | awk '/LC_BUILD_VERSION/ { found = 1 } found && $1 == "minos" { print $2; exit }')"
  [[ -n "$minos" ]] || continue
  xcrun vtool -set-build-version ios "$minos" "$sdk" -replace -output "$work/restamped" "$file" 2>/dev/null
  mv "$work/restamped" "$file"
  chmod +x "$file"
done < <(find "$app" -type f -print0)

# the info.plist keys xcode writes, app store connect reads the sdk and xcode from them
xcode="$(xcodebuild -version | awk 'NR == 1 { print $2 }')"
IFS=. read -r major minor patch <<< "$xcode"
plist=(
  "DTPlatformName string iphoneos"
  "DTPlatformVersion string $sdk"
  "DTPlatformBuild string $(xcrun --sdk iphoneos --show-sdk-build-version)"
  "DTSDKName string iphoneos$sdk"
  "DTSDKBuild string $(xcrun --sdk iphoneos --show-sdk-build-version)"
  "DTXcode string $(printf '%d%d%d' "$major" "${minor:-0}" "${patch:-0}")"
  "DTXcodeBuild string $(xcodebuild -version | awk 'NR == 2 { print $3 }')"
  "DTCompiler string com.apple.compilers.llvm.clang.1_0"
  "BuildMachineOSBuild string $(sw_vers -buildVersion)"
)
for entry in "${plist[@]}"; do
  /usr/libexec/PlistBuddy -c "Delete :${entry%% *}" "$app/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :$entry" "$app/Info.plist"
done
/usr/libexec/PlistBuddy -c "Delete :UIRequiredDeviceCapabilities" "$app/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :UIRequiredDeviceCapabilities array" -c "Add :UIRequiredDeviceCapabilities:0 string arm64" "$app/Info.plist"

for framework in "$app"/Frameworks/*.framework; do
  codesign --force --sign "$identity" "$framework"
done

# every upload needs a build number App Store Connect has not seen, the app is signed again over the new one
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build" "$app/Info.plist"
codesign --force --sign "$identity" --entitlements "$work/entitlements.plist" --generate-entitlement-der "$app"
codesign --verify --deep --strict --verbose=2 "$app"

version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Info.plist")"
ipa="$out/$name-$version-$build.ipa"
mkdir -p "$work/Payload"
ditto "$app" "$work/Payload/$name.app"
rm -f "$ipa"
(cd "$work" && zip -qry "$ipa" Payload)
echo "made $ipa"

if [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]]; then
  xcrun altool --validate-app -f "$ipa" -t ios --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
  xcrun altool --upload-app -f "$ipa" -t ios --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
  echo "uploaded $version ($build), it shows in TestFlight once App Store Connect finishes processing"
else
  echo "ASC_KEY_ID and ASC_ISSUER_ID are not set, upload $ipa with the Transporter app"
fi
