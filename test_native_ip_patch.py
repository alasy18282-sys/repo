import shutil
import tempfile
import unittest
from pathlib import Path

from native_ip_patch import (
    inspect_library,
    patch_file,
    patch_library,
    valid_ipv4,
    xor_decode,
    xor_encode,
)


ROOT = Path(__file__).resolve().parent
MOON64 = ROOT / "templates/lib/arm64-v8a/libMoonProject.so"
MOON32 = ROOT / "templates/lib/armeabi-v7a/libMoonProject.so"
PLEASURE64 = ROOT / "templates/lib/arm64-v8a/libpleasureproject.so"


class XorCodecTests(unittest.TestCase):
    def test_roundtrip(self):
        for ip in ("1.2.3.4", "172.19.0.1", "144.31.157.245", "192.168.100.18", "255.255.255.255"):
            encoded = xor_encode(ip)
            self.assertEqual(len(encoded), 15)
            self.assertEqual(xor_decode(encoded), ip)
            self.assertEqual(encoded[len(ip):], bytes([0x2E]) * (15 - len(ip)))

    def test_dot_encodes_to_zero(self):
        self.assertEqual(xor_encode("1.1.1.1")[1], 0)


class MoonArm64Tests(unittest.TestCase):
    def test_detects_xor_ip(self):
        data = MOON64.read_bytes()
        info = inspect_library(data)
        self.assertEqual(info["xor_ips"], ["144.31.157.245"])
        self.assertEqual(info["xor_stubs"], 3)
        self.assertEqual(info["ascii_ips"], [])

    def test_wrong_catalog_ip_still_patches(self):
        result = patch_library(MOON64.read_bytes(), "192.168.100.18", "172.19.0.1")
        self.assertGreaterEqual(result["count"], 3)
        self.assertEqual(inspect_library(result["data"])["xor_ips"], ["192.168.100.18"])

    def test_patch_and_restore(self):
        with tempfile.TemporaryDirectory() as tmp:
            copy = Path(tmp) / "libMoonProject.so"
            shutil.copy2(MOON64, copy)
            first = patch_file(str(copy), "192.168.100.18", "172.19.0.1")
            self.assertGreaterEqual(first["count"], 3)
            self.assertIn("144.31.157.245", first["replaced"][0])
            after = inspect_library(copy.read_bytes())
            self.assertEqual(after["xor_ips"], ["192.168.100.18"])
            self.assertEqual(after["xor_stubs"], 3)
            already = patch_file(str(copy), "192.168.100.18")
            self.assertTrue(already["already"])
            self.assertEqual(already["count"], 0)
            restored = patch_file(str(copy), "144.31.157.245")
            self.assertGreaterEqual(restored["count"], 3)
            self.assertEqual(inspect_library(copy.read_bytes())["xor_ips"], ["144.31.157.245"])
            self.assertEqual(copy.read_bytes(), MOON64.read_bytes())


class MoonArmv7Tests(unittest.TestCase):
    def test_ascii_slot(self):
        data = MOON32.read_bytes()
        info = inspect_library(data)
        self.assertIn("94.156.114.39", info["ascii_ips"])
        result = patch_library(data, "10.20.30.40")
        self.assertGreaterEqual(result["count"], 1)
        self.assertIn("94.156.114.39", result["replaced"][0])
        self.assertIn(b"10.20.30.40", result["data"])
        self.assertNotIn(b"94.156.114.39", result["data"])


class PleasureProjectTests(unittest.TestCase):
    def test_only_known_server_ip(self):
        data = PLEASURE64.read_bytes()
        result = patch_library(data, "192.168.100.18")
        self.assertIn(b"192.168.100.18", result["data"])
        self.assertNotIn(b"2.26.99.43", result["data"])
        self.assertIn(b"158.177.37.2", result["data"])
        self.assertIn(b"158.177.37.23", result["data"])


class ValidationTests(unittest.TestCase):
    def test_valid_ipv4(self):
        self.assertTrue(valid_ipv4("192.168.100.18"))
        self.assertFalse(valid_ipv4("999.1.2.3"))
        self.assertFalse(valid_ipv4("host.example"))

    def test_rejects_multicast(self):
        with self.assertRaises(ValueError):
            patch_library(MOON64.read_bytes(), "224.0.0.1")


if __name__ == "__main__":
    unittest.main()
