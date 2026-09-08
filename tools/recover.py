#!/usr/bin/env python3
"""Recover managed assemblies from an owner-supplied Control:Mac update.

Static parsing only. Does not execute the updater, native code, or managed code.
Python standard library only. Output must be a new, private directory.
"""

import argparse
import hashlib
import json
import pathlib
import re
import struct
import tarfile
import zlib

MAX_FILE = 128 * 1024 * 1024
MAX_TOTAL = 512 * 1024 * 1024
APPS = ("ControlMac", "SooloosHelper", "SyncCompanion")
CPU_NAMES = {7: "i386", 0x1000007: "x86_64", 12: "arm", 0x100000C: "arm64",
             18: "ppc", 0x1000012: "ppc64"}


class FormatError(ValueError):
    pass


def block(data, offset, size):
    if offset < 0 or size < 0 or offset + size > len(data):
        raise FormatError("truncated or out-of-range binary structure")
    return data[offset:offset + size]


def unpack(fmt, data, offset):
    return struct.unpack(fmt, block(data, offset, struct.calcsize(fmt)))


def cstring(data, offset=0):
    if not 0 <= offset < len(data):
        raise FormatError("string offset out of range")
    end = data.find(b"\0", offset)
    if end < 0:
        raise FormatError("unterminated string")
    return data[offset:end].decode("utf-8", "strict")


