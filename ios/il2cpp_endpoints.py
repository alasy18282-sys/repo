"""Replace explicitly selected IL2CPP UTF-8 string literals, not arbitrary bytes."""
import ipaddress
import re
import struct


def literals(data):
    if len(data) < 24:
        raise ValueError("Truncated IL2CPP metadata")
    magic, version, table, table_size, pool, pool_size = struct.unpack_from("<6I", data)
    if magic != 0xFAB11BAF or version not in (24, 27, 29):
        raise ValueError("Unsupported IL2CPP metadata header/version")
    if (table < 24 or table_size % 8 or table + table_size > len(data) or
            pool < table + table_size or pool + pool_size > len(data)):
        raise ValueError("Invalid IL2CPP string table bounds")
    entries = []
    for i in range(table_size // 8):
        length, index = struct.unpack_from("<II", data, table + i * 8)
        if index + length > pool_size:
            raise ValueError("IL2CPP string literal outside pool")
        entries.append(data[pool + index:pool + index + length])
    return (version, table, pool, pool_size), entries


def replace_hosts(data, old_hosts, new_ip):
    try:
        address = ipaddress.IPv4Address(new_ip)
    except ipaddress.AddressValueError as exc:
        raise ValueError("IPA server IP must be a valid IPv4 address") from exc
    if address.is_unspecified or address.is_multicast or str(address) == "255.255.255.255":
        raise ValueError("IPA server IP must be a unicast destination")
    hosts = list(dict.fromkeys(x.strip() for x in re.split(r"[;,\s]+", old_hosts) if x.strip()))
    if not hosts:
        raise ValueError("Specify the original IPA server IP/domain to replace")
    try:
        wanted = {h.encode("ascii"): h for h in hosts}
    except UnicodeEncodeError as exc:
        raise ValueError("Original endpoints must be ASCII IPs/domains") from exc
    if any(not re.fullmatch(r"[A-Za-z0-9.-]+", h) for h in hosts):
        raise ValueError("Original endpoint must be a hostname/IP without port or URL")
    (version, table, pool, pool_size), before = literals(data)
    selected = [i for i, value in enumerate(before) if value in wanted]
    found = {before[i] for i in selected}
    missing = set(wanted) - found
    if missing:
        raise ValueError("Original endpoint literals not found: " + ", ".join(sorted(x.decode() for x in missing)))
    replacement = str(address).encode("ascii")
    # Relocate the complete literal pool to EOF. This preserves all other
    # metadata tables and accommodates any valid IPv4 length and shared strings.
    new_pool = (len(data) + 3) & ~3
    pool_bytes = data[pool:pool + pool_size] + replacement
    if new_pool + len(pool_bytes) >= 0x80000000:
        raise ValueError("Relocated metadata exceeds signed 32-bit offset range")
    modified = bytearray(data)
    modified.extend(b"\0" * (new_pool - len(modified)))
    modified.extend(pool_bytes)
    struct.pack_into("<II", modified, 16, new_pool, len(pool_bytes))
    edits = []
    for i in selected:
        entry_offset = table + i * 8
        old_length, old_index = struct.unpack_from("<II", data, entry_offset)
        struct.pack_into("<II", modified, entry_offset, len(replacement), pool_size)
        edits.append({"literal_index": i, "table_offset": entry_offset,
                      "old_data_offset": pool + old_index, "old_length": old_length,
                      "new_data_offset": new_pool + pool_size, "new_length": len(replacement),
                      "before": before[i].decode("ascii"), "after": str(address)})
    _, after = literals(modified)
    selected_set = set(selected)
    for i, value in enumerate(before):
        expected = replacement if i in selected_set else value
        if after[i] != expected:
            raise ValueError("IL2CPP literal roundtrip failed at index " + str(i))
    return bytes(modified), {
        "action": "IL2CPP server endpoint replacement",
        "metadata_version": version, "new_ip": str(address),
        "old_pool_offset": pool, "new_pool_offset": new_pool,
        "matched_literals": len(selected), "edits": edits,
        "verification": "Every string literal reread; all unrelated literals byte-identical"}
