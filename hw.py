#!/usr/bin/env python3
"""hw.py - hardware.json (schema 1) from the raw command outputs that the info stage keeps in <result>/hw/.

    python3 -I hw.py DIR          print hardware.json for the folder DIR (normally <result>/hw)

Standard library only, Python 3.8+. Every key of the schema is always present; a value that is not in the files is
null (or [] / {}). Nothing here raises on odd input: a part that cannot be parsed stays null and gets a line in
"unavailable". No serial numbers, asset tags, UUIDs, host names, IP or MAC addresses are read or written.

Schema 1 (see docs/reading-results.md, "Bare metal"):
  cpu      vendor, model, family, model_id, stepping (strings: ARM steppings look like r3p1; on ARM with cpu-id.txt
           family is the MIDR implementer "0x48", model_id the part "0xd01", and a model lscpu does not name comes
           from the part: "Kunpeng-920 (TSV110)", else "HiSilicon part 0xd0f"; without cpu-id.txt it is
           "HiSilicon (model not reported, SVE2)", never "-"), microcode, sockets,
           cores_per_socket, threads_per_core, numa_nodes (int), mhz_min, mhz_max (float), cache {l1d l1i l2 l3}
  freq     driver, governor, min_khz, max_khz, scaling_min_khz, scaling_max_khz, turbo ("on"/"off"), smt,
           cpuidle_driver, cpuidle_governor
  system   sys_vendor, product_name, product_version, board_vendor, board_name, board_version, bios_vendor,
           bios_version, bios_date, bios_release, bmc {firmware, manufacturer}
  memory   slots, populated, dimms [{locator size_mb type speed_mts configured_mts manufacturer part}],
           configured_speeds {"5600": 16}, source ("dmidecode" / "edac")
  nics     [{name state speed_mbps mtu pci model driver driver_version firmware offloads {feature: "on"}}]
  disks    [{name model firmware size tran rota}]
  nvme     [{ctrl model firmware}], nvme_models {"PM9A3": 4}
  bmc      power_w, temperatures {sensor: C}, fans {sensor: RPM}
  unavailable  ["dmidecode -t memory: needs root or sudo -n", ...]
"""
import collections
import glob
import json
import os
import re
import sys

SCHEMA = 1


def skeleton():
    """hardware.json with every key and no values."""
    return collections.OrderedDict([
        ("schema", SCHEMA),
        ("cpu", collections.OrderedDict([
            ("vendor", None), ("model", None), ("family", None), ("model_id", None), ("stepping", None),
            ("microcode", None), ("sockets", None), ("cores_per_socket", None), ("threads_per_core", None),
            ("numa_nodes", None), ("mhz_min", None), ("mhz_max", None),
            ("cache", collections.OrderedDict([("l1d", None), ("l1i", None), ("l2", None), ("l3", None)]))])),
        ("freq", collections.OrderedDict([
            ("driver", None), ("governor", None), ("min_khz", None), ("max_khz", None), ("scaling_min_khz", None),
            ("scaling_max_khz", None), ("turbo", None), ("smt", None), ("cpuidle_driver", None),
            ("cpuidle_governor", None)])),
        ("system", collections.OrderedDict([
            ("sys_vendor", None), ("product_name", None), ("product_version", None), ("board_vendor", None),
            ("board_name", None), ("board_version", None), ("bios_vendor", None), ("bios_version", None),
            ("bios_date", None), ("bios_release", None),
            ("bmc", collections.OrderedDict([("firmware", None), ("manufacturer", None)]))])),
        ("memory", collections.OrderedDict([
            ("slots", None), ("populated", None), ("dimms", []), ("configured_speeds", {}), ("source", None)])),
        ("nics", []),
        ("disks", []),
        ("nvme", []),
        ("nvme_models", {}),
        ("bmc", collections.OrderedDict([("power_w", None), ("temperatures", {}), ("fans", {})])),
        ("unavailable", []),
    ])


# ---------------------------------------------------------------- small helpers

