#!/usr/bin/env bash
# Build an actual iPhoneOS app and package it for re-signing by AltStore Classic.
set -euo pipefail

project_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
bundle_identifier="${BUNDLE_IDENTIFIER:-dev.konomitv.wrapper}"
derived_data="${DERIVED_DATA_PATH:-$project_root/build/Device}"
output_directory="${OUTPUT_DIRECTORY:-$project_root/dist}"

if [[ "$(uname -s)" != "Darwin" ]] || ! command -v xcodebuild >/dev/null 2>&1; then
    echo "A Mac with full Xcode is required to build an iPhoneOS IPA. No IPA was generated." >&2
    exit 1
fi
if [[ ! "$bundle_identifier" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then
    echo "BUNDLE_IDENTIFIER must be a reverse-DNS identifier, such as dev.konomitv.wrapper." >&2
    exit 1
fi
python3 "$project_root/scripts/validate-project.py"

xcodebuild \
    -project "$project_root/KonomiTV.xcodeproj" \
    -scheme KonomiTV \
    -configuration Release \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$derived_data" \
    "BUNDLE_IDENTIFIER=$bundle_identifier" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY= \
    clean build

app="$derived_data/Build/Products/Release-iphoneos/KonomiTV.app"
if [[ ! -d "$app" ]]; then
    echo "Xcode did not produce the expected iPhoneOS app: $app" >&2
    exit 1
fi
python3 - "$app" "$bundle_identifier" <<'PY'
import pathlib
import plistlib
import sys

app = pathlib.Path(sys.argv[1])
with (app / "Info.plist").open("rb") as stream:
    info = plistlib.load(stream)
assert info["CFBundleIdentifier"] == sys.argv[2], "Unexpected bundle identifier"
assert info["CFBundlePackageType"] == "APPL", "Not an application bundle"
assert "iPhoneOS" in info["CFBundleSupportedPlatforms"], "Not an iPhoneOS build"
assert info.get("CFBundleExecutable") == "KonomiTV", "Unexpected executable"
assert (app / info["CFBundleExecutable"]).is_file(), "Native executable missing"
assert (app / "MediaBridge.js").is_file(), "Media bridge resource missing"
assert (app / "PrivacyInfo.xcprivacy").is_file(), "Privacy manifest missing"
assert not (app / "embedded.mobileprovision").exists(), "Build unexpectedly provisioned"
PY
executable="$app/KonomiTV"
if ! file "$executable" | /usr/bin/grep -q 'Mach-O'; then
    echo "The app executable is not a native Mach-O binary." >&2
    exit 1
fi
architectures="$(xcrun lipo -archs "$executable")"
if [[ " $architectures " != *" arm64 "* ]]; then
    echo "The app does not contain the arm64 device architecture: $architectures" >&2
    exit 1
fi
if ! xcrun vtool -show-build "$executable" | /usr/bin/grep -Eq 'platform[[:space:]]+IOS$'; then
    echo "The binary is not built for physical iOS devices." >&2
    exit 1
fi

mkdir -p "$output_directory"
stage="$(mktemp -d "$derived_data/ipa-stage.XXXXXX")"
trap 'rm -rf -- "$stage"' EXIT
mkdir -p "$stage/Payload"
ditto "$app" "$stage/Payload/KonomiTV.app"
ditto -c -k --keepParent "$stage/Payload" "$stage/KonomiTV.ipa"
python3 - "$stage/KonomiTV.ipa" <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    assert archive.testzip() is None, "IPA ZIP integrity check failed"
    assert "Payload/KonomiTV.app/KonomiTV" in archive.namelist(), "IPA executable missing"
    assert "Payload/KonomiTV.app/Info.plist" in archive.namelist(), "IPA Info.plist missing"
PY
mv -f "$stage/KonomiTV.ipa" "$output_directory/KonomiTV.ipa"
(cd "$output_directory" && shasum -a 256 KonomiTV.ipa > KonomiTV.ipa.sha256)
echo "Created $output_directory/KonomiTV.ipa ($architectures, unsigned for AltStore Classic)."
