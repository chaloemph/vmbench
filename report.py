#!/usr/bin/env python3
"""report.py - turn run-benchmark.sh results into tables, and compare runs.

  python3 report.py show    bench-results/x86-full
  python3 report.py compare bench-results/x86-full bench-results/arm64-full   # first folder = baseline

Every command prints the tables to stdout and writes report.md + report.html:
  show     into the results folder (or --out DIR)
  compare  into ./compare-<a>-vs-<b>/ (or --out DIR)
Use --no-files for stdout only. Standard library only, Python 3.8+.

Values are recomputed from results.tsv (median and CV over the rounds).
Marks:  * measured once, so its variation is unknown    ! CV of 5% or more

Compare verdicts: lower is better for ns/us/ms, error counts and packet loss; higher is better
otherwise. A difference within the larger CV of the two runs, or within 1%, is not called a win.
"""
import argparse
import collections
import csv
import html
import os
import re
import statistics
import sys
import unicodedata

HIGH_CV = 5.0       # % - mark a metric as noisy from here on
MIN_DIFF = 1.0      # % - smaller differences are never called a win
HIGH_STEAL = 1.0    # % - average CPU steal worth warning about

SECTIONS = [("CPU", 0, 23), ("Memory", 24, 32), ("Disk", 33, 46), ("PostgreSQL", 47, 49),
            ("Network", 50, 54), ("Web", 55, 59), ("Burn-in", 60, 999)]
INFO_SECTION = "ข้อมูลประกอบ"


class InputError(Exception):
    pass


def section_of(row):
    if row.isdigit():
        for name, lo, hi in SECTIONS:
            if lo <= int(row) <= hi:
                return name
    return INFO_SECTION


def row_key(row):
    return (0, int(row)) if row.isdigit() else (1, 0)


def direction(metric, unit):
    """+1 higher is better, -1 lower is better, 0 not a performance value."""
    if unit in ("flag",) or metric.startswith(("cpu steal", "fio fill")):
        return 0
    if unit in ("ns", "us", "ms", "count") or "lost" in metric:
        return -1
    return 1


Metric = collections.namedtuple("Metric", "row name base variant unit values median cv")


class Run:
    def __init__(self, path):
        self.path = path.rstrip("/") or path
        res = os.path.join(path, "results.tsv")
        if not os.path.isfile(res):
            raise InputError(f"{path}: results.tsv not found (is this a run-benchmark.sh output folder?)")
        self.info = self._read_info(os.path.join(path, "info.txt"))
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
        with open(path, encoding="utf-8", errors="replace", newline="") as f:
            for r in csv.reader(f, delimiter="\t"):
                if len(r) < 5 or r[0] == "row":
                    continue
                try:
                    value = float(r[2])
                except ValueError:
                    continue
                raw.setdefault((r[0], r[1], r[3]), []).append(value)
        metrics = []
        for (row, name, unit), values in raw.items():
            n = re.search(r" \(N=(\d+)\)$", name)
            if n:  # the array size goes to the environment table, so runs with another N still pair up
                self.stream_n = n.group(1)
                name = name[:n.start()]
            base, variant = self._split_threads(name)
            mean = statistics.mean(values)
            cv = statistics.pstdev(values) / abs(mean) * 100 if len(values) > 1 and mean else None
            metrics.append(Metric(row, name, base, variant, unit, values, statistics.median(values), cv))
        metrics.sort(key=lambda m: row_key(m.row))  # stable: keeps the order the tests ran in
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
        return "ใช่" if m.median else "ไม่"
    return num(m.median) + mark(m)


def cv_text(m):
    if m is None:
        return "-"
    return "n/a" if m.cv is None else f"{m.cv:.1f}%"


def row_span(rows):
    nums = sorted(set(rows), key=row_key)
    return nums[0] if len(nums) == 1 else f"{nums[0]}–{nums[-1]}"


