#!/usr/bin/env python3
"""report.py - turn run-benchmark.sh results into tables, and compare runs.

  python3 report.py show    bench-results/x86-full
  python3 report.py compare bench-results/x86-full bench-results/arm64-full   # first folder = baseline

Every command prints the tables to stdout and writes report.md + report.html:
  show     into the results folder (or --out DIR)
  compare  into ./compare-<a>-vs-<b>/ (or --out DIR)
Use --no-files for stdout only. The text is English; --lang th (or VMBENCH_LANG=th) gives Thai.
Standard library only, Python 3.8+.

Values are recomputed from results.tsv (median and CV over the rounds). Every value has a stable id such
as cpu.sysbench.prime.1t (see docs/tests.md). Result folders from before the ids (results.tsv header
"row", numeric spreadsheet rows) still load: their rows are mapped to the same ids through LEGACY below.
Run metadata comes from meta.json when the folder has one, otherwise from info.txt.
Marks:  * measured once, so its variation is unknown    ! CV of 5% or more

Compare verdicts: lower is better for ns/us/ms, error counts and packet loss; higher is better
otherwise. A difference within the larger CV of the two runs, or within 1%, is not called a win.
"""
import argparse
import collections
import csv
import html
import json
import os
import re
import statistics
import sys
import unicodedata

HIGH_CV = 5.0       # % - mark a metric as noisy from here on
MIN_DIFF = 1.0      # % - smaller differences are never called a win
HIGH_STEAL = 1.0    # % - average CPU steal worth warning about

INFO_SECTION = "info"   # key of the context section; its title comes from the catalog (section.info)
# the first part of an id is its stage; this is also the order of the sections in the tables
STAGE_SECTIONS = collections.OrderedDict([("cpu", "CPU"), ("mem", "Memory"), ("disk", "Disk"), ("pg", "PostgreSQL"),
                                          ("net", "Network"), ("web", "Web"), ("burnin", "Burn-in"),
                                          ("info", INFO_SECTION)])
# row ranges of the old numeric format, only used to place rows without a LEGACY entry in a stage
LEGACY_STAGES = [("cpu", 0, 23), ("mem", 24, 32), ("disk", 33, 46), ("pg", 47, 49),
                 ("net", 50, 54), ("web", 55, 59), ("burnin", 60, 999)]

# Old results.tsv files (header "row") name a test by spreadsheet row number and metric text. This table maps
# them to the stable ids. (row, regex for the metric text without its thread suffix, id). A thread suffix
# in the old text adds ".1t" or ".max" to the id; ids that already end in a variant are used as they are.
# The order is the order of the tables. tests/test_ids.py checks it against the table in run-benchmark.sh.
LEGACY = [
    ("7", r"sysbench cpu", "cpu.sysbench.prime"),
    ("8", r"sysbench cpu", "cpu.sysbench.prime"),
    ("10", r"7z rating", "cpu.7z.rating"),
    ("11", r"cpubench crypto/aes-gcm", "cpu.cpubench.crypto.aes-gcm"),
    ("11", r"openssl aes-256-gcm", "cpu.openssl.aes-256-gcm"),
    ("12", r"cpubench crypto/ecdsa-p256", "cpu.cpubench.crypto.ecdsa-p256"),
    ("13", r"cpubench crypto/rsa2048-sign", "cpu.cpubench.crypto.rsa2048-sign"),
    ("14", r"cpubench crypto/sha256", "cpu.cpubench.crypto.sha256"),
    ("15", r"cpubench float/fft", "cpu.cpubench.float.fft"),
    ("16", r"cpubench float/matmul", "cpu.cpubench.float.matmul"),
    ("17", r"cpubench float/nbody", "cpu.cpubench.float.nbody"),
    ("18", r"cpubench int/compress", "cpu.cpubench.int.compress"),
    ("19", r"cpubench int/decompress", "cpu.cpubench.int.decompress"),
    ("20", r"cpubench int/hashmap", "cpu.cpubench.int.hashmap"),
    ("21", r"cpubench int/json", "cpu.cpubench.int.json"),
    ("22", r"cpubench int/regex", "cpu.cpubench.int.regex"),
    ("23", r"cpubench int/sort", "cpu.cpubench.int.sort"),
    ("26", r"stream triad", "mem.stream.triad.max"),
    ("27", r"lat_mem_rd -t \d+MB", "mem.lmbench.lat-mem-rd.1t"),
    ("28", r"stream copy", "mem.stream.copy.max"),
    ("33", r"fio randwrite 4k qd32x4", "disk.fio.randwrite-4k.qd32x4"),
    ("33", r"steadystate attained \(1=yes\)", "disk.fio.randwrite-4k.steadystate"),
    ("34", r"fio randread 4k qd1 p99", "disk.fio.randread-4k.qd1.p99"),
    ("34", r"fio randread 4k qd1 p99\.9", "disk.fio.randread-4k.qd1.p999"),
    ("35", r"fio randread 4k qd32x4", "disk.fio.randread-4k.qd32x4"),
    ("36", r"fio mixed 70/30 read", "disk.fio.mixed-70-30-4k.read"),
    ("36", r"fio mixed 70/30 write", "disk.fio.mixed-70-30-4k.write"),
    ("37", r"fio seq write 1M", "disk.fio.seq-write-1m"),
    ("37", r"fio seq read 1M", "disk.fio.seq-read-1m"),
] + [("38", rf"fio randread 4k qd{q}", f"disk.fio.randread-4k.sweep-qd{q}") for q in (1, 4, 16, 32, 64, 128)] + [
    ("40", r"fio randwrite 8k", "disk.fio.db-randwrite-8k"),
    ("41", r"fio randrw 70/30 8k read", "disk.fio.db-randrw-8k.read"),
    ("41", r"fio randrw 70/30 8k write", "disk.fio.db-randrw-8k.write"),
    ("42", r"fio seqwrite 1M", "disk.fio.db-seqwrite-1m"),
    ("43", r"fio randread 8k", "disk.fio.db-randread-8k"),
    ("44", r"wal fdatasync avg", "disk.wal.fdatasync.avg"),
    ("45", r"wal fdatasync p99", "disk.wal.fdatasync.p99"),
    ("46", r"wal commit iops qd1", "disk.wal.commit-iops.qd1"),
    ("47", r"pgbench tpcb-like tps \(-c \d+\)", "pg.pgbench.tpcb.tps"),
    ("48", r"tps stability 100\*\(1-cv\)", "pg.pgbench.tpcb.stability"),
    ("49", r"pgbench single-session latency", "pg.pgbench.latency.single"),
    ("51", r"iperf3 tcp tx->peer", "net.iperf3.tcp.tx"),
    ("51", r"iperf3 tcp peer->rx", "net.iperf3.tcp.rx"),
    ("51", r"iperf3 tcp bidir total", "net.iperf3.tcp.bidir"),
    ("52", r"sockperf ping-pong avg \(one-way\)", "net.sockperf.pingpong.avg"),
    ("52", r"sockperf ping-pong p99", "net.sockperf.pingpong.p99"),
    ("53", r"iperf3 udp 64B packets sent", "net.iperf3.udp.pps"),
    ("53", r"iperf3 udp lost packets %", "net.iperf3.udp.loss"),
    ("55", r"cpubench web mix max RPS @ SLO \(loopback\)", "web.cpubench.mix.max-rps"),
    ("65", r"burn-in errors \(\d+s\)", "burnin.errors"),
    ("info", r"cpu steal avg", "info.cpu.steal.avg"),
    ("info", r"cpu steal max", "info.cpu.steal.peak"),
    ("info", r"fio fill write 1M", "info.fio.fill-write-1m"),
]
VARIANTS = ("1t", "max")


