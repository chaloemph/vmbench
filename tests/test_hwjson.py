"""Tests for hw.py: hardware.json (schema 1) from the raw command outputs the info stage keeps in <result>/hw/.

Three synthetic folders under tests/fixtures/hw/ (an x86 bare-metal server, an ARM VM, an x86 VM; made up, no serial
numbers) must give exactly the JSON next to them, and odd or missing input must never raise. Standard library only.
"""
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
FIX = os.path.join(HERE, "fixtures", "hw")
HW = os.path.join(ROOT, "hw.py")

spec = importlib.util.spec_from_file_location("hw", HW)
hw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hw)


def keys(obj, prefix=""):
    """The set of dotted key paths of the dicts in obj (lists are not entered)."""
    out = set()
    if isinstance(obj, dict):
        for k, v in obj.items():
            out.add(prefix + k)
            if isinstance(v, dict) and k not in ("configured_speeds", "nvme_models", "temperatures", "fans", "offloads"):
                out |= keys(v, prefix + k + ".")
    return out


def run_hw(*args):
    return subprocess.run([sys.executable, "-I", "-B", HW, *args], capture_output=True, text=True)


class Fixtures(unittest.TestCase):
    def test_each_fixture_gives_the_expected_json(self):
        for name in ("x86-baremetal", "arm-vm", "x86-vm"):
            with self.subTest(name):
                p = run_hw(os.path.join(FIX, name))
                self.assertEqual(p.returncode, 0, p.stderr)
                with open(os.path.join(FIX, name + ".json"), encoding="utf-8") as f:
                    self.assertEqual(json.loads(p.stdout), json.load(f))

    def test_every_key_of_the_schema_is_always_there(self):
        want = keys(hw.skeleton())
        for name in ("x86-baremetal", "arm-vm", "x86-vm", "arm-hisilicon-vm", "arm-kunpeng920-oldlscpu", "arm-n1-oldlscpu", "arm-unknown-part"):
            with self.subTest(name):
                self.assertEqual(keys(hw.build(os.path.join(FIX, name))), want)

    def test_bare_metal_values(self):
        d = hw.build(os.path.join(FIX, "x86-baremetal"))
        self.assertEqual(d["schema"], 1)
        self.assertEqual((d["cpu"]["stepping"], d["cpu"]["microcode"], d["cpu"]["sockets"]), ("8", "0x2b000590", 2))
        self.assertEqual(d["freq"]["turbo"], "on")
        self.assertEqual(d["system"]["bmc"], {"firmware": "7.10", "manufacturer": "Example BMC Corp"})
        self.assertEqual((d["memory"]["slots"], d["memory"]["populated"], d["memory"]["source"]), (4, 3, "dmidecode"))
        self.assertEqual(d["memory"]["configured_speeds"], {"4800": 2, "4400": 1})
        self.assertEqual(d["memory"]["dimms"][0]["part"], "EXR5-32G4800R")   # trailing blanks of dmidecode removed
        nic = {n["name"]: n for n in d["nics"]}
        self.assertIsNone(nic["eno1"]["speed_mbps"])                          # speed -1 = link down
        self.assertNotIn("l2-fwd-offload", nic["ens1f0"]["offloads"])        # [fixed] features are left out
        self.assertEqual([x["name"] for x in d["disks"]], ["nvme0n1", "nvme1n1", "sda"])   # no loop devices
        self.assertEqual([x["ctrl"] for x in d["nvme"]], ["nvme0", "nvme1", "nvme10"])   # numeric order
        self.assertEqual(d["nvme_models"], {"EXSSD PM9A3 3.84TB": 3})
        self.assertEqual(d["bmc"]["temperatures"], {"Inlet Temp": 24, "CPU1 Temp": 52})   # "No Reading" left out
        self.assertEqual(d["bmc"]["power_w"], 312)

    def test_arm_vm_and_x86_vm(self):
        a = hw.build(os.path.join(FIX, "arm-vm"))
        # lscpu of util-linux 2.38+ indents its keys under sections; ARM has clusters, no family, no sockets
        self.assertEqual((a["cpu"]["vendor"], a["cpu"]["model"], a["cpu"]["stepping"]), ("ARM", "Neoverse-N1", "r3p1"))
        self.assertIsNone(a["cpu"]["family"])
        self.assertIsNone(a["cpu"]["sockets"])
        self.assertEqual(a["cpu"]["cores_per_socket"], 8)
        self.assertEqual(a["cpu"]["cache"]["l3"], "32 MiB (1 instance)")
        self.assertIsNone(a["freq"]["driver"])
        self.assertIsNone(a["freq"]["turbo"])
        self.assertIsNone(a["memory"]["source"])
        self.assertEqual([x["name"] for x in a["disks"]], ["vda"])          # sr0 left out
        self.assertIn("dmidecode -t memory: needs root or sudo -n", a["unavailable"])
        v = hw.build(os.path.join(FIX, "x86-vm"))
        self.assertEqual(v["cpu"]["cache"]["l1d"], "32K")                    # old lscpu format
        self.assertEqual((v["memory"]["source"], v["memory"]["slots"], v["memory"]["populated"]), ("edac", 2, 1))
        self.assertEqual(v["disks"][1]["model"], 'Virtual Disk "B"')        # lsblk -P hex escapes decoded


