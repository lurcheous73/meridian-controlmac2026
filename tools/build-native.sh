#!/bin/bash
set -euo pipefail

if [[ "$(uname -s)" != Darwin ]]; then
    echo 'This build requires macOS and the Apple command-line developer tools.' >&2
    exit 1
fi
project_root=$(cd "$(dirname "$0")/.." && pwd)
output_dir=${1:-"$project_root/build/ControlMac-2026.app"}
if [[ -e "$output_dir" || -L "$output_dir" ]]; then
    echo 'Output already exists; choose a new app path. Nothing was overwritten.' >&2
    exit 1
fi
mkdir -p "$output_dir/Contents/MacOS"
cp "$project_root/native/Info.plist" "$output_dir/Contents/Info.plist"
/usr/bin/xcrun swiftc -swift-version 5 -target arm64-apple-macos13.0 \
    -framework AppKit -framework WebKit \
    "$project_root/native/ControlMac2026.swift" \
    -o "$output_dir/Contents/MacOS/ControlMac2026"
/usr/bin/codesign --sign - "$output_dir"
"$output_dir/Contents/MacOS/ControlMac2026" --self-test
/usr/bin/codesign --verify --strict "$output_dir"
echo "Built experimental native browser client: $output_dir"
echo 'Not a complete Control:Mac replacement. No native import, sync, or Mac audio.'
