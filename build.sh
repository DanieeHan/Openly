#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
destination="${1:-dist/Openly.app}"
build_arch="${OPENLY_ARCH:-$(uname -m)}"
staging_root=$(mktemp -d /tmp/openly-build.XXXXXX)
trap 'rm -rf "$staging_root"' EXIT
staging="$staging_root/Openly.app"
mkdir -p "$staging/Contents/MacOS" "$staging/Contents/Resources"
swiftc -swift-version 5 -O -target "${build_arch}-apple-macosx13.0" Sources/Model.swift Sources/Openly.swift -o "$staging/Contents/MacOS/Openly"
cp Resources/Info.plist "$staging/Contents/Info.plist"
cp LICENSE "$staging/Contents/Resources/LICENSE"
if [[ -f Resources/AppIcon.icns ]]; then
    cp Resources/AppIcon.icns "$staging/Contents/Resources/AppIcon.icns"
fi
xattr -cr "$staging"
codesign --force --deep --sign - "$staging"
codesign --verify --deep --strict "$staging"
mkdir -p "${destination:h}"
ditto -c -k --keepParent --norsrc "$staging" "${destination:r}.zip"
ditto --norsrc "$staging" "$destination"
print "Built: $destination"
