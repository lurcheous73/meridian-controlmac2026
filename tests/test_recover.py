import io
import pathlib
import struct
import sys
import tarfile
import tempfile
import unittest
import zlib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "tools"))
import recover
import audit


def managed_fixture(flags=1):
    """Synthetic, non-executable PE/CLI structure; no vendor bytes."""
    data = bytearray(2048)
    data[:2] = b"MZ"
    struct.pack_into("<I", data, 0x3C, 0x80)
    data[0x80:0x84] = b"PE\0\0"
    struct.pack_into("<HH", data, 0x84, 0x14C, 1)
    struct.pack_into("<H", data, 0x94, 224)
    struct.pack_into("<H", data, 0x98, 0x10B)
    struct.pack_into("<II", data, 0x98 + 96 + 14 * 8, 0x2000, 72)
    section = 0x98 + 224
    struct.pack_into("<IIII", data, section + 8, 1536, 0x2000, 1536, 512)
    struct.pack_into("<I", data, 512, 72)
    struct.pack_into("<III", data, 512 + 8, 0x2080, 128, flags)
    data[640:644] = b"BSJB"
    runtime = b"v2.0.50727\0\0"
    struct.pack_into("<I", data, 652, len(runtime))
    data[656:656 + len(runtime)] = runtime
    return bytes(data)


def bundle_fixture(name="Example.App.exe", compressed=True, flags=1):
    managed = managed_fixture(flags)
    payload = zlib.compress(managed) if compressed else managed
    data = bytearray(8192)
    struct.pack_into("<IIIIIII", data, 0, 0xFEEDFACE, 7, 3, 2, 2, 80, 0)
    struct.pack_into("<II16sIIIIIIII", data, 28, 1, 56, b"__DATA", 0x1000,
                     len(data), 0, len(data), 7, 3, 0, 0)
    strings = b"\0_assembly_data_Example_App_exe\0_assembly_bundle_Example_App_exe\0"
    second = strings.index(b"_assembly_bundle")
    struct.pack_into("<IIIIII", data, 84, 2, 24, 6000, 2, 6100, len(strings))
    struct.pack_into("<IBBHI", data, 6000, 1, 0xF, 1, 0, 0x1000 + 1024)
    struct.pack_into("<IBBHI", data, 6012, second, 0xF, 1, 0, 0x1000 + 256)
    data[6100:6100 + len(strings)] = strings
    encoded = name.encode() + b"\0"
    data[320:320 + len(encoded)] = encoded
    struct.pack_into("<III", data, 256, 0x1000 + 320, 0x1000 + 1024, len(managed))
    data[1024:1024 + len(payload)] = payload
    return bytes(data)


def write_archive(path, unsafe=None):
    with tarfile.open(path, "w") as archive:
        for name in recover.APPS:
            data = bundle_fixture(name + ".exe")
            info = tarfile.TarInfo("./" + name)
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
        info = tarfile.TarInfo("./VERSION")
        info.size = 4
        archive.addfile(info, io.BytesIO(b"474\n"))
        if unsafe:
            info = tarfile.TarInfo(unsafe)
            info.size = 1
            archive.addfile(info, io.BytesIO(b"x"))