def legacy_id(row, base, variant):
    """Stable id for a row of an old results.tsv. base is the metric text without array size and thread
    suffix, variant is "1t", "max" or "". Rows that LEGACY does not know get <stage>.row<row>.<text>."""
    for lrow, pattern, ident in LEGACY:
        if lrow == row and re.fullmatch(pattern, base):
            return f"{ident}.{variant}" if variant else ident
    stage = "info"
    if row.isdigit():
        stage = next((st for st, lo, hi in LEGACY_STAGES if lo <= int(row) <= hi), "info")
    slug = re.sub(r"[^a-z0-9]+", "-", f"{base} {variant}".lower()).strip("-")
    return f"{stage}.row{row}.{slug}"


def id_base(ident):
    """The id without its .1t / .max suffix: the test, whatever the thread count."""
    head, _, tail = ident.rpartition(".")
    return head if tail in VARIANTS and head else ident


_RANK = {}
for _i, (_r, _p, _ident) in enumerate(LEGACY):
    _RANK.setdefault(_ident, _i)


def id_key(ident):
    """Sort key: stage order, then the order of the tests (LEGACY), then the order they ran in."""
    stage = list(STAGE_SECTIONS).index(ident.split(".")[0]) if ident.split(".")[0] in STAGE_SECTIONS else len(STAGE_SECTIONS)
    return (stage, _RANK.get(id_base(ident), _RANK.get(ident, len(LEGACY))))


class InputError(Exception):
    pass