Table = collections.namedtuple("Table", "title headers aligns rows")   # a cell is text or (text, css class)


def cell_text(c):
    return c[0] if isinstance(c, tuple) else c


# ---- environment and warnings ----

def env_table(runs):
    def steal(r):
        avg, top = r.steal
        return "-" if avg is None else f"เฉลี่ย {num(avg)}% / สูงสุด {num(top)}%"

    def status(r):
        c = collections.Counter(p[2].split(" ", 1)[0] for p in r.problems)
        return ", ".join(f"{k} {v}" for k, v in sorted(c.items())) or "ไม่มี FAIL/SKIP"

    fields = [("วันที่รัน", lambda r: r.info.get("date", "-")),
              ("CPU", lambda r: r.cpu or "-"),
              ("สถาปัตยกรรม", lambda r: r.arch or "-"),
              ("vCPU / RAM", lambda r: f"{r.info.get('nproc', '-')} / {r.info.get('ram_gb', '-')} GB"),
              ("Kernel", lambda r: r.info.get("kernel", "-")),
              ("OS", lambda r: r.info.get("os", "-")),
              ("Hypervisor", lambda r: r.info.get("virt", "-")),
              ("cpubench", lambda r: r.info.get("cpubench", "-")),
              ("จำนวนรอบ / quick", lambda r: f"{r.info.get('rounds', '-')} / {r.info.get('quick', '-')}"),
              ("ไฟล์ fio / raw device", lambda r: f"{r.info.get('fio_size', '-')} / {r.info.get('raw_dev', '-')}"),
              ("STREAM N", lambda r: r.stream_n or "-"),
              ("CPU steal", steal),
              ("สถานะขั้นตอน", status)]
    return Table("สภาพแวดล้อม", ["รายการ"] + [r.label for r in runs], ["l"] * (len(runs) + 1),
                 [[name] + [fn(r) for r in runs] for name, fn in fields])


def run_warnings(run):
    out = []
    if run.info.get("quick", "0") not in ("0", ""):
        out.append(f"{run.label}: รันแบบ QUICK ใช้ได้แค่ตรวจว่าสคริปต์ทำงาน ห้ามใช้ตัวเลขนี้")
    avg, top = run.steal
    if avg is not None and avg >= HIGH_STEAL:
        out.append(f"{run.label}: CPU steal เฉลี่ย {num(avg)}% (สูงสุด {num(top)}%) "
                   "host มีโหลดอื่น ผลอาจต่ำกว่าความจริง")
    for stage, step, result in run.problems:
        out.append(f"{run.label}: {stage} / {step} = {result}")
    noisy = [m.name for m in run.metrics if mark(m) == "!"]
    if noisy:
        out.append(f"{run.label}: ค่าแกว่งเกิน {HIGH_CV:.0f}% ({len(noisy)} ค่า): " + ", ".join(noisy))
    once = [m for m in run.metrics if len(m.values) < 2 and m.row != "info"]
    if once and any(len(m.values) > 1 for m in run.metrics):
        rows = row_span_list(m.row for m in once)
        out.append(f"{run.label}: วัดรอบเดียว {len(once)} ค่า (แถว {rows}) ยังไม่รู้ว่าแกว่งแค่ไหน")
    flag = run.find("steadystate attained (1=yes)")
    if flag and not flag.median:
        out.append(f"{run.label}: แถว 33 ยังไม่ถึง steady state ค่า IOPS อาจยังไม่นิ่ง")
    return out


def row_span_list(rows):
    nums = sorted({int(r) for r in rows if r.isdigit()})
    parts, i = [], 0
    while i < len(nums):
        j = i
        while j + 1 < len(nums) and nums[j + 1] == nums[j] + 1:
            j += 1
        parts.append(str(nums[i]) if i == j else f"{nums[i]}–{nums[j]}")
        i = j + 1
    return ", ".join(parts)


