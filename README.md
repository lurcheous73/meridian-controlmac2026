# Meridian ControlMac 2026

An independent modern macOS controller for owners of Meridian/Sooloos systems.
ControlMac 2026 is intended to restore day-to-day library control on current Macs
without relying on the obsolete 32-bit Control:Mac application.

## v1.0.0 status

The v1 application is built as **Universal 2**:

- Apple silicon: native `arm64`
- Intel Mac: native 64-bit `x86_64`
- Minimum target: macOS 13
- No 32-bit `i386` application code

Apple-silicon operation has been tested on real hardware. The x86_64 application,
runtime and media-tool slices have been smoke-tested under Rosetta; real Intel-Mac
hardware testing is in progress.
## Working v1 features

- Fast local library cache and browsing
- Metadata/artwork lookup, comparison and revalidation
- Album delete with confirmation and backend verification
- Zone playback, queue and volume control
- Folder/file import with verification and progress
- Audio-CD TOC lookup and 16-bit/44.1 kHz FLAC ripping
- Sooloos export to FLAC and ALAC
- Audio-CD image export as BIN/CUE
- Sooloos library backup with skip/report handling
- NetMD MiniDisc read/rip/write, including SP, LP2 and LP4
- Safe MiniDisc wipe and cooperative cancel/release
- Experimental Hi-MD support via the modern open-source NetMD/Hi-MD stack
## Dependencies and packaging

The release app bundles the open-source runtime components it needs, including
architecture-specific Node, FFmpeg/FFprobe, FLAC/metaflac, ATRAC encoding and Mono.
Homebrew is a development convenience only and is not a runtime requirement.

This public repository intentionally does **not** contain Meridian/Sooloos proprietary
binaries, recovered assemblies, private network details, API credentials, build output,
or user media. Owners must supply their own Meridian software payload where required.

The local developer build script expects an owner-supplied recovered payload and a
prepared per-architecture runtime tree. Generated apps, DMGs and recovered binaries are
ignored by Git.