def macho_slices(data):
    magic = block(data, 0, 4)
    if magic in (b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"):
        endian = ">" if magic == b"\xca\xfe\xba\xbe" else "<"
        count, = unpack(endian + "I", data, 4)
        if not 1 <= count <= 16:
            raise FormatError("invalid fat architecture count")
        result = []
        for i in range(count):
            cpu, _, offset, size, _ = unpack(endian + "IIIII", data, 8 + 20 * i)
            part = block(data, offset, size)
            if macho_info(part)["cpu_type"] != cpu:
                raise FormatError("fat header and slice CPU disagree")
            result.append(part)
        return result
    return [data]


def macho_info(data):
    formats = {b"\xce\xfa\xed\xfe": ("<", False), b"\xcf\xfa\xed\xfe": ("<", True),
               b"\xfe\xed\xfa\xce": (">", False), b"\xfe\xed\xfa\xcf": (">", True)}
    try:
        endian, wide = formats[block(data, 0, 4)]
    except KeyError as exc:
        raise FormatError("not a supported Mach-O binary") from exc
    cpu, _, kind, count, command_bytes, _ = unpack(endian + "IIIIII", data, 4)
    pos = 32 if wide else 28
    commands_end = pos + command_bytes
    block(data, pos, command_bytes)
    if count > 4096:
        raise FormatError("excessive load command count")
    segments, libraries, symbols = [], [], {}
    symtab = None
    for _ in range(count):
        cmd, size = unpack(endian + "II", data, pos)
        if size < 8 or pos + size > commands_end:
            raise FormatError("invalid load command")
        command = block(data, pos, size)
        if cmd in (1, 0x19):
            vm, vms, file_offset, file_size = unpack(endian + ("QQQQ" if cmd == 0x19 else "IIII"), command, 24)
            block(data, file_offset, file_size)
            segments.append((vm, vms, file_offset, file_size))
        if cmd == 2:
            symtab = unpack(endian + "IIII", command, 8)
        if cmd in (0xC, 0x80000018, 0x8000001F, 0x80000023):
            name_offset, = unpack(endian + "I", command, 8)
            libraries.append(cstring(command, name_offset))
        pos += size
    if pos != commands_end:
        raise FormatError("load command size mismatch")
    if symtab:
        offset, count, strings_offset, strings_size = symtab
        strings = block(data, strings_offset, strings_size)
        width = 16 if wide else 12
        block(data, offset, count * width)
        for i in range(count):
            index, typ, _, _, value = unpack(endian + ("IBBHQ" if wide else "IBBHI"), data, offset + width * i)
            if index and typ & 0xE == 0xE and not typ & 0xE0:
                symbols[cstring(strings, index)] = value
    return {"architecture": CPU_NAMES.get(cpu, hex(cpu)), "cpu_type": cpu,
            "bits": 64 if wide else 32, "file_type": kind, "libraries": libraries,
            "segments": segments, "symbols": symbols}


def address_offset(info, address):
    for vm, _, file_offset, file_size in info["segments"]:
        if vm <= address < vm + file_size:
            return file_offset + address - vm, file_offset + file_size
    raise FormatError("symbol is not in file-backed data")


def managed_info(data):
    if block(data, 0, 2) != b"MZ":
        raise FormatError("missing DOS/PE header")
    pe, = unpack("<I", data, 0x3C)
    if block(data, pe, 4) != b"PE\0\0":
        raise FormatError("missing PE signature")
    machine, count = unpack("<HH", data, pe + 4)
    size, = unpack("<H", data, pe + 20)
    opt = pe + 24
    magic, = unpack("<H", data, opt)
    if magic not in (0x10B, 0x20B):
        raise FormatError("unknown PE optional header")
    directory_offset = 96 if magic == 0x10B else 112
    if size < directory_offset + 15 * 8:
        raise FormatError("no CLI data directory")
    rva, cli_size = unpack("<II", data, opt + directory_offset + 14 * 8)

    def pe_offset(address):
        for j in range(count):
            virtual_size, virtual_address, raw_size, raw_offset = unpack("<IIII", data, opt + size + 40 * j + 8)
            if virtual_address <= address < virtual_address + raw_size:
                return raw_offset + address - virtual_address
        raise FormatError("PE RVA is not file-backed")

    if cli_size < 72:
        raise FormatError("truncated CLI header")
    cli = pe_offset(rva)
    block(data, cli, 72)
    metadata_rva, metadata_size, flags = unpack("<III", data, cli + 8)
    metadata = pe_offset(metadata_rva)
    block(data, metadata, metadata_size)
    if block(data, metadata, 4) != b"BSJB":
        raise FormatError("missing CLI metadata signature")
    length, = unpack("<I", data, metadata + 12)
    runtime = block(data, metadata + 16, length).rstrip(b"\0").decode("ascii")
    return {"pe_machine": hex(machine), "cli_flags": hex(flags),
            "il_only": bool(flags & 1), "requires_32_bit": bool(flags & 2),
            "prefers_32_bit": bool(flags & 0x20000), "runtime_metadata": runtime}


def recover_assemblies(data):
    info = macho_info(data)
    if info["architecture"] != "i386":
        raise FormatError("this recovery path is verified only for i386 mkbundle executables")
    found = {}
    for symbol, address in sorted(info["symbols"].items()):
        if not symbol.startswith("_assembly_data_"):
            continue
        encoded = symbol[len("_assembly_data_"):]
        stem, sep, extension = encoded.rpartition("_")
        if not sep or extension not in ("exe", "dll"):
            raise FormatError("unexpected assembly symbol name")
        # mkbundle changes dots to underscores in C symbols. The bundle record
        # retains the real name; use it instead of guessing the spelling.
        bundle_symbol = "_assembly_bundle_" + encoded
        if bundle_symbol not in info["symbols"]:
            raise FormatError("missing bundle record")
        bundle_offset, _ = address_offset(info, info["symbols"][bundle_symbol])
        name_address, data_address, declared_size = unpack("<III", data, bundle_offset)
        if data_address != address or not 0 < declared_size <= MAX_FILE:
            raise FormatError("invalid assembly bundle record")
        name_offset, name_end = address_offset(info, name_address)
        name = cstring(data[name_offset:name_end])
        if not re.fullmatch(r"[A-Za-z0-9_.+-]+\.(dll|exe)", name) or name in found:
            raise FormatError("unsafe or duplicate assembly name")
        offset, end = address_offset(info, address)
        payload = data[offset:end]
        if payload[:2] == b"MZ":
            recovered = block(payload, 0, declared_size)
        else:
            decoder = zlib.decompressobj()
            try:
                recovered = decoder.decompress(payload, MAX_FILE + 1)
            except zlib.error as exc:
                raise FormatError("invalid assembly compression") from exc
            if len(recovered) > MAX_FILE or not decoder.eof:
                raise FormatError("oversized or incomplete compressed assembly")
        if len(recovered) != declared_size:
            raise FormatError("recovered assembly size differs from bundle record")
        found[name] = (recovered, managed_info(recovered))
        if sum(len(item[0]) for item in found.values()) > MAX_TOTAL:
            raise FormatError("excessive recovered assembly total")
    if not found:
        raise FormatError("no recoverable assembly symbols found")
    return found


def read_update(path):
    files = {}
    total = 0
    with tarfile.open(path, "r:*") as archive:
        for member in archive:
            if member.isdir() and member.name in (".", "./"):
                continue
            name = member.name[2:] if member.name.startswith("./") else member.name
            if not member.isfile() or not re.fullmatch(r"[A-Za-z0-9_.+-]+", name):
                raise FormatError("unsupported or unsafe archive member")
            if name in files or not 0 <= member.size <= MAX_FILE:
                raise FormatError("duplicate or oversized archive member")
            total += member.size
            if total > MAX_TOTAL or len(files) > 1024:
                raise FormatError("excessive archive size")
            with archive.extractfile(member) as stream:
                data = stream.read(MAX_FILE + 1)
            if len(data) != member.size:
                raise FormatError("archive member length mismatch")
            files[name] = data
    if not all(app in files for app in APPS):
        raise FormatError("not a complete supported Control:Mac update")
    return files


def recover(update, destination):
    destination = pathlib.Path(destination)
    if destination.exists() or destination.is_symlink():
        raise FileExistsError("output must be a new directory; existing files will not be overwritten")
    files = read_update(update)
    assemblies = {}
    total = 0
    for app in APPS:
        assemblies[app] = recover_assemblies(files[app])
        total += sum(len(item[0]) for item in assemblies[app].values())
        if total > MAX_TOTAL:
            raise FormatError("excessive combined assembly size")
    digest = hashlib.sha256()
    with open(update, "rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    manifest = {"schema_version": 1, "status": "recovered-not-runtime-validated",
                "source_sha256": digest.hexdigest(),
                "version": files.get("VERSION", b"").decode("ascii").strip(),
                "system_version": files.get("SYSVERSION", b"").decode("ascii").strip(),
                "managed": {}, "native": {}}
    for name, data in files.items():
        if data[:4] not in (b"\xce\xfa\xed\xfe", b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe",
                            b"\xbe\xba\xfe\xca", b"\xfe\xed\xfa\xce", b"\xfe\xed\xfa\xcf"):
            continue
        manifest["native"][name] = [
            {k: v for k, v in macho_info(part).items() if k not in ("symbols", "segments")}
            for part in macho_slices(data)]
    # Validation is complete before the first output write. Exclusive creation
    # prevents overwriting an existing recovery or following a destination link.
    destination.mkdir(parents=True, exist_ok=False, mode=0o700)
    for app, recovered in assemblies.items():
        target = destination / "managed" / app
        target.mkdir(parents=True)
        manifest["managed"][app] = {}
        for name, (data, info) in recovered.items():
            (target / name).write_bytes(data)
            manifest["managed"][app][name] = dict(info, size=len(data), sha256=hashlib.sha256(data).hexdigest())
    # Retain original inputs/resources separately; never use tar.extractall.
    original = destination / "original"
    original.mkdir()
    for name, data in files.items():
        (original / name).write_bytes(data)
    (destination / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("update", type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    try:
        manifest = recover(args.update, args.output)
    except (FormatError, OSError, tarfile.TarError, UnicodeError, struct.error) as exc:
        parser.exit(1, "Recovery stopped safely: " + str(exc) + "\n")
    print(json.dumps({"output": str(args.output), "version": manifest["version"],
                      "assemblies": {app: len(items) for app, items in manifest["managed"].items()},
                      "status": manifest["status"]}, indent=2))


if __name__ == "__main__":
    main()