class ArmCpuModel(unittest.TestCase):
    """ARM: the model comes from the MIDR (hw/cpu-id.txt) when lscpu does not name the CPU."""

    def cpu(self, name):
        return hw.build(os.path.join(FIX, name))["cpu"]

    def test_real_hisilicon_vm_without_midr(self):
        # lscpu.txt of a vmbench 0.2.3 run on a HiSilicon KVM guest (Ubuntu 24.04): "Model name: -", and lscpu of
        # util-linux 2.39 knows 0xd01, so this is a newer part (it has SVE2, the Kunpeng 920 has no SVE). No
        # cpu-id.txt: the part number is unknown, and the model says so instead of "-"
        c = self.cpu("arm-hisilicon-vm")
        self.assertEqual((c["vendor"], c["model"]), ("HiSilicon", "HiSilicon (model not reported, SVE2)"))
        self.assertEqual((c["family"], c["model_id"], c["stepping"]), (None, "0", "0x0"))   # as lscpu prints them
        self.assertEqual((c["sockets"], c["cores_per_socket"]), (1, 16))

    def test_hisilicon_d01_with_model_name_dash(self):
        # synthetic: util-linux older than 2.35 has no HiSilicon table and prints "-" for a Kunpeng 920 too
        c = self.cpu("arm-kunpeng920-oldlscpu")
        self.assertEqual((c["vendor"], c["model"]), ("HiSilicon", "Kunpeng-920"))
        self.assertEqual((c["family"], c["model_id"], c["stepping"]), ("0x48", "0xd01", "r1p0"))
        self.assertEqual((c["sockets"], c["cores_per_socket"]), (1, 16))   # the rest of lscpu is still read

    def test_neoverse_n1_from_midr_el1_alone(self):
        # old lscpu without a "Model name" line, /proc/cpuinfo fields missing: midr_el1 0x413fd0c1
        c = self.cpu("arm-n1-oldlscpu")
        self.assertEqual((c["vendor"], c["model"]), ("ARM", "Neoverse-N1"))
        self.assertEqual((c["family"], c["model_id"], c["stepping"]), ("0x41", "0xd0c", "r3p1"))

    def test_unknown_part_names_vendor_and_part(self):
        c = self.cpu("arm-unknown-part")
        self.assertEqual(c["model"], "HiSilicon part 0xd0f")
        self.assertEqual((c["family"], c["model_id"], c["stepping"]), ("0x48", "0xd0f", "r2p2"))

    def test_lscpu_name_wins_and_x86_is_untouched(self):
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "lscpu.txt"), "w", encoding="utf-8") as f:
                f.write("Vendor ID: ARM\nModel name: Neoverse-V2\nModel: 1\nStepping: r0p1\n")
            with open(os.path.join(d, "cpu-id.txt"), "w", encoding="utf-8") as f:
                f.write("implementer=0x41\nvariant=0x0\npart=0xd4f\nrevision=1\nmidr_el1=\n")
            c = hw.build(d)["cpu"]
            self.assertEqual((c["model"], c["model_id"], c["stepping"]), ("Neoverse-V2", "0xd4f", "r0p1"))
            # x86 with an (impossible) ARM id: "CPU family" is there, so nothing is replaced
            with open(os.path.join(d, "lscpu.txt"), "w", encoding="utf-8") as f:
                f.write("Vendor ID: GenuineIntel\nModel name: Xeon\nCPU family: 6\nModel: 143\nStepping: 8\n")
            c = hw.build(d)["cpu"]
            self.assertEqual((c["vendor"], c["model"], c["family"], c["model_id"], c["stepping"]),
                             ("GenuineIntel", "Xeon", "6", "143", "8"))

    def test_table_and_fallbacks(self):
        for impl, part, want in ((0x41, 0xd08, "Cortex-A72"), (0x41, 0xd0b, "Cortex-A76"), (0x41, 0xd40, "Neoverse-V1"),
                                 (0x41, 0xd49, "Neoverse-N2"), (0x41, 0xd4f, "Neoverse-V2"), (0xc0, 0xac3, "Ampere-1"),
                                 (0xc0, 0xac4, "Ampere-1a"), (0x41, 0xfff, "ARM part 0xfff"),
                                 (0x99, 0x123, "implementer 0x99 part 0x123")):
            with self.subTest(want), tempfile.TemporaryDirectory() as d:
                with open(os.path.join(d, "cpu-id.txt"), "w", encoding="utf-8") as f:
                    f.write("midr_el1=0x%08x\n" % (impl << 24 | 0xf << 16 | part << 4))
                self.assertEqual(hw.build(d)["cpu"]["model"], want)

    def test_no_model_and_no_id(self):
        for text, want in (("Vendor ID: HiSilicon\nModel name: -\n", "HiSilicon (model not reported)"),
                           ("Architecture: aarch64\nFlags: fp asimd sve\n", "ARM (model not reported, SVE)"),
                           ("Architecture: x86_64\nVendor ID: Stub\n", None)):
            with self.subTest(want), tempfile.TemporaryDirectory() as d:
                with open(os.path.join(d, "lscpu.txt"), "w", encoding="utf-8") as f:
                    f.write(text)
                self.assertEqual(hw.build(d)["cpu"]["model"], want)


