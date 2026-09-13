"""Offline IPA inspection, extraction and unsigned repacking; Python stdlib only."""
import argparse
import copy
import hashlib
import json
import os
import plistlib
import re
import shutil
import stat
import struct
import sys
import tempfile
import zipfile
from pathlib import Path, PurePosixPath
from il2cpp_endpoints import replace_hosts

CHUNK = 1024 * 1024
MAX_TOTAL = 20 * 1024**3
MAX_EDIT = 256 * 1024**2


def digest(path):
    with open(path, "rb") as f:
        h = hashlib.sha256()
        for data in iter(lambda: f.read(CHUNK), b""):
            h.update(data)
    return h.hexdigest()


def write_json(path, obj):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def valid_name(name):
    parts = name.rstrip("/").split("/")
    if (not name or "\\" in name or name.startswith("/") or
            any(p in ("", ".", "..") or ":" in p or p.endswith((" ", ".")) for p in parts)):
        raise ValueError("Unsafe archive path: " + name)
    if any(re.fullmatch(r"(?i)(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\..*)?", p) for p in parts):
        raise ValueError("Reserved archive path: " + name)


def validate_archive(z):
    seen = set()
    total = 0
    for item in z.infolist():
        valid_name(item.filename)
        key = item.filename.rstrip("/").casefold()
        if key in seen:
            raise ValueError("Duplicate/case-colliding archive path: " + item.filename)
        seen.add(key)
        if item.flag_bits & 1:
            raise ValueError("Password-encrypted ZIP entry: " + item.filename)
        if stat.S_ISLNK(item.external_attr >> 16):
            raise ValueError("Symlink entry needs a symlink-aware platform: " + item.filename)
        total += item.file_size
        if total > MAX_TOTAL:
            raise ValueError("Archive exceeds 20 GiB unpacked limit")
    # Reject file/directory prefix collisions, including implicit directories.
    files = {i.filename.casefold() for i in z.infolist() if not i.is_dir()}
    for name in seen:
        for parent in PurePosixPath(name).parents:
            if str(parent) in files:
                raise ValueError("File/directory path collision: " + name)


def load_plist(z, name):
    if z.getinfo(name).file_size > 16 * 1024**2:
        raise ValueError("Oversized plist: " + name)
    data = z.read(name)
    value = plistlib.loads(data)
    if not isinstance(value, dict):
        raise ValueError("Expected plist dictionary: " + name)
    return value, plistlib.FMT_BINARY if data.startswith(b"bplist00") else plistlib.FMT_XML


