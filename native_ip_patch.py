"""Patch IPv4 destinations in injected Android .so libraries.

MoonProject arm64-v8a does not keep the host as a plaintext ASCII string.
The Connect hooks store a 15-byte buffer XOR-encoded with 0x2E ('.'):

  bytes 0-7  — 8-byte blob in .rodata, loaded with LDR Dt
  bytes 8-11 — MOVZ/MOVK immediate
  bytes 12-13 — MOVZ immediate
  byte 14    — MOVZ immediate (encoded NUL is 0x2E)

armeabi-v7a builds still use a bounded ASCII IPv4 slot.
"""
from __future__ import annotations

import argparse
import json
import re
import struct
import sys
from ipaddress import AddressValueError, IPv4Address


XOR_KEY = 0x2E
IPV4_RE = re.compile(rb"\d{1,3}(?:\.\d{1,3}){3}")
ASCII_SKIP = frozenset({"127.0.0.1", "0.0.0.0", "255.255.255.255"})
KNOWN_LIB_IPS = (
    "2.26.99.43",
    "144.31.157.245",
    "94.156.114.39",
    "5.42.82.49",
    "172.19.0.1",
)


def valid_ipv4(value: str) -> bool:
    try:
        address = IPv4Address(value)
    except (AddressValueError, ValueError):
        return False
    return address.version == 4 and "." in value and len(value) <= 15


def xor_encode(ip: str) -> bytes:
    encoded = bytes(b ^ XOR_KEY for b in ip.encode("ascii"))
    if len(encoded) > 15:
        raise ValueError("IPv4 longer than 15 bytes")
    return encoded.ljust(15, bytes([XOR_KEY]))


def xor_decode(blob: bytes) -> str:
    decoded = bytes(b ^ XOR_KEY for b in blob)
    end = decoded.find(0)
    if end >= 0:
        decoded = decoded[:end]
    text = decoded.decode("ascii", errors="strict")
    if not valid_ipv4(text):
        raise ValueError("decoded XOR blob is not an IPv4 address")
    return text


def u32(data: bytes, offset: int) -> int:
    return struct.unpack_from("<I", data, offset)[0]


def p32(value: int) -> bytes:
    return struct.pack("<I", value & 0xFFFFFFFF)


def elf_load_segments(data: bytes):
    if data[:4] != b"\x7fELF":
        raise ValueError("Not an ELF shared object")
    ei_class = data[4]
    segments = []
    if ei_class == 2:
        e_phoff = struct.unpack_from("<Q", data, 32)[0]
        e_phentsize, e_phnum = struct.unpack_from("<HH", data, 54)
        for i in range(e_phnum):
            off = e_phoff + i * e_phentsize
            p_type, p_flags = struct.unpack_from("<II", data, off)
            p_offset, p_vaddr, _, p_filesz, _, _ = struct.unpack_from("<QQQQQQ", data, off + 8)
            if p_type == 1 and p_filesz:
                segments.append((p_vaddr, p_offset, p_filesz, p_flags))
    elif ei_class == 1:
        e_phoff = struct.unpack_from("<I", data, 28)[0]
        e_phentsize, e_phnum = struct.unpack_from("<HH", data, 42)
        for i in range(e_phnum):
            off = e_phoff + i * e_phentsize
            p_type, p_offset, p_vaddr, _, p_filesz, _, p_flags, _ = struct.unpack_from(
                "<IIIIIIII", data, off
            )
            if p_type == 1 and p_filesz:
                segments.append((p_vaddr, p_offset, p_filesz, p_flags))
    else:
        raise ValueError("Unsupported ELF class")
    return segments


def va_to_offset(segments, va: int):
    for vaddr, offset, filesz, _flags in segments:
        if vaddr <= va < vaddr + filesz:
            return offset + (va - vaddr)
    return None


def executable_ranges(segments):
    ranges = []
    for vaddr, offset, filesz, flags in segments:
        if flags & 1:
            ranges.append((vaddr, offset, filesz))
    return ranges