def compare_warnings(runs):
    out = []

    def differs(name, fn):
        vals = [fn(r) for r in runs]
        if len(set(vals)) > 1:
            out.append(f"{name} ไม่เท่ากัน: " + ", ".join(f"{r.label}={v}" for r, v in zip(runs, vals)))

    # version and commit only: the rest of the line is a per-architecture build tag such as GOAMD64=v1
    versions = [" · ".join(r.info.get("cpubench", "?").split(" · ")[:2]) for r in runs]
    if len(set(versions)) > 1:
        out.append("cpubench คนละเวอร์ชัน ผลกลุ่ม cpubench เทียบกันไม่ได้ตรง ๆ: "
                   + ", ".join(f"{r.label}={v}" for r, v in zip(runs, versions)))
    differs("จำนวนรอบ", lambda r: r.info.get("rounds", "?"))
    differs("ขนาดไฟล์ fio", lambda r: r.info.get("fio_size", "?"))
    differs("raw device", lambda r: r.info.get("raw_dev", "?"))
    differs("vCPU", lambda r: r.info.get("nproc", "?"))
    differs("RAM (GB)", lambda r: r.info.get("ram_gb", "?"))
    differs("STREAM N", lambda r: r.stream_n or "?")
    if len({r.arch for r in runs}) > 1 and any(r.find("sysbench cpu 1t") for r in runs):
        out.append("คนละสถาปัตยกรรม: sysbench cpu คำนวณจำนวนเฉพาะ ผลขึ้นกับ compiler มาก "
                   "อย่าใช้ตัวเดียวสรุปความแรงของ CPU")
    return out


def disk_warning(runs):
    tested = [r for r in runs if any(section_of(m.row) == "Disk" for m in r.metrics)]
    if any(r.info.get("raw_dev", "none") == "none" for r in tested):
        return ["Disk: วัดจากไฟล์บน OS disk ตัวเลขอาจรวมผลของ host cache และการตั้งค่า hypervisor "
                "ควรตรวจ cache mode ก่อนสรุปว่า storage ฝั่งไหนดีกว่า"]
    return []


# ---- show ----

def show_tables(run):
    groups = collections.OrderedDict()
    for m in run.metrics:
        groups.setdefault(section_of(m.row), collections.OrderedDict()).setdefault((m.base, m.unit), []).append(m)
    tables = []
    for section, items in groups.items():
        threaded = any(m.variant for ms in items.values() for m in ms)
        rows = []
        for (base, unit), ms in items.items():
            by = {m.variant: m for m in ms}
            head = [row_span([m.row for m in ms]), base, unit]
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
            headers = ["แถว", "ทดสอบ", "หน่วย", "1 thread", top, "รอบ", "CV"]
        else:
            headers = ["แถว", "ทดสอบ", "หน่วย", "ค่า", "รอบ", "CV"]
        aligns = ["l", "l", "l"] + ["r"] * (len(headers) - 3)
        tables.append(Table(section, headers, aligns, rows))
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
            keys.setdefault((m.row, m.base, m.variant, m.unit), None)
    lookup = [{(m.row, m.base, m.variant, m.unit): m for m in run.metrics} for run in runs]

    groups = collections.OrderedDict()
    for key in sorted(keys, key=lambda k: row_key(k[0])):
        groups.setdefault(section_of(key[0]), []).append(key)

    tables = []
    tally = collections.OrderedDict()
    two = len(runs) == 2
    for section, section_keys in groups.items():
        headers = ["แถว", "ทดสอบ", "หน่วย", base.label + " (baseline)"]
        aligns = ["l", "l", "l", "r"]
        for run in runs[1:]:
            headers += [run.label, "ต่าง"]
            aligns += ["r", "r"]
            headers.append("ผล" if two else f"ผล {run.label}")
            aligns.append("l")
        rows = []
        for key in section_keys:
            row, name, variant, unit = key
            shown = f"{name} {variant}" if variant else name
            b = lookup[0].get(key)
            cells = [row, shown, unit, value(b)]
            for i, run in enumerate(runs[1:], 1):
                o = lookup[i].get(key)
                cells.append(value(o))
                if b is None or o is None:
                    cells += ["-", ("ไม่มีข้อมูล", "none")]
                    continue
                diff, verdict = judge(b, o)
                cells.append("-" if diff is None else f"{diff:+.1f}%".replace("-", "−"))
                if verdict is None:
                    cells.append("-")
                    continue
                t = tally.setdefault(section, {}).setdefault(run.label, [0, 0, 0])
                once = "*" if len(b.values) < 2 or len(o.values) < 2 else ""
                if verdict == 0:
                    t[2] += 1
                    cells.append(("ไม่ต่างชัดเจน", "same"))
                elif verdict > 0:
                    t[0] += 1
                    cells.append((f"{run.label} ดีกว่า{once}" if two else f"ดีกว่า{once}", "better"))
                else:
                    t[1] += 1
                    cells.append((f"{base.label} ดีกว่า{once}" if two else f"แย่กว่า{once}", "worse"))
            rows.append(cells)
        tables.append(Table(section, headers, aligns, rows))

    summary_rows = []
    for section, per_run in tally.items():
        for label, (better, worse, same) in per_run.items():
            summary_rows.append([section, label, str(better), str(worse), str(same)])
    summary = Table("นับผลตามหมวด (เทียบกับ baseline)",
                    ["หมวด", "เทียบ", "ดีกว่า baseline", "baseline ดีกว่า", "ไม่ต่างชัดเจน"],
                    ["l", "l", "r", "r", "r"], summary_rows)
    return summary, tables


