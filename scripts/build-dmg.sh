#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
artifact="$PWD/EasyRecord-$version.dmg"
scratch=$(mktemp -d "${TMPDIR:-/tmp/}easyrecord-dmg.XXXXXX")
mount_dir="$scratch/verify"
mounted=0
cleanup() {
  if (( mounted )); then
    hdiutil detach "$mount_dir" >/dev/null || return
  fi
  rm -rf "$scratch"
}
trap cleanup EXIT

xcodebuild -project EasyRecord.xcodeproj -scheme EasyRecord \
  -configuration Release -derivedDataPath "$scratch/DerivedData" \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=NO build > "$scratch/build.log" 2>&1 || {
    cat "$scratch/build.log"
    exit 1
  }

mkdir -p "$scratch/image" "$mount_dir"
ditto --norsrc --noextattr "$scratch/DerivedData/Build/Products/Release/EasyRecord.app" "$scratch/image/EasyRecord.app"
xattr -cr "$scratch/image/EasyRecord.app"
# A Developer ID can be supplied for distribution; use local signing otherwise.
codesign --force --sign "${SIGNING_IDENTITY:--}" --entitlements Resources/EasyRecord.entitlements "$scratch/image/EasyRecord.app"
codesign --verify --strict --verbose=2 "$scratch/image/EasyRecord.app"
ln -s /Applications "$scratch/image/Applications"

hdiutil create -volname EasyRecord -fs HFS+ -srcfolder "$scratch/image" \
  -format UDZO -imagekey zlib-level=9 -ov "$scratch/EasyRecord.dmg"
hdiutil verify "$scratch/EasyRecord.dmg"
hdiutil attach -readonly -nobrowse -mountpoint "$mount_dir" "$scratch/EasyRecord.dmg" > "$scratch/mount.log"
mounted=1
codesign --verify --strict --verbose=2 "$mount_dir/EasyRecord.app"
test "$(readlink "$mount_dir/Applications")" = /Applications
test -x "$mount_dir/EasyRecord.app/Contents/MacOS/EasyRecord"
cmp "$scratch/image/EasyRecord.app/Contents/MacOS/EasyRecord" "$mount_dir/EasyRecord.app/Contents/MacOS/EasyRecord"
echo "Architectures: $(lipo -archs "$mount_dir/EasyRecord.app/Contents/MacOS/EasyRecord")"
hdiutil detach "$mount_dir"
mounted=0

# Keep the last verified disk image until its replacement is ready.
cp "$scratch/EasyRecord.dmg" "$artifact.new"
mv -f "$artifact.new" "$artifact"
echo "Verified DMG: $artifact"
