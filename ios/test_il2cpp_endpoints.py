import struct
import unittest
from il2cpp_endpoints import literals, replace_hosts


def metadata(values, version=24):
    table=32
    pool=table+8*len(values)
    data=b"".join(values)
    result=bytearray(struct.pack("<6I",0xFAB11BAF,version,table,8*len(values),pool,len(data))+b"HEADER!!")
    index=0
    for value in values:
        result.extend(struct.pack("<II",len(value),index));index+=len(value)
    return bytes(result)+data+b"OTHER_METADATA_TABLES_UNCHANGED"


class EndpointTests(unittest.TestCase):
    def test_variable_lengths(self):
        for ip in ("1.1.1.1","84.21.173.237","192.168.100.100"):
            original=metadata([b"46.101.200.35",b"fra02.bolt.bolt-api.com",b"127.0.0.1",b"2.5.29.17","Пример".encode()])
            modified,report=replace_hosts(original,"46.101.200.35; fra02.bolt.bolt-api.com",ip)
            _,values=literals(modified)
            self.assertEqual(values[:2],[ip.encode(),ip.encode()])
            self.assertEqual(values[2:],literals(original)[1][2:])
            self.assertEqual(report["matched_literals"],2)
            restored=bytearray(modified[:len(original)])
            restored[16:24]=original[16:24]
            for e in report["edits"]:
                p=e["table_offset"];restored[p:p+8]=original[p:p+8]
            self.assertEqual(bytes(restored),original)

    def test_shared_substring_unchanged(self):
        original=bytearray(metadata([b"host.example",b"unused"]))
        struct.pack_into("<II",original,40,7,5)
        modified,_=replace_hosts(bytes(original),"host.example","84.21.173.237")
        self.assertEqual(literals(modified)[1][1],b"example")

    def test_duplicate_literals(self):
        original=metadata([b"api.example",b"api.example"])
        modified,r=replace_hosts(original,"api.example","84.21.173.237")
        self.assertEqual(r["matched_literals"],2)
        self.assertEqual(literals(modified)[1],[b"84.21.173.237"]*2)

    def test_missing_endpoint(self):
        with self.assertRaisesRegex(ValueError,"not found"):
            replace_hosts(metadata([b"api.example"]),"api.example;missing.example","84.21.173.237")

    def test_invalid_destination(self):
        for ip in ("999.1.2.3","0.0.0.0","224.1.2.3","255.255.255.255","host.example","::1",""):
            with self.subTest(ip=ip),self.assertRaises(ValueError):
                replace_hosts(metadata([b"api.example"]),"api.example",ip)

    def test_bad_original_host(self):
        for host in ("","https://api.example","api.example:443"):
            with self.assertRaises(ValueError):
                replace_hosts(metadata([b"api.example"]),host,"84.21.173.237")

    def test_unsupported_version(self):
        with self.assertRaises(ValueError):
            replace_hosts(metadata([b"api.example"],99),"api.example","84.21.173.237")

    def test_bad_offsets(self):
        for field,value in ((8,0),(12,7),(16,0xffffffff),(20,0xffffffff)):
            data=bytearray(metadata([b"api.example"]))
            struct.pack_into("<I",data,field,value)
            with self.assertRaises(ValueError):literals(data)

    def test_bad_literal_range(self):
        data=bytearray(metadata([b"api.example"]))
        struct.pack_into("<I",data,32,0xffffffff)
        with self.assertRaises(ValueError):literals(data)


if __name__=="__main__":unittest.main(verbosity=2)
