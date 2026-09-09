# Meridian ControlMac 2026

An independent modern macOS controller for owners of Meridian/Sooloos systems.
ControlMac 2026 restores practical library control on current Macs without relying on the obsolete 32-bit Control:Mac application.

## Downloads

- **Stable:** [ControlMac 2026 v1.0.0 Universal DMG](https://github.com/lurcheous73/meridian-controlmac2026/releases/tag/v1.0.0)
- **Development alpha:** [ControlMac 2026 v1.01a](https://github.com/lurcheous73/meridian-controlmac2026/releases/tag/v1.01a)

The single Universal 2 application supports Apple silicon (`arm64`) and 64-bit Intel (`x86_64`) Macs. Minimum target: macOS 13. Homebrew is not required for normal use.

## v1.0.0 stable

Working features include:

- Fast Sooloos library cache and browsing
- Metadata/artwork lookup, comparison and revalidation
- Album/track editing with guarded deletion
- Zone playback, queue and volume control
- Verified folder/file import with progress and cancellation
- Audio-CD TOC lookup and 16-bit/44.1 kHz FLAC ripping
- Native-resolution FLAC and ALAC export
- CD-A BIN/CUE disc-image export
- Whole-library Sooloos FLAC backup with skip/report handling
- NetMD MiniDisc read/rip/write: SP, LP2 and LP4
- Safe MiniDisc wipe and cooperative USB release
- Experimental Hi-MD support
The v1.0.0 release was repackaged on 9 September 2026 to restore the required Mono 6.12 `4.5/machine.config` in both architecture slices. This fixes fresh-install Sooloos network/import failures reporting `The URI prefix is not recognized.`

## v1.01a development alpha

v1.01a adds the first optical Hi-Res work while keeping the proven v1.0.0 library functions:

- Blu-ray disc detection and MakeMKV-backed audio-stream scanning
- Protected commercial Blu-ray access physically proven with MakeMKV/LibreDrive
- Audio-only presentation: video streams are ignored by ControlMac
- Lossless stream ranking by layout, sample rate, bit depth and codec
- Default stereo policy prefers native LPCM when equivalent lossless streams exist
- Best distinct multichannel layouts are retained separately for local archive: quad/4.0, 5.1, 7.1 and future layouts
- 24-bit/96 kHz LPCM stereo Blu-ray extraction physically proven and imported to Sooloos
- Sample-accurate album splitting verified by decoded-PCM SHA-256 reconstruction
- Blu-ray duplicate audio PIDs can be identified by decoded PCM rather than labels alone
- Post-import artwork lookup now keeps the custom edition title while resolving art from the canonical release
- Blu-ray editions prefer artwork from a matching Blu-ray release where available
- Build now fails if either architecture is missing Mono `config` or `4.5/machine.config`

Physical reference tests include Steven Wilson — *The Raven That Refused to Sing (and Other Stories)* and Queen — *A Night at the Opera* Pure Audio Blu-ray. The Queen disc correctly ranks LPCM 24/96 stereo for Sooloos and LPCM 24/96 5.1 for local archive.
### Still in development after v1.01a

These are planned/in-progress and are not claimed as finished one-click features in this alpha:

- Automatic Blu-ray ripping directly from the ControlMac UI
- True DVD-Audio authoring (`AUDIO_TS`) and burnable ISO
- Pure Audio Blu-ray/BDMV authoring and ISO creation
- Full DVD/Blu-ray disc backup workflow
- True DVD-Audio read/import path
- SACD/DSD support

## Dependencies and packaging

The release app bundles the open-source runtime components it needs, including architecture-specific Node, FFmpeg/FFprobe, FLAC/metaflac, ATRAC encoding and Mono. MakeMKV is an optional external provider for protected commercial Blu-ray access; it is not bundled by ControlMac.

This public repository intentionally does **not** contain Meridian/Sooloos proprietary binaries, recovered assemblies, private network details, API credentials, build output, or user media. Owners must supply their own Meridian software payload where required.

The local developer build script expects an owner-supplied recovered payload and a prepared per-architecture runtime tree. Generated apps, DMGs and recovered binaries are ignored by Git.

This is an independent community project and is not affiliated with or endorsed by Meridian Audio.
