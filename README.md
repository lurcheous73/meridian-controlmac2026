# Meridian Control:Mac 2026

An independent compatibility investigation for owners of Meridian/Sooloos systems.
The aim is to restore Control:Mac on modern Macs, initially as a 64-bit Intel
application under Rosetta on Apple silicon.

**Development status: recovery and static auditing work. This is not yet a
working replacement application, installer, or supported release.**

## What is here

- `tools/recover.py`: recovers embedded managed assemblies from an owner-supplied
  `controlmacupdate.tar`, without executing its installer or applications.
- `tools/audit.py`: checks recovered file hashes and reports native dependencies
  and known Cocoa structure-layout obstacles. Requires `monodis`.
- `tests/`: synthetic, vendor-free fixtures and regression tests.

The tested v474 update contains three i386 executables embedding Mono and .NET
assemblies. Recovery yields 21 assembly copies for ControlMac, 14 for
SooloosHelper, and 19 for SyncCompanion. These are 54 copies, not 54 unique
assemblies. None declares `32BITREQUIRED`, but that does **not** make their native
interfaces 64-bit-compatible.

The supplied Monobjc 2.0.492.0 bindings use `float32` for NSPoint/NSSize fields
and `uint32` for NSRange fields. A runtime swap or code signature cannot by
itself resolve these ABI differences. Native dependencies and the old Mono
thread/GC integration also require investigation.

## Recover your own update

Python 3.9 or newer; the recovery tool has no third-party Python dependencies.
Keep your original update. The output directory must not already exist.

```sh
python3 tools/recover.py /path/to/controlmacupdate.tar --output work/recovered
python3 tools/audit.py work/recovered
python3 -m unittest discover -s tests -v
```

The recovery tool validates input before writing output, rejects unsafe archive
members, and records SHA-256 hashes. It does not run `update.sh`, install launch
agents, change `/Applications`, or contact a Sooloos Core.

## Repository boundaries

This repository contains original recovery, diagnostic, and compatibility
tooling only. Do not commit Meridian binaries, recovered assemblies, decompiled
application code, third-party runtime distributions, private network addresses,
or diagnostic logs containing personal information. Each owner supplies their
own application payload. Files under `work/`, `vendor/`, `downloads/`, `build/`,
`dist/`, and `reports/` are ignored.

This project is not affiliated with or endorsed by Meridian. No rights to
Meridian software or third-party components are granted by this repository.
There is no public binary release at this stage.

## Acceptance criteria

1. Reproducible recovery with hash checks and no modification of the original.
2. A 64-bit managed/native bridge proven against Cocoa scalar/structure ABIs.
3. An isolated application that opens on an Apple-silicon Mac.
4. Core discovery, library browsing, and endpoint playback tested deliberately.
5. Separately validated optional import/ripping/sync/desktop-audio features.
6. Clear installation, rollback, licensing, and support documentation before a
   release is described as usable by other owners.

Passing recovery tests is not evidence that criteria 2–6 have passed.
