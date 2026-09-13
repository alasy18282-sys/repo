import io
import json
import plistlib
import stat
import struct
import tempfile
import shutil
import uuid
import unittest
import zipfile
from pathlib import Path
import ipa_tool as ipa


def binary(cryptid=0):
    return struct.pack("<8I",0xfeedfacf,0x100000c,0,2,1,24,0,0)+struct.pack("<6I",0x2c,24,0,0,cryptid,0)


class IpaTests(unittest.TestCase):
    def setUp(self):
        self.base=Path(__file__).resolve().parent.parent/"test_out/ipa-support/unit-fixtures"
        self.base.mkdir(parents=True,exist_ok=True)
        self.root=self.base/uuid.uuid4().hex
        self.root.mkdir()
        self.source=self.root/"[input] app.ipa"
        self.out=self.root/"output.ipa"
        self.make()

    def tearDown(self):
        if not self.root.resolve().is_relative_to(self.base.resolve()):raise ValueError("Invalid test cleanup path")
        shutil.rmtree(self.root)

    def make(self,cryptid=0,extra=None,fmt=plistlib.FMT_BINARY):
        info={"CFBundleExecutable":"app","CFBundleIdentifier":"com.example.app","CFBundleDisplayName":"Old",
              "CFBundleShortVersionString":"1.0","CFBundleVersion":"2","MinimumOSVersion":"13.0",
              "CFBundleURLTypes":[{"CFBundleURLSchemes":["old.google","keep.scheme"]}]}
        with zipfile.ZipFile(self.source,"w") as z:
            z.writestr("Payload/Demo.app/Info.plist",plistlib.dumps(info,fmt=fmt))
            item=zipfile.ZipInfo("Payload/Demo.app/app")
            item.external_attr=(stat.S_IFREG|0o755)<<16
            z.writestr(item,binary(cryptid))
            z.writestr("Payload/Demo.app/data.bin",b"HOST_ONE unchanged bytes")
            z.writestr("Payload/Demo.app/_CodeSignature/CodeResources",b"old signature")
            z.writestr("Payload/Demo.app/embedded.mobileprovision",b"old profile")
            for name,data in (extra or {}).items(): z.writestr(name,data)

    def test_inspection(self):
        r=ipa.inspect_ipa(self.source)
        self.assertEqual(r["build"],"2")
        self.assertEqual(r["binaries"][0]["slices"][0]["architecture"],"arm64")
        self.assertFalse(r["encrypted"])

    def test_build_and_verification(self):
        original=ipa.digest(self.source)
        r=ipa.build_unsigned(self.source,self.out,{"IpaBundle":"com.example.new","IpaLabel":"Новое"})
        self.assertEqual(r["status"],"unsigned_requires_resigning")
        self.assertEqual(r["output_display_name"],"Новое")
        self.assertEqual(ipa.digest(self.source),original)
        with zipfile.ZipFile(self.out) as z:
            self.assertTrue(z.read("Payload/Demo.app/Info.plist").startswith(b"bplist"))
            self.assertEqual(z.getinfo("Payload/Demo.app/app").external_attr>>16,stat.S_IFREG|0o755)
            self.assertFalse(any("_CodeSignature" in n or "mobileprovision" in n for n in z.namelist()))
        ipa.verify_output(self.out,r["entries"])

    def test_xml_plist(self):
        self.make(fmt=plistlib.FMT_XML)
        ipa.build_unsigned(self.source,self.out,{"IpaLabel":"Changed"})
        with zipfile.ZipFile(self.out) as z:self.assertTrue(z.read("Payload/Demo.app/Info.plist").startswith(b"<?xml"))

    def test_extract(self):
        dst=self.root/"extracted"
        ipa.extract(self.source,dst)
        self.assertEqual((dst/"Payload/Demo.app/data.bin").read_bytes(),b"HOST_ONE unchanged bytes")
        with self.assertRaises(ValueError):ipa.extract(self.source,dst)

    def test_encrypted_guard(self):
        self.make(cryptid=1)
        self.assertTrue(ipa.inspect_ipa(self.source)["encrypted"])
        with self.assertRaisesRegex(ValueError,"Encrypted"):ipa.build_unsigned(self.source,self.out,{})

    def test_existing_output_and_source_guard(self):
        with self.assertRaises(ValueError):ipa.build_unsigned(self.source,self.source,{})
        self.out.write_bytes(b"preserve")
        with self.assertRaises(ValueError):ipa.build_unsigned(self.source,self.out,{})
        self.assertEqual(self.out.read_bytes(),b"preserve")

    def test_bad_bundle_version(self):
        for c in ({"IpaBundle":"bad id"},{"IpaBuild":"1..2"},{"IpaVersion":"abc"}):
            with self.assertRaises(ValueError):ipa.build_unsigned(self.source,self.out,c)

    def test_binary_patch(self):
        plan=self.root/"plan.json"
        plan.write_text(json.dumps({"patches":[{"path":"Payload/Demo.app/data.bin",
            "find_hex":b"HOST_ONE".hex(),"replace_hex":b"HOST_TWO".hex(),"expected_matches":1}]}))
        r=ipa.build_unsigned(self.source,self.out,{"IpaPatchPlan":str(plan)})
        with zipfile.ZipFile(self.out) as z:self.assertEqual(z.read("Payload/Demo.app/data.bin"),b"HOST_TWO unchanged bytes")
        self.assertEqual(r["changes"][0]["offsets"],[0])

    def test_patch_count_and_length_guards(self):
        for after,count in ((b"x",1),(b"HOST_TWO",2)):
            plan=self.root/"plan.json"
            plan.write_text(json.dumps({"patches":[{"path":"Payload/Demo.app/data.bin",
                "find_hex":b"HOST_ONE".hex(),"replace_hex":after.hex(),"expected_matches":count}]}))
            with self.assertRaises(ValueError):ipa.build_unsigned(self.source,self.out,{"IpaPatchPlan":str(plan)})

    def test_firebase(self):
        old=plistlib.dumps({"REVERSED_CLIENT_ID":"old.google"})
        self.make(extra={"Payload/Demo.app/GoogleService-Info.plist":old,
                         "Payload/Demo.app/Frameworks/Test.framework/GoogleService-Info.plist":old})
        new=self.root/"GoogleService-Info.plist"
        new.write_bytes(plistlib.dumps({"GOOGLE_APP_ID":"fixture","BUNDLE_ID":"com.example.app",
                                       "CLIENT_ID":"fixture","REVERSED_CLIENT_ID":"new.google"}))
        ipa.build_unsigned(self.source,self.out,{"IpaGooglePlist":str(new)})
        with zipfile.ZipFile(self.out) as z:
            for n in z.namelist():
                if n.endswith("GoogleService-Info.plist"):self.assertEqual(z.read(n),new.read_bytes())
            info=plistlib.loads(z.read("Payload/Demo.app/Info.plist"))
            schemes=[s for x in info["CFBundleURLTypes"] for s in x["CFBundleURLSchemes"]]
            self.assertIn("keep.scheme",schemes);self.assertIn("new.google",schemes);self.assertNotIn("old.google",schemes)

    def test_firebase_wrong_bundle(self):
        p=self.root/"firebase.plist"
        p.write_bytes(plistlib.dumps({"GOOGLE_APP_ID":"fixture","BUNDLE_ID":"com.other",
                                    "CLIENT_ID":"fixture","REVERSED_CLIENT_ID":"new.google"}))
        with self.assertRaisesRegex(ValueError,"BUNDLE_ID"):ipa.build_unsigned(self.source,self.out,{"IpaGooglePlist":str(p)})

    def test_unsafe_zip_paths(self):
        with self.assertRaises(ValueError):ipa.valid_name("Payload\\x")
        for name in ("../outside","/outside","Payload/x/../../outside","C:/outside","Payload/CON","Payload/x."):
            with self.subTest(name=name):
                self.make(extra={name:b"x"})
                with self.assertRaises(ValueError):ipa.inspect_ipa(self.source)

    def test_case_collision(self):
        self.make(extra={"Payload/Demo.app/APP":b"duplicate"})
        with self.assertRaisesRegex(ValueError,"colliding"):ipa.inspect_ipa(self.source)

    def test_symlink(self):
        with zipfile.ZipFile(self.source,"a") as z:
            i=zipfile.ZipInfo("Payload/Demo.app/link");i.external_attr=(stat.S_IFLNK|0o777)<<16
            z.writestr(i,b"../../outside")
        with self.assertRaisesRegex(ValueError,"Symlink"):ipa.inspect_ipa(self.source)

    def test_prefix_collision(self):
        self.make(extra={"Payload/Demo.app/data.bin/child":b"x"})
        with self.assertRaisesRegex(ValueError,"collision"):ipa.inspect_ipa(self.source)

    def test_fat_macho(self):
        b=binary()
        header=struct.pack(">II5I",0xcafebabe,1,0x100000c,0,32,len(b),0)+b"\0"*4+b
        self.assertEqual(ipa.macho(io.BytesIO(header),len(header))[0]["architecture"],"arm64")

    def test_malformed_macho(self):
        b=bytearray(binary());struct.pack_into("<I",b,36,0)
        with self.assertRaises(ValueError):ipa.macho(io.BytesIO(b),len(b))

    def test_multiple_apps(self):
        self.make(extra={"Payload/Other.app/Info.plist":plistlib.dumps({})})
        with self.assertRaisesRegex(ValueError,"exactly one"):ipa.inspect_ipa(self.source)

    def test_extension_bundle_guard(self):
        self.make(extra={"Payload/Demo.app/PlugIns/Ext.appex/Info.plist":plistlib.dumps({})})
        with self.assertRaisesRegex(ValueError,"extensions"):ipa.build_unsigned(self.source,self.out,{"IpaBundle":"com.example.new"})


if __name__=="__main__":unittest.main(verbosity=2)