class RecoveryTests(unittest.TestCase):
    def test_managed_flags(self):
        result = recover.managed_info(managed_fixture())
        self.assertTrue(result["il_only"])
        self.assertFalse(result["requires_32_bit"])
        self.assertEqual(result["runtime_metadata"], "v2.0.50727")

    def test_32bit_flag(self):
        self.assertTrue(recover.managed_info(managed_fixture(3))["requires_32_bit"])

    def test_truncated_pe(self):
        with self.assertRaises(recover.FormatError):
            recover.managed_info(managed_fixture()[:200])

    def test_missing_cli(self):
        data = bytearray(managed_fixture())
        struct.pack_into("<II", data, 0x98 + 96 + 14 * 8, 0, 0)
        with self.assertRaises(recover.FormatError):
            recover.managed_info(bytes(data))

    def test_compressed_recovery(self):
        result = recover.recover_assemblies(bundle_fixture())
        self.assertEqual(result["Example.App.exe"][0], managed_fixture())

    def test_uncompressed_recovery(self):
        self.assertEqual(recover.recover_assemblies(bundle_fixture(compressed=False))["Example.App.exe"][0], managed_fixture())

    def test_exact_name_is_retained(self):
        self.assertIn("Example_Name.App.exe", recover.recover_assemblies(bundle_fixture("Example_Name.App.exe")))

    def test_unsafe_assembly_name(self):
        with self.assertRaises(recover.FormatError):
            recover.recover_assemblies(bundle_fixture("../escape.exe"))

    def test_bad_declared_size(self):
        data = bytearray(bundle_fixture())
        struct.pack_into("<I", data, 264, 5)
        with self.assertRaises(recover.FormatError):
            recover.recover_assemblies(bytes(data))

    def test_bad_compression(self):
        data = bytearray(bundle_fixture())
        data[1024:1028] = b"BAD!"
        with self.assertRaises(recover.FormatError):
            recover.recover_assemblies(bytes(data))

    def test_bad_load_command(self):
        data = bytearray(bundle_fixture())
        struct.pack_into("<I", data, 32, 0)
        with self.assertRaises(recover.FormatError):
            recover.macho_info(bytes(data))

    def test_end_to_end(self):
        with tempfile.TemporaryDirectory() as temp:
            path = pathlib.Path(temp)
            write_archive(path / "input.tar")
            manifest = recover.recover(path / "input.tar", path / "output")
            self.assertEqual(manifest["version"], "474")
            for app in recover.APPS:
                self.assertEqual((path / "output" / "managed" / app / (app + ".exe")).read_bytes(), managed_fixture())

    def test_refuses_existing_output(self):
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaises(FileExistsError):
                recover.recover("does-not-exist", temp)

    def test_archive_path_traversal(self):
        with tempfile.TemporaryDirectory() as temp:
            path = pathlib.Path(temp)
            write_archive(path / "input.tar", "../escape")
            with self.assertRaises(recover.FormatError):
                recover.recover(path / "input.tar", path / "output")
            self.assertFalse((path / "output").exists())

    def test_absolute_archive_path(self):
        with tempfile.TemporaryDirectory() as temp:
            path = pathlib.Path(temp) / "input.tar"
            write_archive(path, "/escape")
            with self.assertRaises(recover.FormatError):
                recover.read_update(path)

    def test_symlink_archive_entry(self):
        with tempfile.TemporaryDirectory() as temp:
            path = pathlib.Path(temp) / "input.tar"
            with tarfile.open(path, "w") as archive:
                info = tarfile.TarInfo("ControlMac")
                info.type = tarfile.SYMTYPE
                info.linkname = "/etc/passwd"
                archive.addfile(info)
            with self.assertRaises(recover.FormatError):
                recover.read_update(path)

    def test_truncated_fat_header(self):
        with self.assertRaises(recover.FormatError):
            recover.macho_slices(b"\xca\xfe\xba\xbe\0\0\0\1")


class AuditTests(unittest.TestCase):
    def test_field_parse(self):
        fields = audit.parse_fields("########## Monobjc.Cocoa.NSPoint\n1: float32 x: public \n2: float32 y: public \n3: float32 ignored: public static \n")
        self.assertEqual(fields["Monobjc.Cocoa.NSPoint"], {"x": "float32", "y": "float32"})

    def test_old_layout_blocks(self):
        fields = {"Monobjc.Cocoa.NSPoint": {"x": "float32", "y": "float32"}}
        findings = audit.layout_findings(fields)
        self.assertEqual(len(findings), 6)
        self.assertEqual(findings[0]["severity"], "blocker")

    def test_correct_layout(self):
        self.assertEqual(audit.layout_findings(audit.LAYOUTS), [])


if __name__ == "__main__":
    unittest.main()
