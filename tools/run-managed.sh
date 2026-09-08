#!/bin/bash
set -euo pipefail

# Uses an owner's recovered assemblies and a separately supplied Mono runtime.
# Put Mono's current BCL first: the bundled 2009 mscorlib crashes modern Mono.
: "${CONTROLMAC_MONO_ROOT:?Set this to the Mono Versions/6.12.0 directory}"
: "${CONTROLMAC_RECOVERED:?Set this to the recovery output directory}"
controlmac_source_root=$(cd "$(dirname "$0")/.." && pwd)
controlmac_entry=${1:-}
case "$controlmac_entry" in
  BrokerProbe|ImportPreflight|ImportDraftProbe|ImportOne|BatchImportTool|LibraryTool|PlaybackTool|AlbumInspect|ExportProbe|ExportTool|FlacMetadataTests) ;;
  *) echo 'Choose BrokerProbe, ImportPreflight, ImportDraftProbe, ImportOne, BatchImportTool, LibraryTool, PlaybackTool, AlbumInspect, ExportProbe, ExportTool or FlacMetadataTests' >&2; exit 2 ;;
esac
shift
controlmac_runtime="$CONTROLMAC_MONO_ROOT/bin/mono-sgen64"
controlmac_bcl="$CONTROLMAC_MONO_ROOT/lib/mono/4.5"
controlmac_assemblies="$CONTROLMAC_RECOVERED/managed/ControlMac"
test -x "$controlmac_runtime"
test -f "$controlmac_bcl/mcs.exe"
mkdir -p "$controlmac_source_root/build/managed"
export MONO_PATH="$controlmac_bcl:$controlmac_assemblies"
controlmac_references=()
for controlmac_name in SooloosApp SooloosBase Messaging SooloosMessages ClientBase; do
  test -f "$controlmac_assemblies/$controlmac_name.dll"
  controlmac_references+=("-r:$controlmac_assemblies/$controlmac_name.dll")
done
"$controlmac_runtime" "$controlmac_bcl/mcs.exe" \
  "-main:$controlmac_entry" "-out:$controlmac_source_root/build/managed/$controlmac_entry.exe" \
  "${controlmac_references[@]}" \
  "$controlmac_source_root/tools/BrokerProbe.cs" \
  "$controlmac_source_root/tools/ImportPreflight.cs" \
  "$controlmac_source_root/tools/ImportDraftProbe.cs" \
  "$controlmac_source_root/tools/ImportOne.cs" \
  "$controlmac_source_root/tools/ImportVerification.cs" \
  "$controlmac_source_root/tools/BatchImportTool.cs" \
  "$controlmac_source_root/tools/LibraryTool.cs" \
  "$controlmac_source_root/tools/PlaybackTool.cs" \
  "$controlmac_source_root/tools/AlbumInspect.cs" \
  "$controlmac_source_root/tools/ExportProbe.cs" \
  "$controlmac_source_root/tools/ExportTool.cs" \
  "$controlmac_source_root/tests/FlacMetadataTests.cs"
if [[ ${CONTROLMAC_BUILD_ONLY:-0} != 1 ]]; then
  exec "$controlmac_runtime" "$controlmac_source_root/build/managed/$controlmac_entry.exe" "$@"
fi