def is_movz_w(insn: int) -> bool:
    return (insn & 0xFFC00000) == 0x52800000


def is_movk_w_lsl16(insn: int) -> bool:
    # bits 31-21: sf=0, opc=11, 100101, hw=01 (LSL #16)
    return (insn & 0xFFE00000) == 0x72A00000


def is_ldr_d(insn: int) -> bool:
    return (insn & 0xFFC00000) == 0xFD400000


def is_adrp(insn: int) -> bool:
    return (insn & 0x9F000000) == 0x90000000


def is_str_w(insn: int) -> bool:
    return (insn & 0xFFC00000) == 0xB9000000


def is_strh(insn: int) -> bool:
    return (insn & 0xFFC00000) == 0x79000000


def is_strb(insn: int) -> bool:
    return (insn & 0xFFC00000) == 0x39000000


def is_str_d(insn: int) -> bool:
    return (insn & 0xFFC00000) == 0xFD000000


def mov_rd(insn: int) -> int:
    return insn & 31


def mov_imm16(insn: int) -> int:
    return (insn >> 5) & 0xFFFF


def make_movz_w(rd: int, imm16: int) -> int:
    return 0x52800000 | ((imm16 & 0xFFFF) << 5) | (rd & 31)


def make_movk_w_lsl16(rd: int, imm16: int) -> int:
    return 0x72A00000 | ((imm16 & 0xFFFF) << 5) | (rd & 31)


def ldr_d_parts(insn: int):
    return insn & 31, (insn >> 5) & 31, ((insn >> 10) & 0xFFF) * 8


def str_imm(insn: int, scale: int) -> int:
    return ((insn >> 10) & 0xFFF) * scale


def str_rn_rt(insn: int):
    return (insn >> 5) & 31, insn & 31


def adrp_target(insn: int, pc: int) -> int:
    immlo = (insn >> 29) & 3
    immhi = (insn >> 5) & 0x7FFFF
    imm = (immhi << 2) | immlo
    if imm & (1 << 20):
        imm -= 1 << 21
    return (pc & ~0xFFF) + (imm << 12)


def find_xor_stubs(data: bytes):
    segments = elf_load_segments(data)
    stubs = []
    seen_code = set()
    for vaddr, offset, filesz in executable_ranges(segments):
        end = offset + filesz - 16
        pos = offset
        while pos <= end:
            insn0, insn1, insn2, insn3 = struct.unpack_from("<IIII", data, pos)
            if not (
                is_str_w(insn0)
                and is_strh(insn1)
                and is_str_d(insn2)
                and is_strb(insn3)
            ):
                pos += 4
                continue
            rn0, rt_word = str_rn_rt(insn0)
            rn1, rt_half = str_rn_rt(insn1)
            rn2, rt_d = str_rn_rt(insn2)
            rn3, rt_byte = str_rn_rt(insn3)
            if not (rn0 == rn1 == rn2 == rn3 and str_imm(insn0, 4) == 8
                    and str_imm(insn1, 2) == 12 and str_imm(insn2, 8) == 0
                    and str_imm(insn3, 1) == 14):
                pos += 4
                continue
            window_off = max(offset, pos - 20 * 4)
            movz_word = movk_word = movz_half = movz_byte = ldr = adrp = None
            adrp_by_reg = {}
            scan = window_off
            while scan < pos:
                insn = u32(data, scan)
                pc = vaddr + (scan - offset)
                if is_adrp(insn):
                    adrp_by_reg[mov_rd(insn)] = (scan, insn, adrp_target(insn, pc))
                elif is_movz_w(insn) and mov_rd(insn) == rt_word:
                    movz_word = (scan, insn)
                elif is_movk_w_lsl16(insn) and mov_rd(insn) == rt_word:
                    movk_word = (scan, insn)
                elif is_movz_w(insn) and mov_rd(insn) == rt_half:
                    movz_half = (scan, insn)
                elif is_movz_w(insn) and mov_rd(insn) == rt_byte:
                    movz_byte = (scan, insn)
                elif is_ldr_d(insn):
                    rt, rn, addend = ldr_d_parts(insn)
                    if rt == rt_d:
                        ldr = (scan, insn, rn, addend)
                        adrp = adrp_by_reg.get(rn)
                scan += 4
            if not (movz_word and movk_word and movz_half and movz_byte and ldr and adrp):
                pos += 4
                continue
            rodata_va = adrp[2] + ldr[3]
            rodata_off = va_to_offset(segments, rodata_va)
            if rodata_off is None or rodata_off + 8 > len(data):
                pos += 4
                continue
            encoded = bytearray(data[rodata_off:rodata_off + 8])
            word = mov_imm16(movz_word[1]) | (mov_imm16(movk_word[1]) << 16)
            encoded.extend(struct.pack("<I", word))
            encoded.extend(struct.pack("<H", mov_imm16(movz_half[1])))
            encoded.append(mov_imm16(movz_byte[1]) & 0xFF)
            try:
                ip = xor_decode(bytes(encoded))
            except ValueError:
                pos += 4
                continue
            key = (movz_word[0], rodata_off)
            if key not in seen_code:
                seen_code.add(key)
                stubs.append({
                    "ip": ip,
                    "encoded": bytes(encoded),
                    "rodata_off": rodata_off,
                    "movz_word_off": movz_word[0],
                    "movk_word_off": movk_word[0],
                    "movz_half_off": movz_half[0],
                    "movz_byte_off": movz_byte[0],
                    "rt_word": rt_word,
                    "rt_half": rt_half,
                    "rt_byte": rt_byte,
                })
            pos += 4
    return stubs