def main_app(z):
    names = [n for n in z.namelist() if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", n)]
    if len(names) != 1:
        raise ValueError("IPA must contain exactly one Payload/*.app/Info.plist")
    info, fmt = load_plist(z, names[0])
    executable = info.get("CFBundleExecutable", "")
    if not executable or "/" in executable or "\\" in executable:
        raise ValueError("Invalid CFBundleExecutable")
    root = names[0][:-len("Info.plist")]
    if root + executable not in z.namelist():
        raise ValueError("Main executable missing")
    return root, info, fmt


def macho(stream, total):
    """Read thin/fat Mach-O headers and encryption/signature load commands only."""
    thin = {b"\xce\xfa\xed\xfe": ("<", False), b"\xcf\xfa\xed\xfe": ("<", True),
            b"\xfe\xed\xfa\xce": (">", False), b"\xfe\xed\xfa\xcf": (">", True)}
    fat = {b"\xca\xfe\xba\xbe": (">", False), b"\xbe\xba\xfe\xca": ("<", False),
           b"\xca\xfe\xba\xbf": (">", True), b"\xbf\xba\xfe\xca": ("<", True)}

    def read_at(offset, size):
        if offset < 0 or size < 0 or offset + size > total:
            raise ValueError("Mach-O range outside file")
        stream.seek(offset)
        data = stream.read(size)
        if len(data) != size:
            raise ValueError("Truncated Mach-O")
        return data

    def parse_slice(base, length):
        magic = read_at(base, 4)
        if magic not in thin:
            raise ValueError("Invalid Mach-O slice")
        endian, is64 = thin[magic]
        header_size = 32 if is64 else 28
        if length < header_size:
            raise ValueError("Short Mach-O header")
        header = struct.unpack(endian + "7I", read_at(base, 28))
        cpu, ncmds, sizeofcmds = header[1], header[4], header[5]
        if sizeofcmds > 16 * 1024**2 or header_size + sizeofcmds > length or ncmds > sizeofcmds // 8:
            raise ValueError("Invalid Mach-O load commands")
        commands = read_at(base + header_size, sizeofcmds)
        pos = 0
        encryption = []
        signatures = []
        for _ in range(ncmds):
            if pos + 8 > len(commands):
                raise ValueError("Truncated load command")
            cmd, size = struct.unpack_from(endian + "II", commands, pos)
            if size < 8 or pos + size > len(commands):
                raise ValueError("Invalid load command size")
            if cmd in (0x21, 0x2C):
                if size < (24 if cmd == 0x2C else 20):
                    raise ValueError("Short encryption command")
                off, count, cryptid = struct.unpack_from(endian + "III", commands, pos + 8)
                if off + count > length:
                    raise ValueError("Invalid encrypted range")
                encryption.append({"offset": off, "size": count, "cryptid": cryptid})
            if cmd == 0x1D:
                if size < 16:
                    raise ValueError("Short signature command")
                off, count = struct.unpack_from(endian + "II", commands, pos + 8)
                if off + count > length:
                    raise ValueError("Invalid signature range")
                signatures.append({"offset": off, "size": count})
            pos += size
        return {"architecture": {12: "arm", 0x100000C: "arm64", 7: "x86", 0x1000007: "x86_64"}.get(cpu, hex(cpu)),
                "offset": base, "size": length, "encryption": encryption, "signatures": signatures}

    if total < 4:
        return []
    magic = read_at(0, 4)
    if magic in thin:
        return [parse_slice(0, total)]
    if magic not in fat:
        return []
    endian, fat64 = fat[magic]
    count = struct.unpack(endian + "I", read_at(4, 4))[0]
    if not 1 <= count <= 32:
        raise ValueError("Invalid fat architecture count")
    size = 32 if fat64 else 20
    table = read_at(8, count * size)
    slices = []
    ranges = []
    for i in range(count):
        row = struct.unpack_from(endian + ("IIQQII" if fat64 else "IIIII"), table, i * size)
        off, length = row[2], row[3]
        if off < 8 + count * size or off + length > total or any(off < b and off + length > a for a, b in ranges):
            raise ValueError("Invalid/overlapping fat slice")
        ranges.append((off, off + length))
        slices.append(parse_slice(off, length))
    return slices


def inspect_ipa(source, full_hash=True):
    source = Path(source)
    with zipfile.ZipFile(source) as z:
        validate_archive(z)
        root, info, _ = main_app(z)
        binaries = []
        for item in z.infolist():
            if item.is_dir():
                continue
            with z.open(item) as stream:
                slices = macho(stream, item.file_size)
            if slices:
                binaries.append({"path": item.filename, "slices": slices})
        encrypted = any(c["cryptid"] for b in binaries for s in b["slices"] for c in s["encryption"])
        result = {"source": str(source.resolve()), "size": source.stat().st_size,
                  "entries": len(z.infolist()), "unpacked_bytes": sum(i.file_size for i in z.infolist()),
                  "app_root": root, "bundle_id": info.get("CFBundleIdentifier"),
                  "display_name": info.get("CFBundleDisplayName", info.get("CFBundleName")),
                  "version": info.get("CFBundleShortVersionString"), "build": info.get("CFBundleVersion"),
                  "minimum_ios": info.get("MinimumOSVersion"), "supported_devices": info.get("UISupportedDevices", []),
                  "binaries": binaries, "encrypted": encrypted,
                  "firebase_plists": [n for n in z.namelist() if n.endswith("/GoogleService-Info.plist")],
                  "extensions": [n for n in z.namelist() if n.endswith(".appex/Info.plist")],
                  "signature_resources": [n for n in z.namelist() if "/_CodeSignature/" in n],
                  "signature_status": "not cryptographically verified",
                  "runtime_status": "not tested on an iOS device"}
    if full_hash:
        result["sha256"] = digest(source)
    return result


def verify_output(path, manifest):
    with zipfile.ZipFile(path) as z:
        validate_archive(z)
        if set(z.namelist()) != set(manifest):
            raise ValueError("Output entries differ from manifest")
        for item in z.infolist():
            h = hashlib.sha256()
            with z.open(item) as stream:
                for chunk in iter(lambda: stream.read(CHUNK), b""):
                    h.update(chunk)
            if h.hexdigest() != manifest[item.filename]["sha256"]:
                raise ValueError("Output content verification failed: " + item.filename)


def build_unsigned(source, output, config):
    if not isinstance(config, dict):
        raise ValueError("Build config must be a JSON object")
    source, output = Path(source).resolve(), Path(output).resolve()
    if source == output:
        raise ValueError("Source and output must differ")
    if output.suffix.lower() != ".ipa":
        raise ValueError("Output must have .ipa extension")
    report_path = Path(str(output) + ".report.json")
    if output.exists() or report_path.exists():
        raise ValueError("Output/report already exists; choose a new output path")
    original = inspect_ipa(source)
    if original["encrypted"]:
        raise ValueError("Encrypted Mach-O found; this builder requires an unencrypted input and does not decrypt code")
    output.parent.mkdir(parents=True, exist_ok=True)
    changes = {}
    edits = []
    with zipfile.ZipFile(source) as z:
        root, info, fmt = main_app(z)
        previous_bundle = info["CFBundleIdentifier"]
        mapping = {"IpaBundle": "CFBundleIdentifier", "IpaLabel": "CFBundleDisplayName",
                   "IpaVersion": "CFBundleShortVersionString", "IpaBuild": "CFBundleVersion"}
        for field, key in mapping.items():
            value = str(config.get(field) or "").strip()
            if not value:
                continue
            if field == "IpaBundle" and not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", value):
                raise ValueError("Invalid iOS bundle identifier")
            if field in ("IpaVersion", "IpaBuild") and not re.fullmatch(r"\d+(?:\.\d+){0,2}", value):
                raise ValueError("Version/build must contain one to three numeric components")
            if info.get(key) != value:
                edits.append({"path": root + "Info.plist", "field": key, "before": info.get(key), "after": value})
                info[key] = value
        if original["extensions"] and info["CFBundleIdentifier"] != previous_bundle:
            raise ValueError("Changing the main bundle ID with app extensions requires explicit per-extension configuration")
        if config.get("IpaGooglePlist"):
            raw = Path(config["IpaGooglePlist"]).read_bytes()
            google = plistlib.loads(raw)
            if not isinstance(google, dict) or not all(google.get(k) for k in ("GOOGLE_APP_ID", "BUNDLE_ID", "CLIENT_ID", "REVERSED_CLIENT_ID")):
                raise ValueError("Expected iOS GoogleService-Info.plist, not Android google-services.json")
            if google["BUNDLE_ID"] != info["CFBundleIdentifier"]:
                raise ValueError("Firebase BUNDLE_ID differs from the selected iOS bundle")
            paths = original["firebase_plists"] or [root + "GoogleService-Info.plist"]
            old_schemes = set()
            for name in original["firebase_plists"]:
                old_schemes.add(load_plist(z, name)[0].get("REVERSED_CLIENT_ID"))
            for name in paths:
                changes[name] = raw
                edits.append({"path": name, "action": "replace iOS Firebase plist"})
            types = info.setdefault("CFBundleURLTypes", [])
            for entry in types:
                entry["CFBundleURLSchemes"] = [s for s in entry.get("CFBundleURLSchemes", []) if s not in old_schemes]
            types.append({"CFBundleURLName": "GoogleSignIn", "CFBundleURLSchemes": [google["REVERSED_CLIENT_ID"]]})
        if edits:
            changes[root + "Info.plist"] = plistlib.dumps(info, fmt=fmt, sort_keys=False)
        if str(config.get("IpaServerIp") or "").strip():
            metadata_paths = [n for n in z.namelist() if n.startswith(root) and n.endswith("/global-metadata.dat")]
            if len(metadata_paths) != 1:
                raise ValueError("IPA IP replacement requires exactly one IL2CPP global-metadata.dat")
            name = metadata_paths[0]
            if z.getinfo(name).file_size > MAX_EDIT:
                raise ValueError("IL2CPP metadata exceeds edit size limit")
            changes[name], endpoint_report = replace_hosts(
                z.read(name), str(config.get("IpaOriginalHosts") or ""),
                str(config["IpaServerIp"]).strip())
            endpoint_report["path"] = name
            edits.append(endpoint_report)
        # Optional exact, equal-length patches with an explicit match count.
        if config.get("IpaPatchPlan"):
            plan = json.loads(Path(config["IpaPatchPlan"]).read_text(encoding="utf-8-sig"))
            if not isinstance(plan, dict) or not isinstance(plan.get("patches"), list):
                raise ValueError("Patch plan requires a patches array")
            for patch in plan["patches"]:
                if not isinstance(patch, dict) or not all(k in patch for k in ("path", "find_hex", "replace_hex", "expected_matches")):
                    raise ValueError("Each patch requires path, find_hex, replace_hex, expected_matches")
                name = patch["path"]
                valid_name(name)
                if not name.startswith(root) or name in changes or z.getinfo(name).file_size > MAX_EDIT:
                    raise ValueError("Patch target conflicts, is too large, or is outside the app: " + name)
                before = bytes.fromhex(patch["find_hex"])
                after = bytes.fromhex(patch["replace_hex"])
                count = patch["expected_matches"]
                if not before or len(before) != len(after) or type(count) is not int or count < 1:
                    raise ValueError("Patch requires equal-length nonempty bytes and a positive expected_matches")
                data = z.read(name)
                if data.count(before) != count:
                    raise ValueError("Patch match-count mismatch: " + name)
                offsets = [m.start() for m in re.finditer(re.escape(before), data)]
                changes[name] = data.replace(before, after)
                edits.append({"path": name, "action": "exact equal-length patch", "offsets": offsets,
                              "find_hex": before.hex(), "replace_hex": after.hex()})
        manifest = {}
        removed = []
        fd, tempname = tempfile.mkstemp(prefix="ipa-build-", suffix=".ipa", dir=output.parent)
        os.close(fd)
        temp = Path(tempname)
        try:
            with zipfile.ZipFile(temp, "w", allowZip64=True, compression=zipfile.ZIP_DEFLATED, compresslevel=1) as target:
                for item in z.infolist():
                    if "/_CodeSignature/" in item.filename or item.filename.endswith("/embedded.mobileprovision"):
                        removed.append(item.filename)
                        continue
                    clone = copy.copy(item)
                    clone.compress_type = zipfile.ZIP_DEFLATED
                    clone._compresslevel = 1
                    # Preserve permissions and timestamps, drop stale ZIP64/extra offsets.
                    clone.extra = b""
                    h = hashlib.sha256()
                    before_hash = None
                    if item.filename in changes:
                        original_data = z.read(item)
                        before_hash = hashlib.sha256(original_data).hexdigest()
                        data = changes[item.filename]
                        target.writestr(clone, data)
                        h.update(data)
                    else:
                        with z.open(item) as src, target.open(clone, "w", force_zip64=True) as dst:
                            for data in iter(lambda: src.read(CHUNK), b""):
                                dst.write(data)
                                h.update(data)
                    manifest[item.filename] = {"sha256": h.hexdigest(),
                                               "original_sha256": before_hash or h.hexdigest()}
                for name, data in changes.items():
                    if name not in manifest:
                        target.writestr(name, data)
                        manifest[name] = {"sha256": hashlib.sha256(data).hexdigest(), "original_sha256": None}
            verify_output(temp, manifest)
            modified = inspect_ipa(temp, full_hash=False)
            # Reject patches that damaged load commands or altered encryption state.
            if modified["encrypted"]:
                raise ValueError("Patched output has encrypted Mach-O state")
            if digest(source) != original["sha256"]:
                raise ValueError("Source changed while building")
            out_hash = digest(temp)
            report = {"original": original, "output": str(output), "output_sha256": out_hash,
                      "server_ip": str(config.get("IpaServerIp") or ""),
                      "endpoint_replacements": sum(e.get("matched_literals", 0) for e in edits),
                      "status": "unsigned_requires_resigning", "device_installation_verified": False,
                      "warning": "Old Mach-O signature blobs may remain; they are invalid after edits. Fresh iOS signing is required.",
                      "changes": edits, "removed_signature_resources": removed, "entries": manifest,
                      "output_bundle_id": modified["bundle_id"], "output_display_name": modified["display_name"],
                      "verified": "All output entries reread, CRC checked and SHA256 compared; original SHA256 unchanged"}
            # Never overwrite an existing output, even if it appeared while building.
            with output.open("xb") as dst, temp.open("rb") as src:
                shutil.copyfileobj(src, dst, CHUNK)
            if digest(output) != out_hash:
                output.unlink()
                raise ValueError("Final copy verification failed")
            write_json(report_path, report)
            return report
        finally:
            temp.unlink(missing_ok=True)


def extract(source, destination):
    destination = Path(destination).resolve()
    if destination.exists():
        raise ValueError("Extraction destination must be new")
    with zipfile.ZipFile(source) as z:
        validate_archive(z)
        main_app(z)
        destination.mkdir(parents=True)
        for item in z.infolist():
            path = destination.joinpath(*PurePosixPath(item.filename).parts)
            if not path.resolve().is_relative_to(destination):
                raise ValueError("Extraction path escaped destination")
            if item.is_dir():
                path.mkdir(parents=True, exist_ok=True)
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                with z.open(item) as src, path.open("xb") as dst:
                    shutil.copyfileobj(src, dst, CHUNK)
    return {"directory": str(destination), "status": "extracted"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("inspect", "build", "extract"))
    parser.add_argument("--source", required=True)
    parser.add_argument("--output")
    parser.add_argument("--config")
    parser.add_argument("--report")
    args = parser.parse_args()
    try:
        if args.report:
            if Path(args.report).resolve() in (Path(args.source).resolve(), Path(args.output).resolve() if args.output else None):
                raise ValueError("Report path must differ from source and output")
            if Path(args.report).exists():
                raise ValueError("Report already exists; choose a new report path")
        if args.action == "inspect":
            result = inspect_ipa(args.source)
        elif args.action == "extract":
            if not args.output:
                raise ValueError("--output required")
            result = extract(args.source, args.output)
        else:
            if not args.output:
                raise ValueError("--output required")
            config = json.loads(Path(args.config).read_text(encoding="utf-8-sig")) if args.config else {}
            result = build_unsigned(args.source, args.output, config)
        if args.report:
            write_json(args.report, result)
        print(json.dumps(result if args.action == "inspect" else
                         {k: result[k] for k in ("status", "output", "output_sha256", "directory", "server_ip", "endpoint_replacements") if k in result},
                         ensure_ascii=False, indent=2))
    except (ValueError, OSError, KeyError, zipfile.BadZipFile, plistlib.InvalidFileException, struct.error) as exc:
        print("ERROR: " + str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    sys.exit(main())
