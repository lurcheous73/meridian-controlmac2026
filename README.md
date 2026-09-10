# Meridian ControlMac 2026

An independent modern macOS controller for owners of Meridian/Sooloos systems. ControlMac 2026 restores practical library control on current Macs without relying on the obsolete 32-bit Control:Mac application.

## Downloads

- **Stable:** [ControlMac 2026 v1.0.0 Universal DMG](https://github.com/lurcheous73/meridian-controlmac2026/releases/tag/v1.0.0)
- **Current working development branch:** `feature/equipment-discovery` — ControlMac 2026 v1.02b1

The single Universal 2 application supports Apple silicon (`arm64`) and 64-bit Intel (`x86_64`) Macs. Minimum target: macOS 13. Homebrew is not required for normal use.

## v1.02b1 current working build

v1.02b1 is the current working ControlMac 2026 development build. It keeps the proven Meridian/Sooloos library, import/export, optical-disc and playback functions from earlier builds and adds native equipment/configuration management.

### Proven on real Meridian/Sooloos hardware

- Native Meridian/Sooloos configuration window with live Core and device information
- Universal 2 build for Apple silicon (`arm64`) and 64-bit Intel (`x86_64`)
- About box includes the release version, build number and exact short Git commit for traceability
- Live Meridian IPNP discovery/communication on modern macOS without relying on the obsolete 2009 Mono multicast socket wrapper
- ControlFifteen network configuration read: DHCP, current address, static IP, subnet mask, gateway and DNS
- DHCP/static network editor using Meridian's original C15 `set_dhcp` and `set_static_ip` commands, with IPv4/netmask/subnet validation and a guarded Apply confirmation
- Network write-and-reconnect cycle physically tested on live hardware, including DHCP/static operation and IP/netmask/gateway/DNS changes
- Sooloos registration data read from the live Broker using Meridian's original `user_registration` IPNP query
- Registration editor using Meridian's original `register_user` fields: first name, last name, email, phone, address lines, city, state/county, postcode/ZIP and country
- Registration write and persistence physically tested on live hardware
- Dealer information read/display through the Sooloos broker where the system provides it; dealer editing is intentionally out of scope
- Meridian speaker wake/select-SpeakerLink behaviour physically proven by selecting Meridian source index `2` (`LP/Aux/SLS`); the generic `PowerOn` remote key alone did not wake the speakers
- Multiple playback units/zones can be selected from the Playback Unit control
- Configuration refreshes are serialized so network and registration IPNP transactions do not compete for the same multicast transport
- Firmware update and downgrade path physically tested on live Meridian hardware

### Firmware management

ControlMac can inspect the update catalogue already stored on a Sooloos Core and report available system/device versions, including `live`, `live.old`, `staging` and `staging.old` trees when present. On the development reference C15, genuine Meridian upgrade and downgrade packages were found and used successfully.

Firmware update/downgrade is considered a tested advanced maintenance function. It remains inherently risky: users should only use known-correct Meridian firmware for the target device, keep the Core/device on a UPS, and never interrupt power during an update or downgrade. Recovery and manual maintenance may require SSH access.

### Still in development after v1.02b1

- Fully proven Meridian Surround Core multichannel playback control
- True DVD-Audio authoring (`AUDIO_TS`) and burnable ISO from a Sooloos album
- One-click Pure Audio Blu-ray ISO authoring from a Sooloos album
- True DVD-Audio read/import path
- SACD/DSD support
- Physical validation on a real Intel Mac remains pending


## v1.0.0 stable

Working features include fast Sooloos library cache/browsing, metadata and artwork editing/revalidation, guarded deletion, zone playback/queue/volume, verified import, Audio-CD ripping, native-resolution FLAC/ALAC export, CD-A BIN/CUE creation, whole-library FLAC backup, NetMD SP/LP2/LP4 read/write and safe MiniDisc erase/release. Experimental Hi-MD support is also included.

The v1.0.0 release was repackaged on 9 September 2026 to restore the required Mono 6.12 `4.5/machine.config` in both architecture slices. This fixes fresh-install Sooloos network/import failures reporting `The URI prefix is not recognized.`

## v1.01a development alpha

v1.01a added the first optical Hi-Res work:

- Blu-ray detection and MakeMKV-backed audio-stream scanning
- Protected commercial Blu-ray access physically proven with MakeMKV/LibreDrive
- Audio-only presentation: video streams are ignored by ControlMac
- Lossless stream ranking by layout, sample rate, bit depth and codec
- Default stereo policy prefers native LPCM when equivalent lossless streams exist
- Best distinct multichannel layouts retained separately for local archive (quad/4.0, 5.1, 7.1 and future layouts)
- 24-bit/96 kHz LPCM stereo Blu-ray extraction physically proven and imported to Sooloos
- Sample-accurate album splitting verified by decoded-PCM SHA-256 reconstruction
- Post-import artwork lookup keeps the custom edition title while resolving art from the canonical release

Physical reference tests include Steven Wilson — *The Raven That Refused to Sing (and Other Stories)* and Queen — *A Night at the Opera* Pure Audio Blu-ray.

## v1.02a development alpha

v1.02a extends the optical/image layer while keeping all previous Sooloos functionality:

- `Add ISO / BIN…` opens data-disc images read-only and feeds DVD/Blu-ray images through the same optical scanner as physical media
- DVD `VIDEO_TS` image/disc scanning added through the MakeMKV title/audio parser
- `Backup Disc → ISO…` added to Import / Export
- Exact raw optical-disc ISO backup copies the full optical block device and verifies byte count
- Finished backups are remounted read-only and checked for expected `BDMV`, `VIDEO_TS` or `AUDIO_TS` structure
- Protected commercial Blu-ray offers a playable backup path using MakeMKV full-disc `backup --decrypt`, followed by UDF 2.50 ISO creation
- Native macOS UDF 2.50 image creation is implemented without a Homebrew runtime dependency
- Backup progress, cancellation and partial-image cleanup are implemented
- `.BIN` data-disc mounting has a raw-image fallback; CD-A BIN/CUE remains its separate audio-CD image format
- Blu-ray stereo/multichannel selection policy prefers the best lossless stream for each distinct channel layout and does not downmix, normalize or resample

A Sooloos → 24/96 LPCM → BDMV → Blu-ray ISO authoring recipe has also been lab-proven with decoded-PCM round-trip equality, but one-click Pure Audio Blu-ray authoring is not yet exposed as a finished v1.02a UI feature.

### Superseded by v1.02b1

The current development status and remaining work are listed in the v1.02b1 section above.

## Dependencies and packaging

The release app bundles the open-source runtime components it needs, including architecture-specific Node, FFmpeg/FFprobe, FLAC/metaflac, ATRAC encoding and Mono. MakeMKV is an optional external provider for protected commercial Blu-ray access; it is not bundled by ControlMac.

This public repository intentionally does **not** contain Meridian/Sooloos proprietary binaries, recovered assemblies, private network details, API credentials, build output or user media. Owners must supply their own Meridian software payload where required.

Generated apps, DMGs and recovered binaries are ignored by Git. This is an independent community project and is not affiliated with or endorsed by Meridian Audio.