# ---- messages ----
# Every user-visible sentence of the reports lives here, one dict per language, with the same keys and the same
# {placeholders} in both (tests/test_report.py checks that). Use t("key", name=value). Metric names, units, ids
# and tool output are not translated.
MESSAGES = {
    "en": {
        "lang.html": "en",
        "section.info": "Context",
        "yes": "yes",
        "no": "no",
        "title.show": "Benchmark results: {label}",
        "title.compare": "Comparison: {labels}",
        "title.compare.join": " vs ",
        "env.title": "Environment",
        "env.item": "Item",
        "env.date": "Run date",
        "env.stages": "Stages run",
        "env.arch": "Architecture",
        "env.rounds": "Rounds / quick",
        "env.fio": "fio file / raw device",
        "env.stage_status": "Stage status",
        "env.steal": "avg {avg}% / max {peak}%",
        "env.no_problems": "no FAIL/SKIP",
        "col.test": "Test",
        "col.unit": "Unit",
        "col.value": "Value",
        "col.rounds": "Rounds",
        "col.diff": "Diff",
        "col.verdict": "Verdict",
        "col.verdict_run": "Verdict {label}",
        "verdict.none": "no data",
        "verdict.same": "not clearly different",
        "verdict.better_named": "{label} better{once}",
        "verdict.better": "better{once}",
        "verdict.worse": "worse{once}",
        "summary.title": "Tally per section (against the baseline)",
        "summary.section": "Section",
        "summary.compared": "Compared",
        "summary.better": "better than baseline",
        "summary.worse": "baseline better",
        "summary.same": "not clearly different",
        "legend": "* measured once, so its variation is unknown    ! CV of {cv}% or more    CV n/a = measured once",
        "compare.note": "\"not clearly different\" = the difference is within the larger CV of the two sides, or within {min}%    "
                        "Diff = (that machine - baseline) / baseline    Counts are numbers of tests, not weighted",
        "warnings": "Warnings",
        "warn.quick": "{label}: QUICK run, only good for checking that the script works. Do not use these numbers",
        "warn.steal": "{label}: average CPU steal {avg}% (max {peak}%), the host has other load, so results may be lower than the real capacity",
        "warn.noisy": "{label}: {count} value(s) vary by more than {cv}%: {names}",
        "warn.once": "{label}: {count} value(s) measured once (stages {stages}), so their variation is unknown",
        "warn.steady": "{label}: {id} did not reach steady state, the IOPS value may not have settled",
        "warn.differs": "{name} differs: {values}",
        "cmp.rounds": "rounds",
        "cmp.fio_size": "fio file size",
        "warn.cpubench": "cpubench versions differ, so the cpubench results cannot be compared directly: {values}",
        "warn.vmbench": "vmbench versions differ: {values}",
        "warn.arch": "different architectures: sysbench cpu counts prime numbers and depends heavily on the compiler, "
                     "so do not judge CPU speed by it alone",
        "warn.disk": "Disk: measured on a file on the OS disk, so the numbers may include host cache and hypervisor settings. "
                     "Check the cache mode before concluding which storage is better",
    },
    "th": {
        "lang.html": "th",
        "section.info": "ข้อมูลประกอบ",
        "yes": "ใช่",
        "no": "ไม่",
        "title.show": "ผลการทดสอบ: {label}",
        "title.compare": "เปรียบเทียบผล: {labels}",
        "title.compare.join": " กับ ",
        "env.title": "สภาพแวดล้อม",
        "env.item": "รายการ",
        "env.date": "วันที่รัน",
        "env.stages": "ขั้นตอนที่รัน",
        "env.arch": "สถาปัตยกรรม",
        "env.rounds": "จำนวนรอบ / quick",
        "env.fio": "ไฟล์ fio / raw device",
        "env.stage_status": "สถานะขั้นตอน",
        "env.steal": "เฉลี่ย {avg}% / สูงสุด {peak}%",
        "env.no_problems": "ไม่มี FAIL/SKIP",
        "col.test": "ทดสอบ",
        "col.unit": "หน่วย",
        "col.value": "ค่า",
        "col.rounds": "รอบ",
        "col.diff": "ต่าง",
        "col.verdict": "ผล",
        "col.verdict_run": "ผล {label}",
        "verdict.none": "ไม่มีข้อมูล",
        "verdict.same": "ไม่ต่างชัดเจน",
        "verdict.better_named": "{label} ดีกว่า{once}",
        "verdict.better": "ดีกว่า{once}",
        "verdict.worse": "แย่กว่า{once}",
        "summary.title": "นับผลตามหมวด (เทียบกับ baseline)",
        "summary.section": "หมวด",
        "summary.compared": "เทียบ",
        "summary.better": "ดีกว่า baseline",
        "summary.worse": "baseline ดีกว่า",
        "summary.same": "ไม่ต่างชัดเจน",
        "legend": "* วัดรอบเดียว ยังไม่รู้ว่าแกว่งแค่ไหน    ! CV ตั้งแต่ {cv}% ขึ้นไป    CV n/a = วัดรอบเดียว",
        "compare.note": "\"ไม่ต่างชัดเจน\" = ผลต่างไม่เกินค่า CV ที่มากกว่าของสองฝั่ง หรือไม่เกิน {min}%    "
                        "ต่าง = (เครื่องนั้น − baseline) / baseline    ค่าที่นับเป็นจำนวนการทดสอบ ไม่ได้ถ่วงน้ำหนัก",
        "warnings": "ข้อควรระวัง",
        "warn.quick": "{label}: รันแบบ QUICK ใช้ได้แค่ตรวจว่าสคริปต์ทำงาน ห้ามใช้ตัวเลขนี้",
        "warn.steal": "{label}: CPU steal เฉลี่ย {avg}% (สูงสุด {peak}%) host มีโหลดอื่น ผลอาจต่ำกว่าความจริง",
        "warn.noisy": "{label}: ค่าแกว่งเกิน {cv}% ({count} ค่า): {names}",
        "warn.once": "{label}: วัดรอบเดียว {count} ค่า (ขั้นตอน {stages}) ยังไม่รู้ว่าแกว่งแค่ไหน",
        "warn.steady": "{label}: {id} ยังไม่ถึง steady state ค่า IOPS อาจยังไม่นิ่ง",
        "warn.differs": "{name} ไม่เท่ากัน: {values}",
        "cmp.rounds": "จำนวนรอบ",
        "cmp.fio_size": "ขนาดไฟล์ fio",
        "warn.cpubench": "cpubench คนละเวอร์ชัน ผลกลุ่ม cpubench เทียบกันไม่ได้ตรง ๆ: {values}",
        "warn.vmbench": "vmbench คนละเวอร์ชัน: {values}",
        "warn.arch": "คนละสถาปัตยกรรม: sysbench cpu คำนวณจำนวนเฉพาะ ผลขึ้นกับ compiler มาก "
                     "อย่าใช้ตัวเดียวสรุปความแรงของ CPU",
        "warn.disk": "Disk: วัดจากไฟล์บน OS disk ตัวเลขอาจรวมผลของ host cache และการตั้งค่า hypervisor "
                     "ควรตรวจ cache mode ก่อนสรุปว่า storage ฝั่งไหนดีกว่า",
    },
}
LANGS = tuple(MESSAGES)
LANG = "en"


