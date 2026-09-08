#!/usr/bin/env python3
"""Statically audit recovered Control:Mac files; never launch the application."""

import argparse
import hashlib
import json
import pathlib
import re
import shutil
import subprocess

LAYOUTS = {
    "Monobjc.Cocoa.NSPoint": {"x": "float64", "y": "float64"},
    "Monobjc.Cocoa.NSSize": {"width": "float64", "height": "float64"},
    "Monobjc.Cocoa.NSRange": {"location": "unsigned int64", "length": "unsigned int64"},
}


def parse_fields(text):
    result, current = {}, None
    for line in text.splitlines():
        if line.startswith("########## "):
            current = line[len("########## "):].strip()
            result[current] = {}
            continue
        match = re.match(r"\d+: (.*?) ([^ :]+): (.*)", line)
        if current and match and "static" not in match[3].split():
            result[current][match[2]] = match[1]
    return result


def layout_findings(fields):
    findings = []
    for typename, expected_fields in LAYOUTS.items():
        observed = fields.get(typename, {})
        for name, expected in expected_fields.items():
            actual = observed.get(name)
            if actual != expected:
                findings.append({"type": typename, "field": name, "observed": actual,
                                 "expected_for_64_bit_macos": expected,
                                 "severity": "blocker" if actual else "unknown"})
    return findings


def disassemble(program, flag, path):
    result = subprocess.run([program, flag, str(path)], capture_output=True, text=True,
                            timeout=60, check=False)
    if result.returncode != 0:
        raise RuntimeError("monodis failed for " + path.name + ": " + result.stderr[:500])
    return result.stdout


def audit(root, program):
    root = pathlib.Path(root)
    manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
    managed_root = root / "managed" / "ControlMac"
    if manifest.get("schema_version") != 1:
        raise ValueError("unsupported recovery manifest")
    assemblies = manifest["managed"]["ControlMac"]
    native_modules = {}
    for name, info in assemblies.items():
        if not re.fullmatch(r"[A-Za-z0-9_.+-]+\.(dll|exe)", name):
            raise ValueError("unsafe manifest assembly name")
        path = managed_root / name
        if path.is_symlink() or hashlib.sha256(path.read_bytes()).hexdigest() != info["sha256"]:
            raise ValueError("recovered assembly integrity mismatch: " + name)
        lines = disassemble(program, "--moduleref", path).splitlines()
        native_modules[name] = [line.split(": ", 1)[1] for line in lines if re.match(r"\d+: ", line)]
    fields = parse_fields(disassemble(program, "--fields", managed_root / "Monobjc.Cocoa.dll"))
    mono_modules = native_modules.get("Monobjc.dll", [])
    return {
        "status": "static-audit-not-runtime-validation",
        "version": manifest["version"],
        "source_sha256": manifest["source_sha256"],
        "managed_assembly_counts": {app: len(items) for app, items in manifest["managed"].items()},
        "layout_blockers": layout_findings(fields),
        "native_modules": native_modules,
        "legacy_monobjc_path_imports": [x for x in mono_modules if x.startswith("@executable_path/")],
        "i386_only_native_components": sorted(name for name, slices in manifest["native"].items()
                                              if all(item["architecture"] == "i386" for item in slices)),
        "notes": [
            "IL-only without 32BITREQUIRED is not a promise of 64-bit safety.",
            "ModuleRef imports can include unused Windows-only platform branches.",
            "Layout findings require ABI review, not blind global float/int replacement.",
            "A 64-bit native bridge does not fix 32-bit managed Cocoa structures.",
            "Legacy Mono GC/thread hooks and framework paths need macOS runtime testing.",
        ],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("recovery", type=pathlib.Path)
    args = parser.parse_args()
    program = shutil.which("monodis")
    if not program:
        parser.exit(1, "monodis is required for static metadata inspection; nothing was changed.\n")
    try:
        result = audit(args.recovery, program)
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.TimeoutExpired) as exc:
        parser.exit(1, "Audit stopped: " + str(exc) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
