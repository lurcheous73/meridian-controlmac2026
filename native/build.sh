#!/bin/bash
set -euo pipefail
: "${CONTROLMAC_MONO_ROOT:?Set the local Mono runtime root}"
: "${CONTROLMAC_RECOVERED:?Set the local recovered payload root}"
repo=$(cd "$(dirname "$0")/.." && pwd)
out=${1:?Pass a new .app output directory}
runtime="$repo/build/runtime-v1"
[[ ! -e "$out" ]] || { echo 'Output already exists; choose a new path.' >&2; exit 1; }
for arch in arm64 x86_64; do
  for tool in node ffmpeg ffprobe flac metaflac atracdenc; do
    [[ -x "$runtime/$arch/bin/$tool" ]] || { echo "Missing $arch runtime tool: $tool" >&2; exit 1; }
  done
  [[ -x "$runtime/$arch/mono/bin/mono-sgen64" ]] || { echo "Missing $arch Mono runtime" >&2; exit 1; }
  [[ -f "$runtime/$arch/mono/etc/mono/config" ]] || { echo "Missing $arch Mono config" >&2; exit 1; }
  [[ -f "$runtime/$arch/mono/etc/mono/4.5/machine.config" ]] || { echo "Missing $arch Mono 4.5 machine.config" >&2; exit 1; }
done
for tool in ImportOne BatchImportTool LibraryTool PlaybackTool ExportTool; do
  CONTROLMAC_BUILD_ONLY=1 bash "$repo/tools/run-managed.sh" "$tool"
done
swift_sources=(
  "$repo/native/RuntimeSupport.swift"
  "$repo/native/NetworkConfiguration.swift"
  "$repo/native/BluRaySupport.swift"
  "$repo/native/DiscImageSupport.swift"
  "$repo/native/ImportedArtwork.swift"
  "$repo/native/ProviderSettings.swift"
  "$repo/native/LookupService.swift"
  "$repo/native/ExternalProviders.swift"
  "$repo/native/BandcampService.swift"
  "$repo/native/SettingsController.swift"
  "$repo/native/LookupGrid.swift"
  "$repo/native/RevalidationCompare.swift"
  "$repo/native/PlaybackUI.swift"
  "$repo/native/ImportExportController.swift"
  "$repo/native/BatchImportUI.swift"
  "$repo/native/ControlMacNative.swift"
)
mkdir -p "$out/Contents/MacOS" "$out/Contents/Resources"
arm_bin="$repo/build/ControlMac2026-arm64"
intel_bin="$repo/build/ControlMac2026-x86_64"
rm -f "$arm_bin" "$intel_bin"
xcrun swiftc -swift-version 5 -target arm64-apple-macos13.0 \
  -framework AppKit -framework UniformTypeIdentifiers -framework Security \
  "${swift_sources[@]}" -o "$arm_bin"
xcrun swiftc -swift-version 5 -target x86_64-apple-macos13.0 \
  -framework AppKit -framework UniformTypeIdentifiers -framework Security \
  "${swift_sources[@]}" -o "$intel_bin"
lipo -create "$arm_bin" "$intel_bin" -output "$out/Contents/MacOS/ControlMac2026"
cp "$repo/native/Info.plist" "$out/Contents/Info.plist"
icon="$repo/native/M2026.icns"
if [[ ! -f "$icon" ]]; then
  echo "Generating app icon from source..."
  ( cd "$repo/native" && xcrun swift make-icon.swift )
  mkdir -p "$repo/native/M2026.iconset"
  sips -z 16 16 M2026-1024.png --out "$repo/native/M2026.iconset/icon_16x16.png" >/dev/null
  sips -z 32 32 M2026-1024.png --out "$repo/native/M2026.iconset/icon_16x16@2x.png" >/dev/null
  sips -z 32 32 M2026-1024.png --out "$repo/native/M2026.iconset/icon_32x32.png" >/dev/null
  sips -z 64 64 M2026-1024.png --out "$repo/native/M2026.iconset/icon_32x32@2x.png" >/dev/null
  sips -z 128 128 M2026-1024.png --out "$repo/native/M2026.iconset/icon_128x128.png" >/dev/null
  sips -z 256 256 M2026-1024.png --out "$repo/native/M2026.iconset/icon_128x128@2x.png" >/dev/null
  sips -z 256 256 M2026-1024.png --out "$repo/native/M2026.iconset/icon_256x256.png" >/dev/null
  sips -z 512 512 M2026-1024.png --out "$repo/native/M2026.iconset/icon_256x256@2x.png" >/dev/null
  sips -z 512 512 M2026-1024.png --out "$repo/native/M2026.iconset/icon_512x512.png" >/dev/null
  cp M2026-1024.png "$repo/native/M2026.iconset/icon_512x512@2x.png"
  iconutil -c icns "$repo/native/M2026.iconset" -o "$icon"
fi
cp "$icon" "$out/Contents/Resources/M2026.icns"
for tool in ImportOne BatchImportTool LibraryTool PlaybackTool ExportTool; do
  cp "$repo/build/managed/$tool.exe" "$out/Contents/Resources/$tool.exe"
done
cp -R "$repo/tools/netmd" "$out/Contents/Resources/netmd"
mkdir -p "$out/Contents/Resources/runtime"
cp -R "$runtime/arm64" "$out/Contents/Resources/runtime/arm64"
cp -R "$runtime/x86_64" "$out/Contents/Resources/runtime/x86_64"
cp -R "$CONTROLMAC_RECOVERED/managed/ControlMac" "$out/Contents/Resources/managed"
rm -f "$out/Contents/Resources/Backend.plist"
chmod +x "$out/Contents/MacOS/ControlMac2026"
find "$out/Contents/Resources/runtime" -type f \( -name node -o -name ffmpeg -o -name ffprobe -o -name flac -o -name metaflac -o -name atracdenc -o -name mono-sgen64 \) -exec chmod +x {} +
xattr -cr "$out" 2>/dev/null || true
codesign --force --deep --sign - "$out"
codesign --verify --deep --strict "$out"
file "$out/Contents/MacOS/ControlMac2026"
lipo -archs "$out/Contents/MacOS/ControlMac2026"
rm -f "$arm_bin" "$intel_bin"
printf 'Built Universal 2 %s\n' "$out"