def set_lang(lang):
    global LANG
    if lang not in MESSAGES:
        raise InputError(f"unknown language '{lang}' (use one of: {', '.join(LANGS)})")
    LANG = lang


def t(key, **kw):
    return MESSAGES[LANG][key].format(**kw)


def section_of(ident):
    return STAGE_SECTIONS.get(ident.split(".")[0], INFO_SECTION)


def section_title(section):
    return t("section.info") if section == INFO_SECTION else section


def direction(metric, unit):
    """+1 higher is better, -1 lower is better, 0 not a performance value."""
    if unit in ("flag",) or metric.startswith(("cpu steal", "fio fill")):
        return 0
    if unit in ("ns", "us", "ms", "count") or "lost" in metric:
        return -1
    return 1


Metric = collections.namedtuple("Metric", "id name base variant unit values median cv")


class Run:
    def __init__(self, path):
        self.path = path.rstrip("/") or path
        res = os.path.join(path, "results.tsv")
        if not os.path.isfile(res):
            raise InputError(f"{path}: results.tsv not found (is this a run-benchmark.sh output folder?)")
        self.info = self._read_info(os.path.join(path, "info.txt"))
        self.meta, self.meta_problem = self._read_meta(os.path.join(path, "meta.json"))
        self._apply_meta()
        self.label = self.info.get("label") or os.path.basename(self.path)
        self.nproc = self.info.get("nproc", "")
        self.metrics = self._read_results(res)
        if not self.metrics:
            raise InputError(f"{path}: results.tsv has no values")
        self.problems = self._read_status(os.path.join(path, "status.tsv"))

    @staticmethod
    def _read_info(path):
        info = {}
        if not os.path.isfile(path):
            return info
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read()
        for key in ("date", "label", "kernel", "os", "virt", "cpubench"):
            m = re.search(rf"^{key}:[ \t]*(.+)$", text, re.M)
            if m:
                info[key] = m.group(1).strip()
        for key in ("nproc", "ram_gb", "quick", "rounds", "fio_size", "raw_dev"):
            m = re.search(rf"(?:^|\s){key}:[ \t]*(\S+)", text, re.M)
            if m:
                info[key] = m.group(1)
        for key, name in (("model", "Model name"), ("vendor", "Vendor ID")):
            m = re.search(rf"^{name}:[ \t]*(.+)$", text, re.M)
            if m:
                info[key] = m.group(1).strip()
        return info

    @staticmethod
    def _read_meta(path):
        """(meta dict, problem text). A folder without meta.json is an old run: no problem, empty dict."""
        if not os.path.isfile(path):
            return {}, ""
        try:
            with open(path, encoding="utf-8") as f:
                meta = json.load(f)
        except (OSError, ValueError) as e:
            return {}, f"meta.json cannot be read ({e.__class__.__name__}), using info.txt"
        if not isinstance(meta, dict):
            return {}, "meta.json is not a JSON object, using info.txt"
        return meta, ""

    def _apply_meta(self):
        """meta.json wins over info.txt for the keys it has; everything else keeps coming from info.txt."""
        def text(key):
            v = self.meta.get(key)
            if isinstance(v, bool):
                return "1" if v else "0"
            return str(v) if isinstance(v, (str, int, float)) and str(v) != "" else None

        for meta_key, info_key in (("label", "label"), ("nproc", "nproc"), ("ram_gb", "ram_gb"), ("quick", "quick"),
                                   ("rounds", "rounds"), ("cpubench_version", "cpubench"), ("start_utc", "date")):
            if text(meta_key) is not None:
                self.info[info_key] = text(meta_key)
        # per-stage repeats (vmbench 0.2+): "cpu 3, mem 3, disk 1, web 3" replaces the single cpu count
        by_stage = self.meta.get("rounds_by_stage")
        if isinstance(by_stage, dict) and by_stage:
            self.info["rounds"] = ", ".join(f"{k} {v}" for k, v in by_stage.items())

    @property
    def version(self):
        v = self.meta.get("vmbench_version")
        return v if isinstance(v, str) and v else ""

    @property
    def stages(self):
        v = self.meta.get("stages")
        return [x for x in v if isinstance(x, str)] if isinstance(v, list) else []

    def _split_threads(self, name):
        """'x 8t' -> ('x', 'max') when 8 is this machine's vCPU count, so 8 and 16 vCPU runs still pair up."""
        m = re.match(r"^(.*) (\d+)t$", name)
        if not m:
            return name, ""
        n = m.group(2)
        if n == "1":
            return m.group(1), "1t"
        if not self.nproc or n == self.nproc:
            return m.group(1), "max"
        return name, ""

    def _read_results(self, path):
        raw = collections.OrderedDict()
        self.stream_n = ""
        legacy = True   # no header at all means the old format
        with open(path, encoding="utf-8", errors="replace", newline="") as f:
            for r in csv.reader(f, delimiter="\t"):
                if len(r) < 5:
                    continue
                if r[0] in ("row", "id") and r[2] == "value":
                    legacy = r[0] == "row"
                    continue
                try:
                    value = float(r[2])
                except ValueError:
                    continue
                raw.setdefault((r[0], r[1], r[3]), []).append(value)
        metrics = []
        for (key, name, unit), values in raw.items():
            n = re.search(r" \(N=(\d+)\)$", name)
            if n:  # the array size goes to the environment table, so runs with another N still pair up
                self.stream_n = n.group(1)
                name = name[:n.start()]
            base, variant = self._split_threads(name)
            ident = legacy_id(key, base, variant) if legacy else key
            mean = statistics.mean(values)
            cv = statistics.pstdev(values) / abs(mean) * 100 if len(values) > 1 and mean else None
            metrics.append(Metric(ident, name, base, variant, unit, values, statistics.median(values), cv))
        metrics.sort(key=lambda m: id_key(m.id))  # stable: keeps the order the tests ran in
        return metrics

    @staticmethod
    def _read_status(path):
        out = []
        if os.path.isfile(path):
            with open(path, encoding="utf-8", errors="replace", newline="") as f:
                for r in csv.reader(f, delimiter="\t"):
                    # the result column may carry a reason: "FAIL see web.log"
                    if len(r) >= 3 and r[2].split(" ", 1)[0] in ("FAIL", "SKIP"):
                        out.append(r[:3])
        return out

    def find(self, name):
        for m in self.metrics:
            if m.name == name:
                return m
        return None

    @property
    def arch(self):
        meta = self.meta.get("arch")
        if isinstance(meta, str) and meta:
            return meta
        return self.info.get("kernel", "").rsplit(" ", 1)[-1]

    @property
    def cpu(self):
        model = self.info.get("model", "")
        return self.info.get("vendor", "") if model in ("", "-") else model

    @property
    def steal(self):
        avg, top = self.find("cpu steal avg"), self.find("cpu steal max")
        return avg.median if avg else None, top.median if top else None