def read(d, name):
    """Text of d/name, '' when the file is missing or unreadable."""
    try:
        with open(os.path.join(d, name), encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def clean(v):
    """A value as written by the tools -> stripped string, None for empty and the usual placeholders."""
    if v is None:
        return None
    v = str(v).strip()
    if v == "" or v.lower() in ("n/a", "not specified", "unknown", "none", "to be filled by o.e.m.",
                                 "default string", "not provided", "no module installed"):
        return None
    return v


def to_int(v):
    m = re.match(r"^\s*(-?\d+)", str(v or ""))
    return int(m.group(1)) if m else None


def to_float(v):
    m = re.match(r"^\s*(-?\d+(?:[.,]\d+)?)", str(v or ""))
    return float(m.group(1).replace(",", ".")) if m else None


def number(v):
    """int when whole, else float (a reading such as 24 degrees or 250.5 W)."""
    f = to_float(v)
    if f is None:
        return None
    return int(f) if f == int(f) else f


def kv(text, sep):
    """'key<sep>value' lines -> {key: value}; the first occurrence of a key wins (lscpu repeats keys per cluster)."""
    out = {}
    for line in text.splitlines():
        if sep not in line:
            continue
        k, v = line.split(sep, 1)
        k = k.strip()
        if k and k not in out:
            out[k] = v.strip()
    return out


def sections(text):
    """'--- name' sections of a net-<if>.txt -> {'': head lines, name: lines}."""
    out = {"": []}
    cur = ""
    for line in text.splitlines():
        if line.startswith("--- "):
            cur = line[4:].strip()
            out.setdefault(cur, [])
        else:
            out[cur].append(line)
    return out


# ---------------------------------------------------------------- one parser per part

# ARM CPUs say what they are only through the MIDR register (implementer, variant, part, revision); /proc/cpuinfo on
# arm64 has no "model name", and lscpu names only the parts in its own table (older util-linux prints "Model name: -"
# for a HiSilicon Kunpeng 920, for example). These tables name the parts whose numbers are certain (Linux
# arch/arm64/include/asm/cputype.h, util-linux lscpu-arm.c); the names of Arm's own cores are spelled as lscpu spells
# them, so a VM whose lscpu knows the part and one whose lscpu does not end up with the same cpu.model.
# AWS Graviton2/3/4 are Arm Neoverse N1/V1/V2 cores and Ampere Altra is Neoverse N1: they come out of the Arm table.
ARM_IMPLEMENTERS = {
    0x41: "ARM", 0x42: "Broadcom", 0x43: "Cavium", 0x46: "Fujitsu", 0x48: "HiSilicon", 0x4e: "NVIDIA",
    0x50: "APM", 0x51: "Qualcomm", 0x61: "Apple", 0xc0: "Ampere",
}
ARM_PARTS = {
    (0x41, 0xd03): "Cortex-A53", (0x41, 0xd07): "Cortex-A57", (0x41, 0xd08): "Cortex-A72",
    (0x41, 0xd0b): "Cortex-A76", (0x41, 0xd0c): "Neoverse-N1", (0x41, 0xd40): "Neoverse-V1",
    (0x41, 0xd49): "Neoverse-N2", (0x41, 0xd4f): "Neoverse-V2",
    (0x48, 0xd01): "Kunpeng-920 (TSV110)",
    (0xc0, 0xac3): "Ampere-1", (0xc0, 0xac4): "Ampere-1a",
}


def hexnum(v):
    """'0x48' / '72' / '0x00000000481fd010' -> int, None when it is not a number."""
    try:
        return int(str(v).strip(), 0)
    except (TypeError, ValueError):
        return None


def arm_id(text):
    """cpu-id.txt (CPU implementer/variant/part/revision of cpu0 from /proc/cpuinfo, and midr_el1 from /sys) ->
    (implementer, variant, part, revision) as ints, or None when the file has no ARM id (x86, old result folder)."""
    t = kv(text, "=")
    f = [hexnum(t.get(k)) for k in ("implementer", "variant", "part", "revision")]
    if f[0] is None or f[2] is None:
        midr = hexnum(t.get("midr_el1"))
        if not midr:
            return None
        f = [(midr >> 24) & 0xff, (midr >> 20) & 0xf, (midr >> 4) & 0xfff, midr & 0xf]
    return tuple(f)


def parse_cpu(d, hw):
    c = hw["cpu"]
    t = kv(read(d, "lscpu.txt"), ":")
    c["vendor"] = clean(t.get("Vendor ID"))
    c["model"] = clean(t.get("Model name"))
    c["family"] = clean(t.get("CPU family"))
    c["model_id"] = clean(t.get("Model"))
    c["stepping"] = clean(t.get("Stepping"))
    dash = c["model"] == "-"
    if dash:
        c["model"] = None
    mid = arm_id(read(d, "cpu-id.txt"))
    if mid and not c["family"]:   # "CPU family" is always there on x86: its fields stay as lscpu prints them
        impl, variant, part, rev = mid
        c["vendor"] = c["vendor"] if c["vendor"] not in (None, "-") else ARM_IMPLEMENTERS.get(impl)
        if not c["model"]:
            c["model"] = ARM_PARTS.get((impl, part)) or "%s part 0x%03x" % (
                ARM_IMPLEMENTERS.get(impl) or c["vendor"] or "implementer 0x%02x" % impl, part)
        # the MIDR fields in the places x86 has them: family = implementer, model_id = part, stepping = rVpR
        c["family"] = "0x%02x" % impl
        c["model_id"] = "0x%03x" % part
        if variant is not None and rev is not None:
            c["stepping"] = "r%dp%d" % (variant, rev)
    elif not c["model"] and (dash or (clean(t.get("Architecture")) or "").startswith(("aarch64", "arm"))):
        # ARM without the MIDR (result folders of vmbench 0.2.3 and older): say so instead of "-", with the widest
        # vector extension from the flags, which at least tells a core with SVE2 from one without
        flags = (t.get("Flags") or "").split()
        ext = ", SVE2" if "sve2" in flags else ", SVE" if "sve" in flags else ""
        c["model"] = "%s (model not reported%s)" % (c["vendor"] if c["vendor"] not in (None, "-") else "ARM", ext)
    c["sockets"] = to_int(t.get("Socket(s)"))
    # ARM lscpu often says "Core(s) per cluster" and "Cluster(s)" instead of sockets
    c["cores_per_socket"] = to_int(t.get("Core(s) per socket") or t.get("Core(s) per cluster"))
    c["threads_per_core"] = to_int(t.get("Thread(s) per core"))
    c["numa_nodes"] = to_int(t.get("NUMA node(s)"))
    c["mhz_min"] = to_float(t.get("CPU min MHz"))
    c["mhz_max"] = to_float(t.get("CPU max MHz"))
    for key, names in (("l1d", ("L1d cache", "L1d")), ("l1i", ("L1i cache", "L1i")),
                       ("l2", ("L2 cache", "L2")), ("l3", ("L3 cache", "L3"))):
        c["cache"][key] = next((clean(t[n]) for n in names if clean(t.get(n))), None)
    m = kv(read(d, "cpuinfo-microcode.txt"), "=")
    c["microcode"] = clean(m.get("proc")) or clean(m.get("sysfs"))


def parse_freq(d, hw):
    f = hw["freq"]
    t = kv(read(d, "cpufreq.txt"), "=")
    f["driver"] = clean(t.get("scaling_driver"))
    f["governor"] = clean(t.get("scaling_governor"))
    f["min_khz"] = to_int(t.get("cpuinfo_min_freq"))
    f["max_khz"] = to_int(t.get("cpuinfo_max_freq"))
    f["scaling_min_khz"] = to_int(t.get("scaling_min_freq"))
    f["scaling_max_khz"] = to_int(t.get("scaling_max_freq"))
    no_turbo, boost = clean(t.get("no_turbo")), clean(t.get("boost"))
    if no_turbo in ("0", "1"):
        f["turbo"] = "off" if no_turbo == "1" else "on"
    elif boost in ("0", "1"):
        f["turbo"] = "on" if boost == "1" else "off"
    f["smt"] = clean(t.get("smt"))
    f["cpuidle_driver"] = clean(t.get("cpuidle_driver"))
    f["cpuidle_governor"] = clean(t.get("cpuidle_governor"))


def parse_system(d, hw):
    s = hw["system"]
    t = kv(read(d, "dmi-id.txt"), ":")
    for k in ("sys_vendor", "product_name", "product_version", "board_vendor", "board_name", "board_version",
              "bios_vendor", "bios_version", "bios_date", "bios_release"):
        s[k] = clean(t.get(k))
    # dmidecode -t bios fills what /sys/class/dmi/id did not have
    b = kv(read(d, "dmidecode-bios.txt"), ":")
    for k, name in (("bios_vendor", "Vendor"), ("bios_version", "Version"), ("bios_date", "Release Date"),
                    ("bios_release", "BIOS Revision")):
        if s[k] is None:
            s[k] = clean(b.get(name))
    mc = kv(read(d, "ipmitool-mc-info.txt"), ":")
    s["bmc"]["firmware"] = clean(mc.get("Firmware Revision"))
    s["bmc"]["manufacturer"] = clean(mc.get("Manufacturer Name"))


def size_mb(v):
    m = re.match(r"^\s*(\d+(?:\.\d+)?)\s*([KMGT]i?B)\b", v or "", re.I)
    if not m:
        return None
    mult = {"K": 1 / 1024, "M": 1, "G": 1024, "T": 1024 * 1024}[m.group(2)[0].upper()]
    return int(round(float(m.group(1)) * mult))


def parse_memory(d, hw):
    mem = hw["memory"]
    text = read(d, "dmidecode-memory.txt")
    if text.strip():
        blocks, cur = [], None
        for line in text.splitlines():
            if line.strip() == "Memory Device":
                cur = {}
                blocks.append(cur)
            elif cur is not None and ":" in line and line.startswith(("\t", " ")):
                k, v = line.split(":", 1)
                k = k.strip()
                if k not in cur:   # "Locator" before "Bank Locator"; keep the first value of a key
                    cur[k] = v.strip()
        if not blocks:
            return
        mem["source"] = "dmidecode"
        mem["slots"] = len(blocks)
        speeds = collections.Counter()
        for b in blocks:
            mb = size_mb(b.get("Size"))
            if not mb:
                continue
            conf = to_int(b.get("Configured Memory Speed") or b.get("Configured Clock Speed"))
            mem["dimms"].append(collections.OrderedDict([
                ("locator", clean(b.get("Locator"))), ("size_mb", mb), ("type", clean(b.get("Type"))),
                ("speed_mts", to_int(b.get("Speed"))), ("configured_mts", conf),
                ("manufacturer", clean(b.get("Manufacturer"))), ("part", clean(b.get("Part Number")))]))
            if conf:
                speeds[str(conf)] += 1
        mem["populated"] = len(mem["dimms"])
        mem["configured_speeds"] = dict(sorted(speeds.items(), key=lambda kv_: -int(kv_[0])))
        return
    text = read(d, "edac-dimms.txt")   # name|label|size MB|type, one line per DIMM slot the kernel knows
    rows = [line.split("|") for line in text.splitlines() if line.count("|") >= 3]
    if rows:
        mem["source"] = "edac"
        mem["slots"] = len(rows)
        for name, label, size, typ in (r[:4] for r in rows):
            mb = to_int(size)
            if mb:
                mem["dimms"].append(collections.OrderedDict([
                    ("locator", clean(label) or clean(name)), ("size_mb", mb), ("type", clean(typ)),
                    ("speed_mts", None), ("configured_mts", None), ("manufacturer", None), ("part", None)]))
        mem["populated"] = len(mem["dimms"])


def parse_nics(d, hw):
    for path in sorted(glob.glob(os.path.join(d, "net-*.txt"))):
        name = os.path.basename(path)[4:-4]
        sec = sections(read(d, os.path.basename(path)))
        head = kv("\n".join(sec.get("", [])), "=")
        info = kv("\n".join(sec.get("ethtool -i", [])), ":")
        model = None
        for line in sec.get("lspci", []):
            m = re.match(r"^\s*[0-9a-fA-F:.]+\s+[^:]+:\s*(.+)$", line)
            if m:
                model = clean(m.group(1))
                break
        offloads = collections.OrderedDict()
        for line in sec.get("ethtool -k", []):
            m = re.match(r"^\s*([a-z0-9-]+):\s*(on|off)\b(.*)$", line)
            if m and ("offload" in m.group(1) or "segmentation" in m.group(1)) and "[fixed]" not in m.group(3):
                offloads[m.group(1)] = m.group(2)
        speed = to_int(head.get("speed"))
        hw["nics"].append(collections.OrderedDict([
            ("name", name), ("state", clean(head.get("state"))),
            ("speed_mbps", speed if speed is not None and speed > 0 else None), ("mtu", to_int(head.get("mtu"))),
            ("pci", clean(info.get("bus-info")) or clean(head.get("pci"))), ("model", model),
            ("driver", clean(info.get("driver"))), ("driver_version", clean(info.get("version"))),
            ("firmware", clean(info.get("firmware-version"))), ("offloads", offloads)]))


def parse_disks(d, hw):
    for line in read(d, "lsblk.txt").splitlines():
        if "=" in line:   # lsblk -P: NAME="sda" MODEL="..." REV="..." SIZE="..." TRAN="..." ROTA="..."
            t = {k: re.sub(r"\\x([0-9a-fA-F]{2})", lambda m: chr(int(m.group(1), 16)), v)   # \x22 etc.
                 for k, v in re.findall(r'([A-Z:-]+)="([^"]*)"', line)}
        else:             # plain columns; a model with spaces cannot be split reliably, keep what is there
            p = line.split()
            if not p:
                continue
            t = dict(zip(("NAME", "MODEL", "REV", "SIZE", "TRAN", "ROTA"), p))
        name = clean(t.get("NAME"))
        if not name or re.match(r"^(loop|ram|sr|zram)", name):
            continue
        hw["disks"].append(collections.OrderedDict([
            ("name", name), ("model", clean(t.get("MODEL"))), ("firmware", clean(t.get("REV"))),
            ("size", clean(t.get("SIZE"))), ("tran", clean(t.get("TRAN"))), ("rota", to_int(t.get("ROTA")))]))


def parse_nvme(d, hw):
    models = collections.Counter()
    paths = glob.glob(os.path.join(d, "nvme-*.txt"))
    def ctrl_key(p):
        n = os.path.basename(p)[5:-4]
        return (to_int(re.sub(r"^\D+", "", n)) or 0, n)
    for path in sorted(paths, key=ctrl_key):
        t = kv(read(d, os.path.basename(path)), "=")
        model = clean(t.get("model"))
        hw["nvme"].append(collections.OrderedDict([
            ("ctrl", os.path.basename(path)[5:-4]), ("model", model), ("firmware", clean(t.get("firmware")))]))
        if model:
            models[model] += 1
    hw["nvme_models"] = dict(sorted(models.items()))


def sdr(text, unit):
    """ipmitool sdr type ... lines 'name | id | ok | entity | 24 degrees C' -> {name: number}."""
    out = collections.OrderedDict()
    for line in text.splitlines():
        p = [x.strip() for x in line.split("|")]
        if len(p) >= 5 and re.search(unit, p[-1], re.I):
            v = number(p[-1])
            if v is not None:
                out[p[0]] = v
    return out


def parse_bmc(d, hw):
    b = hw["bmc"]
    m = re.search(r"Instantaneous power reading:\s*([\d.]+)\s*Watts", read(d, "ipmi-dcmi-power.txt"))
    b["power_w"] = number(m.group(1)) if m else None
    b["temperatures"] = sdr(read(d, "ipmi-sdr-temp.txt"), r"degrees")
    b["fans"] = sdr(read(d, "ipmi-sdr-fan.txt"), r"RPM")


PARSERS = (("cpu", parse_cpu), ("freq", parse_freq), ("system", parse_system), ("memory", parse_memory),
           ("nics", parse_nics), ("disks", parse_disks), ("nvme", parse_nvme), ("bmc", parse_bmc))


def build(d):
    """hardware.json (an OrderedDict) from the raw files in folder d."""
    hw = skeleton()
    for line in read(d, "unavailable.txt").splitlines():
        if line.strip():
            hw["unavailable"].append(line.strip())
    for part, fn in PARSERS:
        try:
            fn(d, hw)
        except Exception as e:  # noqa: BLE001 - a parser bug must not lose the rest of the file
            fresh = skeleton()
            hw[part] = fresh[part]
            if part == "nvme":
                hw["nvme_models"] = fresh["nvme_models"]
            hw["unavailable"].append("hw.py: %s could not be parsed (%s)" % (part, type(e).__name__))
    return hw


def main(argv):
    if len(argv) != 2 or argv[1] in ("-h", "--help"):
        print(__doc__.split("\n\n")[1].strip(), file=sys.stderr)
        return 0 if len(argv) == 2 else 2
    d = argv[1]
    if not os.path.isdir(d):
        print("hw.py: %s is not a folder (expected <result>/hw)" % d, file=sys.stderr)
        return 2
    json.dump(build(d), sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