def find_ascii_ipv4s(data: bytes):
    found = []
    seen = set()
    for match in IPV4_RE.finditer(data):
        text = match.group(0).decode("ascii")
        if text in seen or not valid_ipv4(text) or text in ASCII_SKIP:
            continue
        seen.add(text)
        found.append(text)
    return found


def replace_ascii_ipv4(buf: bytearray, old_ip: str, new_ip: str) -> int:
    old_b = old_ip.encode("ascii")
    new_b = new_ip.encode("ascii")
    if len(new_b) > 15:
        raise ValueError("IPv4 longer than 15 characters")
    count = 0
    i = 0
    limit = len(buf) - len(old_b)
    while i <= limit:
        if buf[i:i + len(old_b)] != old_b:
            i += 1
            continue
        after = buf[i + len(old_b)] if i + len(old_b) < len(buf) else 0
        pad16 = False
        if i + 16 <= len(buf):
            pad16 = all(buf[i + k] == 0 for k in range(len(old_b), 16))
        bounded = after == 0 or after < 48 or after > 57
        if not pad16 and not bounded:
            i += 1
            continue
        slot = 16 if pad16 else len(old_b)
        if len(new_b) > slot:
            i += 1
            continue
        buf[i:i + len(new_b)] = new_b
        for k in range(len(new_b), slot):
            buf[i + k] = 0
        count += 1
        i += slot
    return count


def patch_xor_stub(buf: bytearray, stub: dict, new_ip: str) -> bool:
    encoded = xor_encode(new_ip)
    if encoded == stub["encoded"]:
        return False
    buf[stub["rodata_off"]:stub["rodata_off"] + 8] = encoded[:8]
    word = struct.unpack_from("<I", encoded, 8)[0]
    half = struct.unpack_from("<H", encoded, 12)[0]
    last = encoded[14]
    buf[stub["movz_word_off"]:stub["movz_word_off"] + 4] = p32(
        make_movz_w(stub["rt_word"], word & 0xFFFF)
    )
    buf[stub["movk_word_off"]:stub["movk_word_off"] + 4] = p32(
        make_movk_w_lsl16(stub["rt_word"], (word >> 16) & 0xFFFF)
    )
    buf[stub["movz_half_off"]:stub["movz_half_off"] + 4] = p32(
        make_movz_w(stub["rt_half"], half)
    )
    buf[stub["movz_byte_off"]:stub["movz_byte_off"] + 4] = p32(
        make_movz_w(stub["rt_byte"], last)
    )
    return True