# ---- formatting ----

def num(v):
    a = abs(v)
    if a >= 1000:
        return f"{v:,.0f}"
    if a >= 100:
        return f"{v:.1f}"
    if a >= 1 or a == 0:
        return f"{v:.2f}".rstrip("0").rstrip(".")
    return f"{v:.3g}"


def mark(m):
    if len(m.values) < 2:
        return "*"
    return "!" if m.cv is not None and m.cv >= HIGH_CV else ""


def value(m):
    if m is None:
        return "-"
    if m.unit == "flag":
        return t("yes") if m.median else t("no")
    return num(m.median) + mark(m)


def cv_text(m):
    if m is None:
        return "-"
    return "n/a" if m.cv is None else f"{m.cv:.1f}%"


def id_span(ids):
    return ", ".join(sorted({id_base(i) for i in ids}, key=id_key))


Table = collections.namedtuple("Table", "title headers aligns rows")   # a cell is text or (text, css class)


def cell_text(c):
    return c[0] if isinstance(c, tuple) else c


# ---- environment and warnings ----

def env_table(runs):
    def steal(r):
        avg, top = r.steal
        return "-" if avg is None else t("env.steal", avg=num(avg), peak=num(top))

    def status(r):
        c = collections.Counter(p[2].split(" ", 1)[0] for p in r.problems)
        return ", ".join(f"{k} {v}" for k, v in sorted(c.items())) or t("env.no_problems")

    fields = [(t("env.date"), lambda r: r.info.get("date", "-")),
              ("vmbench", lambda r: r.version or "-"),
              (t("env.stages"), lambda r: " ".join(s for s in r.stages if s != "info") or "-"),
              ("CPU", lambda r: r.cpu or "-"),
              (t("env.arch"), lambda r: r.arch or "-"),
              ("vCPU / RAM", lambda r: f"{r.info.get('nproc', '-')} / {r.info.get('ram_gb', '-')} GB"),
              ("Kernel", lambda r: r.info.get("kernel", "-")),
              ("OS", lambda r: r.info.get("os", "-")),
              ("Hypervisor", lambda r: r.info.get("virt", "-")),
              ("cpubench", lambda r: r.info.get("cpubench", "-")),
              (t("env.rounds"), lambda r: f"{r.info.get('rounds', '-')} / {r.info.get('quick', '-')}"),
              (t("env.fio"), lambda r: f"{r.info.get('fio_size', '-')} / {r.info.get('raw_dev', '-')}"),
              ("STREAM N", lambda r: r.stream_n or "-"),
              ("CPU steal", steal),
              (t("env.stage_status"), status)]
    return Table(t("env.title"), [t("env.item")] + [r.label for r in runs], ["l"] * (len(runs) + 1),
                 [[name] + [fn(r) for r in runs] for name, fn in fields])


def run_warnings(run):
    out = []
    if run.info.get("quick", "0") not in ("0", ""):
        out.append(t("warn.quick", label=run.label))
    avg, top = run.steal
    if avg is not None and avg >= HIGH_STEAL:
        out.append(t("warn.steal", label=run.label, avg=num(avg), peak=num(top)))
    if run.meta_problem:
        out.append(f"{run.label}: {run.meta_problem}")
    for stage, step, result in run.problems:
        out.append(f"{run.label}: {stage} / {step} = {result}")
    noisy = [m.name for m in run.metrics if mark(m) == "!"]
    if noisy:
        out.append(t("warn.noisy", label=run.label, cv=f"{HIGH_CV:.0f}", count=len(noisy), names=", ".join(noisy)))
    once = [m for m in run.metrics if len(m.values) < 2 and not m.id.startswith("info.")]
    if once and any(len(m.values) > 1 for m in run.metrics):
        stages = ", ".join(sorted({m.id.split(".")[0] for m in once}, key=lambda s: id_key(s + ".")))
        out.append(t("warn.once", label=run.label, count=len(once), stages=stages))
    flag = run.find("steadystate attained (1=yes)")
    if flag and not flag.median:
        out.append(t("warn.steady", label=run.label, id=flag.id))
    return out