class Robustness(unittest.TestCase):
    def test_empty_folder_gives_the_skeleton(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(hw.build(d), json.loads(json.dumps(hw.skeleton())))
            p = run_hw(d)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertEqual(json.loads(p.stdout)["cpu"]["model"], None)

    def test_garbage_never_raises(self):
        junk = "\x00\xff:::=|||--- \n" * 50 + "Memory Device\n\tSize: lots\n\tLocator:\n"
        names = ("lscpu.txt", "cpuinfo-microcode.txt", "cpu-id.txt", "cpufreq.txt", "dmi-id.txt", "dmidecode-bios.txt",
                 "dmidecode-memory.txt", "edac-dimms.txt", "ipmitool-mc-info.txt", "net-x.txt", "lsblk.txt",
                 "nvme-nvme0.txt", "ipmi-sdr-temp.txt", "ipmi-sdr-fan.txt", "ipmi-dcmi-power.txt", "unavailable.txt")
        with tempfile.TemporaryDirectory() as d:
            for n in names:
                with open(os.path.join(d, n), "w", encoding="utf-8", errors="replace") as f:
                    f.write(junk)
            out = hw.build(d)
            self.assertEqual(keys(out), keys(hw.skeleton()))
            json.dumps(out)

    def test_a_parser_bug_leaves_the_part_empty_and_says_so(self):
        orig = hw.parse_memory
        def broken(d, h):
            h["memory"]["slots"] = 99
            raise ValueError("boom")
        hw.PARSERS = tuple((p, broken if p == "memory" else f) for p, f in hw.PARSERS)
        try:
            out = hw.build(os.path.join(FIX, "x86-baremetal"))
        finally:
            hw.PARSERS = tuple((p, orig if p == "memory" else f) for p, f in hw.PARSERS)
        self.assertIsNone(out["memory"]["slots"])
        self.assertIn("hw.py: memory could not be parsed (ValueError)", out["unavailable"])
        self.assertEqual(out["cpu"]["model"], "Intel(R) Xeon(R) Gold 6430")

    def test_usage(self):
        self.assertEqual(run_hw().returncode, 2)
        self.assertEqual(run_hw("/nonexistent/hw").returncode, 2)

    def test_no_serial_numbers_in_the_fixtures_or_the_output(self):
        for name in ("x86-baremetal", "arm-vm", "x86-vm", "arm-hisilicon-vm", "arm-kunpeng920-oldlscpu", "arm-n1-oldlscpu", "arm-unknown-part"):
            text = json.dumps(hw.build(os.path.join(FIX, name))).lower()
            self.assertNotIn("serial", text)
            self.assertNotIn("uuid", text)
            for f in os.listdir(os.path.join(FIX, name)):
                with open(os.path.join(FIX, name, f), encoding="utf-8") as fh:
                    self.assertNotIn("serial", fh.read().lower(), f)


if __name__ == "__main__":
    unittest.main()