def replace_contiguous_xor(buf: bytearray, old_ip: str, new_ip: str) -> int:
    old_enc = xor_encode(old_ip)
    new_enc = xor_encode(new_ip)
    needle = old_enc[: len(old_ip)]
    count = 0
    start = 0
    while True:
        pos = bytes(buf).find(needle, start)
        if pos < 0:
            return count
        slot = 15
        if pos + slot <= len(buf) and all(
            buf[pos + len(needle) + k] == XOR_KEY
            for k in range(slot - len(needle))
        ):
            buf[pos:pos + slot] = new_enc
            count += 1
            start = pos + slot
        else:
            start = pos + 1


def inspect_library(data: bytes) -> dict:
    stubs = find_xor_stubs(data)
    xor_ips = list(dict.fromkeys(stub["ip"] for stub in stubs))
    return {
        "ascii_ips": find_ascii_ipv4s(data),
        "xor_ips": xor_ips,
        "xor_stubs": len(stubs),
    }


def patch_library(data: bytes, new_ip: str, old_ip: str = "") -> dict:
    if not valid_ipv4(new_ip):
        raise ValueError("New IP must be a unicast IPv4 address of at most 15 characters")
    if IPv4Address(new_ip).is_multicast or IPv4Address(new_ip).is_unspecified:
        raise ValueError("New IP must be a unicast destination")
    stubs = find_xor_stubs(data)
    xor_ips = list(dict.fromkeys(stub["ip"] for stub in stubs))
    ascii_ips = find_ascii_ipv4s(data)
    present = set(ascii_ips) | set(xor_ips)
    if old_ip and valid_ipv4(old_ip) and old_ip in present:
        preferred = [old_ip]
    else:
        preferred = []
    targets = []
    for ip in preferred + list(KNOWN_LIB_IPS) + xor_ips:
        if ip == new_ip or ip in ASCII_SKIP or ip not in present:
            continue
        if ip not in targets:
            targets.append(ip)
    buf = bytearray(data)
    replaced = []
    count = 0
    for ip in targets:
        ascii_n = replace_ascii_ipv4(buf, ip, new_ip)
        xor_contig = replace_contiguous_xor(buf, ip, new_ip)
        xor_n = 0
        for stub in stubs:
            if stub["ip"] == ip and patch_xor_stub(buf, stub, new_ip):
                xor_n += 1
        total = ascii_n + xor_contig + xor_n
        if total:
            count += total
            parts = []
            if ascii_n:
                parts.append(f"ascii:{ascii_n}")
            if xor_n:
                parts.append(f"xor-stub:{xor_n}")
            if xor_contig:
                parts.append(f"xor-bytes:{xor_contig}")
            replaced.append(f"{ip}({','.join(parts)})")
    already = new_ip in present and count == 0
    return {
        "data": bytes(buf),
        "count": count,
        "replaced": replaced,
        "already": already,
        "ascii_ips": ascii_ips,
        "xor_ips": xor_ips,
        "found": sorted(present),
    }


def patch_file(path: str, new_ip: str, old_ip: str = "") -> dict:
    with open(path, "rb") as handle:
        original = handle.read()
    result = patch_library(original, new_ip, old_ip)
    if result["count"]:
        with open(path, "wb") as handle:
            handle.write(result["data"])
    payload = {k: result[k] for k in ("count", "replaced", "already", "ascii_ips", "xor_ips", "found")}
    payload["path"] = path
    payload["new_ip"] = new_ip
    return payload


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Patch IPv4 host in a native .so")
    parser.add_argument("--so", required=True)
    parser.add_argument("--new-ip", default="")
    parser.add_argument("--old-ip", default="")
    parser.add_argument("--inspect", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.inspect or not args.new_ip:
            info = inspect_library(open(args.so, "rb").read())
            info["path"] = args.so
            print(json.dumps(info, ensure_ascii=False))
            return 0
        print(json.dumps(patch_file(args.so, args.new_ip, args.old_ip), ensure_ascii=False))
        return 0
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc)}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