def compare_warnings(runs):
    out = []

    def differs(name, fn):
        vals = [fn(r) for r in runs]
        if len(set(vals)) > 1:
            out.append(t("warn.differs", name=name, values=", ".join(f"{r.label}={v}" for r, v in zip(runs, vals))))

    # version and commit only: the rest of the line is a per-architecture build tag such as GOAMD64=v1
    versions = [" · ".join(r.info.get("cpubench", "?").split(" · ")[:2]) for r in runs]
    if len(set(versions)) > 1:
        out.append(t("warn.cpubench", values=", ".join(f"{r.label}={v}" for r, v in zip(runs, versions))))
    known = [r.version for r in runs]
    if all(known) and len(set(known)) > 1:
        out.append(t("warn.vmbench", values=", ".join(f"{r.label}={r.version}" for r in runs)))
    differs(t("cmp.rounds"), lambda r: r.info.get("rounds", "?"))
    differs(t("cmp.fio_size"), lambda r: r.info.get("fio_size", "?"))
    differs("raw device", lambda r: r.info.get("raw_dev", "?"))
    differs("vCPU", lambda r: r.info.get("nproc", "?"))
    differs("RAM (GB)", lambda r: r.info.get("ram_gb", "?"))
    differs("STREAM N", lambda r: r.stream_n or "?")
    if len({r.arch for r in runs}) > 1 and any(r.find("sysbench cpu 1t") for r in runs):
        out.append(t("warn.arch"))
    return out


def disk_warning(runs):
    tested = [r for r in runs if any(section_of(m.id) == "Disk" for m in r.metrics)]
    if any(r.info.get("raw_dev", "none") == "none" for r in tested):
        return [t("warn.disk")]
    return []


# ---- show ----

def show_tables(run):
    groups = collections.OrderedDict()
    for m in run.metrics:
        groups.setdefault(section_of(m.id), collections.OrderedDict()).setdefault((m.base, m.unit), []).append(m)
    tables = []
    for section, items in groups.items():
        threaded = any(m.variant for ms in items.values() for m in ms)
        rows = []
        for (base, unit), ms in items.items():
            by = {m.variant: m for m in ms}
            head = [id_span([m.id for m in ms]), base, unit]
            if threaded:
                one, top = by.get("1t"), by.get("max")
                plain = by.get("")
                if plain and not one and not top:
                    rows.append(head + ["-", value(plain), str(len(plain.values)), cv_text(plain)])
                    continue
                count = {len(m.values) for m in ms}
                rows.append(head + [value(one), value(top), "/".join(str(c) for c in sorted(count)),
                                    " / ".join(cv_text(m) for m in (one, top) if m)])
            else:
                m = ms[0]
                rows.append(head + [value(m), str(len(m.values)), cv_text(m)])
        if threaded:
            top = f"max ({run.nproc}t)" if run.nproc else "max"
            headers = ["ID", t("col.test"), t("col.unit"), "1 thread", top, t("col.rounds"), "CV"]
        else:
            headers = ["ID", t("col.test"), t("col.unit"), t("col.value"), t("col.rounds"), "CV"]
        aligns = ["l", "l", "l"] + ["r"] * (len(headers) - 3)
        tables.append(Table(section_title(section), headers, aligns, rows))
    return tables


# ---- compare ----

def judge(base, other):
    """(difference %, verdict): +1 other is better, -1 baseline is better, 0 not clear, None not comparable."""
    direct = direction(other.name, other.unit)
    if direct == 0:   # context values such as CPU steal: show them, a percentage would only mislead
        return None, None
    b, o = base.median, other.median
    diff = (o - b) / abs(b) * 100 if b else None
    if b == o:
        return diff, 0
    if diff is not None:
        noise = max(MIN_DIFF, base.cv or 0, other.cv or 0)
        if abs(diff) <= noise:
            return diff, 0
    return diff, (1 if (o > b) == (direct > 0) else -1)


