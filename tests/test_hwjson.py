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
        for name in ("x86-baremetal", "arm-vm", "x86-vm"):
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


class Robustness(unittest.TestCase):
    def test_empty_folder_gives_the_skeleton(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertEqual(hw.build(d), json.loads(json.dumps(hw.skeleton())))
            p = run_hw(d)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertEqual(json.loads(p.stdout)["cpu"]["model"], None)

    def test_garbage_never_raises(self):
        junk = "\x00\xff:::=|||--- \n" * 50 + "Memory Device\n\tSize: lots\n\tLocator:\n"
        names = ("lscpu.txt", "cpuinfo-microcode.txt", "cpufreq.txt", "dmi-id.txt", "dmidecode-bios.txt",
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
        for name in ("x86-baremetal", "arm-vm", "x86-vm"):
            text = json.dumps(hw.build(os.path.join(FIX, name))).lower()
            self.assertNotIn("serial", text)
            self.assertNotIn("uuid", text)
            for f in os.listdir(os.path.join(FIX, name)):
                with open(os.path.join(FIX, name, f), encoding="utf-8") as fh:
                    self.assertNotIn("serial", fh.read().lower(), f)


if __name__ == "__main__":
    unittest.main()