# ---- renderers ----

LEGEND = (f"* วัดรอบเดียว ยังไม่รู้ว่าแกว่งแค่ไหน    ! CV ตั้งแต่ {HIGH_CV:.0f}% ขึ้นไป    "
          "CV n/a = วัดรอบเดียว")
COMPARE_NOTE = (f"\"ไม่ต่างชัดเจน\" = ผลต่างไม่เกินค่า CV ที่มากกว่าของสองฝั่ง หรือไม่เกิน {MIN_DIFF:.0f}%    "
                "ต่าง = (เครื่องนั้น − baseline) / baseline    ค่าที่นับเป็นจำนวนการทดสอบ ไม่ได้ถ่วงน้ำหนัก")


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
        parts += ["", "== ข้อควรระวัง =="] + ["- " + w for w in warnings]
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
        parts.append("## ข้อควรระวัง\n\n" + "\n".join("- " + w.replace("*", "\\*") for w in warnings))
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
        body.append(f'<div class="warn"><h2>ข้อควรระวัง</h2><ul>{items}</ul></div>')
    if summary and summary.rows:
        body.append(html_table(summary))
    body += [html_table(t) for t in main]
    body.append(html_table(env))
    body.append('<div class="notes">' + "".join(f"<p>{html.escape(n)}</p>" for n in notes) + "</div>")
    return ('<!doctype html><html lang="th"><head><meta charset="utf-8">'
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
    emit(args, run.path, f"ผลการทดสอบ: {run.label}", env_table([run]), show_tables(run),
         disk_warning([run]) + run_warnings(run), None, [LEGEND])


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
    title = "เปรียบเทียบผล: " + " กับ ".join(r.label for r in runs)
    emit(args, "compare-" + "-vs-".join(labels), title, env_table(runs), tables, warnings, summary,
         [LEGEND, COMPARE_NOTE])


def main():
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--out", help="folder for report.md and report.html")
    common.add_argument("--no-files", action="store_true", help="stdout only")
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
        args.fn(args)
    except InputError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    except BrokenPipeError:   # e.g. piped into head
        os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
    return 0


if __name__ == "__main__":
    sys.exit(main())