def compare_tables(runs):
    base = runs[0]
    keys = collections.OrderedDict()
    for run in runs:
        for m in run.metrics:
            keys.setdefault((m.id, m.base, m.variant, m.unit), None)
    lookup = [{(m.id, m.base, m.variant, m.unit): m for m in run.metrics} for run in runs]

    groups = collections.OrderedDict()
    for key in sorted(keys, key=lambda k: id_key(k[0])):
        groups.setdefault(section_of(key[0]), []).append(key)

    tables = []
    tally = collections.OrderedDict()
    two = len(runs) == 2
    for section, section_keys in groups.items():
        headers = ["ID", t("col.test"), t("col.unit"), base.label + " (baseline)"]
        aligns = ["l", "l", "l", "r"]
        for run in runs[1:]:
            headers += [run.label, t("col.diff")]
            aligns += ["r", "r"]
            headers.append(t("col.verdict") if two else t("col.verdict_run", label=run.label))
            aligns.append("l")
        rows = []
        for key in section_keys:
            ident, name, variant, unit = key
            shown = f"{name} {variant}" if variant else name
            b = lookup[0].get(key)
            cells = [id_base(ident), shown, unit, value(b)]
            for i, run in enumerate(runs[1:], 1):
                o = lookup[i].get(key)
                cells.append(value(o))
                if b is None or o is None:
                    cells += ["-", (t("verdict.none"), "none")]
                    continue
                diff, verdict = judge(b, o)
                cells.append("-" if diff is None else f"{diff:+.1f}%".replace("-", "−"))
                if verdict is None:
                    cells.append("-")
                    continue
                cnt = tally.setdefault(section, {}).setdefault(run.label, [0, 0, 0])
                once = "*" if len(b.values) < 2 or len(o.values) < 2 else ""
                if verdict == 0:
                    cnt[2] += 1
                    cells.append((t("verdict.same"), "same"))
                elif verdict > 0:
                    cnt[0] += 1
                    cells.append((t("verdict.better_named", label=run.label, once=once) if two else t("verdict.better", once=once), "better"))
                else:
                    cnt[1] += 1
                    cells.append((t("verdict.better_named", label=base.label, once=once) if two else t("verdict.worse", once=once), "worse"))
            rows.append(cells)
        tables.append(Table(section_title(section), headers, aligns, rows))

    summary_rows = []
    for section, per_run in tally.items():
        for label, (better, worse, same) in per_run.items():
            summary_rows.append([section_title(section), label, str(better), str(worse), str(same)])
    summary = Table(t("summary.title"),
                    [t("summary.section"), t("summary.compared"), t("summary.better"), t("summary.worse"), t("summary.same")],
                    ["l", "l", "r", "r", "r"], summary_rows)
    return summary, tables


# ---- renderers ----

def legend():
    return t("legend", cv=f"{HIGH_CV:.0f}")


def compare_note():
    return t("compare.note", min=f"{MIN_DIFF:.0f}")


def width(s):
    w = 0
    for ch in s:
        if unicodedata.category(ch) in ("Mn", "Me", "Cf"):
            continue
        w += 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
    return w


def text_table(t):
    rows = [[cell_text(c) for c in r] for r in t.rows]
    widths = [max([width(h)] + [width(r[i]) for r in rows]) for i, h in enumerate(t.headers)]

    def line(cells):
        out = []
        for i, c in enumerate(cells):
            pad = " " * (widths[i] - width(c))
            out.append(pad + c if t.aligns[i] == "r" else c + pad)
        return "  ".join(out).rstrip()

    return "\n".join([f"== {t.title} ==", line(t.headers), "  ".join("-" * w for w in widths)]
                     + [line(r) for r in rows])


def render_text(title, env, main, warnings, summary, notes):
    parts = [title, "", text_table(env)]
    parts += ["\n" + text_table(t) for t in main]
    if summary and summary.rows:
        parts.append("\n" + text_table(summary))
    parts += [""] + notes
    if warnings:
        parts += ["", f"== {t('warnings')} =="] + ["- " + w for w in warnings]
    return "\n".join(parts) + "\n"


def md_cell(c):
    return cell_text(c).replace("|", "\\|").replace("*", "\\*")


def md_table(t):
    sep = {"l": "---", "r": "---:"}
    out = [f"## {t.title}", "", "| " + " | ".join(h.replace("|", "\\|") for h in t.headers) + " |",
           "|" + "|".join(sep[a] for a in t.aligns) + "|"]
    out += ["| " + " | ".join(md_cell(c) for c in r) + " |" for r in t.rows]
    return "\n".join(out)


def render_md(title, env, main, warnings, summary, notes):
    parts = [f"# {title}"]
    if warnings:
        parts.append(f"## {t('warnings')}\n\n" + "\n".join("- " + w.replace("*", "\\*") for w in warnings))
    if summary and summary.rows:
        parts.append(md_table(summary))
    parts += [md_table(t) for t in main]
    parts.append(md_table(env))
    parts.append("\n\n".join(n.replace("*", "\\*") for n in notes))
    return "\n\n".join(parts) + "\n"


CSS = """
:root{--bg:#fbfbfa;--panel:#fff;--text:#1f2328;--muted:#5f6670;--line:#e2e4e8;--head:#f2f3f5;
--better:#17663a;--better-bg:#e4f4ea;--worse:#a3321f;--worse-bg:#fbe9e5;--same:#5f6670;
--warn:#7a4b00;--warn-bg:#fdf3dc;--warn-line:#e8c777}
@media (prefers-color-scheme:dark){:root{--bg:#16181c;--panel:#1e2126;--text:#e6e8eb;--muted:#a0a7b1;
--line:#33373e;--head:#262a30;--better:#7fd6a0;--better-bg:#1b3527;--worse:#f29d8c;--worse-bg:#3d221c;
--same:#a0a7b1;--warn:#f0cf8a;--warn-bg:#352b14;--warn-line:#6b5522}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font:15px/1.55 system-ui,-apple-system,"Segoe UI","Noto Sans Thai",sans-serif}
main{max-width:1120px;margin:0 auto;padding:28px 16px 48px}
h1{font-size:24px;line-height:1.3;margin:0 0 20px}
h2{font-size:17px;margin:30px 0 10px}
.warn{background:var(--warn-bg);border:1px solid var(--warn-line);color:var(--warn);border-radius:8px;padding:12px 16px}
.warn h2{margin:0 0 6px;font-size:15px;color:inherit}
.warn ul{margin:0;padding-left:20px}
.wrap{overflow-x:auto;background:var(--panel);border:1px solid var(--line);border-radius:8px}
table{border-collapse:collapse;width:100%;font-size:14px}
th,td{padding:7px 12px;border-bottom:1px solid var(--line);text-align:left;white-space:nowrap}
tr:last-child td{border-bottom:0}
th{background:var(--head);font-weight:600}
.r{text-align:right;font-variant-numeric:tabular-nums}
td.better{color:var(--better);background:var(--better-bg)}
td.worse{color:var(--worse);background:var(--worse-bg)}
td.same,td.none{color:var(--same)}
.notes{color:var(--muted);font-size:13px;margin-top:24px}
.notes p{margin:4px 0}
"""


def html_table(t):
    out = [f"<h2>{html.escape(t.title)}</h2>", '<div class="wrap"><table><thead><tr>']
    for h, a in zip(t.headers, t.aligns):
        out.append(f'<th class="{a}">{html.escape(h)}</th>')
    out.append("</tr></thead><tbody>")
    for r in t.rows:
        out.append("<tr>")
        for c, a in zip(r, t.aligns):
            cls = [a] + ([c[1]] if isinstance(c, tuple) else [])
            out.append(f'<td class="{" ".join(cls)}">{html.escape(cell_text(c))}</td>')
        out.append("</tr>")
    out.append("</tbody></table></div>")
    return "".join(out)


def render_html(title, env, main, warnings, summary, notes):
    body = [f"<h1>{html.escape(title)}</h1>"]
    if warnings:
        items = "".join(f"<li>{html.escape(w)}</li>" for w in warnings)
        body.append(f'<div class="warn"><h2>{html.escape(t("warnings"))}</h2><ul>{items}</ul></div>')
    if summary and summary.rows:
        body.append(html_table(summary))
    body += [html_table(t) for t in main]
    body.append(html_table(env))
    body.append('<div class="notes">' + "".join(f"<p>{html.escape(n)}</p>" for n in notes) + "</div>")
    return (f'<!doctype html><html lang="{t("lang.html")}"><head><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width,initial-scale=1">'
            f"<title>{html.escape(title)}</title><style>{CSS}</style></head><body><main>"
            + "".join(body) + "</main></body></html>\n")


def emit(args, default_dir, title, env, main, warnings, summary, notes):
    sys.stdout.write(render_text(title, env, main, warnings, summary, notes))
    if args.no_files:
        return
    out = args.out or default_dir
    os.makedirs(out, exist_ok=True)
    for name, render in (("report.md", render_md), ("report.html", render_html)):
        path = os.path.join(out, name)
        with open(path, "w", encoding="utf-8") as f:
            f.write(render(title, env, main, warnings, summary, notes))
        print(f"wrote {path}", file=sys.stderr)


def cmd_show(args):
    run = Run(args.dir)
    emit(args, run.path, t("title.show", label=run.label), env_table([run]), show_tables(run),
         disk_warning([run]) + run_warnings(run), None, [legend()])


def unique_labels(runs):
    seen = collections.Counter(r.label for r in runs)
    for r in runs:
        if seen[r.label] > 1:
            r.label = os.path.basename(r.path)
    seen = collections.Counter(r.label for r in runs)
    used = collections.Counter()
    for r in runs:
        if seen[r.label] > 1:
            used[r.label] += 1
            r.label = f"{r.label}#{used[r.label]}"


def cmd_compare(args):
    runs = [Run(d) for d in args.dirs]
    unique_labels(runs)
    warnings = compare_warnings(runs) + disk_warning(runs)
    for run in runs:
        warnings += run_warnings(run)
    summary, tables = compare_tables(runs)
    labels = [re.sub(r"[^\w.-]+", "_", r.label) for r in runs]
    title = t("title.compare", labels=t("title.compare.join").join(r.label for r in runs))
    emit(args, "compare-" + "-vs-".join(labels), title, env_table(runs), tables, warnings, summary,
         [legend(), compare_note()])


def main():
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--out", help="folder for report.md and report.html")
    common.add_argument("--no-files", action="store_true", help="stdout only")
    common.add_argument("--lang", choices=LANGS, default=None,
                        help="report language (default: $VMBENCH_LANG, else en)")
    p = argparse.ArgumentParser(description="Tables and comparisons from run-benchmark.sh results.")
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("show", parents=[common], help="tables for one run")
    s.add_argument("dir", help="results folder")
    s.set_defaults(fn=cmd_show)
    c = sub.add_parser("compare", parents=[common], help="compare runs; the first folder is the baseline")
    c.add_argument("dirs", nargs="+", metavar="dir", help="at least two results folders")
    c.set_defaults(fn=cmd_compare)
    args = p.parse_args()
    if args.cmd == "compare" and len(args.dirs) < 2:
        p.error("compare needs at least two results folders")
    try:
        set_lang(args.lang or os.environ.get("VMBENCH_LANG") or "en")
        args.fn(args)
    except InputError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    except BrokenPipeError:   # e.g. piped into head
        os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
    return 0


if __name__ == "__main__":
    sys.exit(main())
