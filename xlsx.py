#!/usr/bin/env python3
"""xlsx.py - the Excel review sheet of one or more result folders (vmbench report xlsx).

    python3 -I xlsx.py DIR [DIR...] [--layout FILE] [-o OUT.xlsx] [--lang en|th]
    python3 -I xlsx.py --print-layout [--lang en|th]      a starting layout.tsv: every metric ID, by stage
    python3 -I xlsx.py --check-layout FILE                parse a layout.tsv and report the first error

The first DIR is the baseline; the default output is DIR1/review.xlsx. The rows come from the metric catalog
(lib/metrics.sh: every ID), arranged by an optional layout.tsv that the team keeps outside the repository (sections,
names, owner, priority, notes, hardware.json fields, rows filled in by hand). Every number comes from report.Run, so
it is the number of report.md.

openpyxl is needed to write the workbook (and only for that): `sudo apt-get install python3-openpyxl`, or a venv
whose python runs this file. --print-layout and --check-layout need only the standard library.
Exit codes: 0 done, 2 usage, input or layout error, or openpyxl missing.
"""
import argparse
import collections
import csv
import importlib.util
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CREATOR = "vmbench xlsx.py"   # written into the workbook properties; an existing -o file is replaced only if it has it


def _load(name):
    """report.py and hw.py sit next to this file; python3 -I does not put this folder on sys.path."""
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, name + ".py"))
    mod = importlib.util.module_from_spec(spec)
    sys.modules.setdefault(name, mod)
    spec.loader.exec_module(mod)
    return mod


report = _load("report")
hw = _load("hw")

# ---- messages ----
# Every text of the workbook, one dict per language with the same keys and placeholders (tests/test_xlsx.py checks
# that). Metric names, units, IDs and tool output are not translated. report.MESSAGES is not touched.
MESSAGES = {
    "en": {
        "col.section": "Section", "col.details": "Details", "col.tooling": "Tooling", "col.owner": "Owner",
        "col.priority": "Priority", "col.unit": "Unit", "col.better": "Better", "col.cv": "CV {label}",
        "col.rounds": "Rounds {label}", "col.diff": "Diff % {label} vs {base}", "col.verdict": "Verdict {label}",
        "col.round": "{label} r{n}", "col.note": "Note", "col.id": "ID",
        "better.higher": "Higher", "better.lower": "Lower", "better.none": "-",
        "verdict.better": "{label} better", "verdict.same": "not clearly different", "verdict.none": "-",
        "verdict.hw_same": "same", "verdict.hw_differs": "differs",
        "section.other": "Other measured values",
        "note.stage_not_run": "stage not run", "note.failed": "{steps}", "note.no_value": "no value",
        "note.no_value_problems": "no value ({steps})", "note.cv": "CV {cv}% ≥ {limit}%",
        "note.quick": "QUICK run: tiny sizes and durations",
        "note.no_hwjson": "no hardware.json", "note.hw_missing": "not in hardware.json",
        "note.manual": "filled in by hand",
        "sheet.review": "Review", "sheet.hardware": "Hardware", "sheet.summary": "Summary",
        "sheet.cpu": "CPU 1t vs max", "sheet.raw": "Raw {label}",
        "hw.title": "Hardware facts (hardware.json)", "hw.item": "Item", "hw.same": "Same?",
        "hw.yes": "yes", "hw.no": "no",
        "hw.missing": "No hardware.json for: {labels} (result of vmbench v0.1.0 or older, or the info stage failed).",
        "hw.txt_fallback": "{labels}: only hardware.txt; each of its sections is one cell (section \"hardware.txt\").",
        "summary.title": "vmbench review: {labels}", "summary.warnings": "Warnings", "summary.none": "none",
        "summary.legend": "How to read the Review sheet",
        "legend.median": "The value of a run is the median over its rounds, the same number as in report.md; CV = population standard deviation / mean over the rounds.",
        "legend.rounds": "Rounds = how many values the run has; the single values are in the columns <label> r1, r2, ...",
        "legend.grey": "Grey row = measured once: the variation is unknown.",
        "legend.orange": "Orange CV = {limit}% or more: interpret with care.",
        "legend.better": "Better: Higher / Lower says which direction is good; - is a context value that is never judged.",
        "legend.verdict": "Verdict (2 or more runs): a difference within the larger CV of the two runs, or within {min}%, is \"not clearly different\". Diff % is a value, not a formula.",
        "legend.hw": "Rows from hardware.json show text; their verdict is same / differs.",
        "cpu.test": "Test", "cpu.unit": "Unit", "cpu.one": "1 thread {label}", "cpu.max": "max {label}",
        "cpu.scaling": "max / 1t {label}",
        "err.openpyxl": "openpyxl is needed to write the workbook and was not found by {python} -I.\n"
                        "  install it:  sudo apt-get install python3-openpyxl\n"
                        "  or a venv:   python3 -m venv ~/.venv-vmbench && ~/.venv-vmbench/bin/pip install openpyxl\n"
                        "               ~/.venv-vmbench/bin/python {script} DIR ...",
        "err.exists": "{path} exists and was not written by vmbench; choose another -o or remove it",
        "wrote": "wrote {path}",
    },
    "th": {
        "col.section": "หัวข้อ", "col.details": "รายละเอียด", "col.tooling": "เครื่องมือ", "col.owner": "ผู้ทดสอบ",
        "col.priority": "ความสำคัญ", "col.unit": "หน่วย", "col.better": "ทิศทางที่ดี", "col.cv": "CV {label}",
        "col.rounds": "จำนวนรอบ {label}", "col.diff": "ต่าง % {label} เทียบ {base}", "col.verdict": "ผล {label}",
        "col.round": "{label} รอบ {n}", "col.note": "หมายเหตุ", "col.id": "ID",
        "better.higher": "สูงดี", "better.lower": "ต่ำดี", "better.none": "-",
        "verdict.better": "{label} ดีกว่า", "verdict.same": "ไม่ต่างชัดเจน", "verdict.none": "-",
        "verdict.hw_same": "เหมือนกัน", "verdict.hw_differs": "ต่างกัน",
        "section.other": "ค่าที่วัดอื่น ๆ",
        "note.stage_not_run": "ไม่ได้รัน stage นี้", "note.failed": "{steps}", "note.no_value": "ไม่มีค่า",
        "note.no_value_problems": "ไม่มีค่า ({steps})", "note.cv": "CV {cv}% ≥ {limit}%",
        "note.quick": "รันแบบ QUICK: ขนาดและเวลาสั้นมาก",
        "note.no_hwjson": "ไม่มี hardware.json", "note.hw_missing": "ไม่มีใน hardware.json",
        "note.manual": "กรอกเอง",
        "sheet.review": "Review", "sheet.hardware": "Hardware", "sheet.summary": "Summary",
        "sheet.cpu": "CPU 1t vs max", "sheet.raw": "Raw {label}",
        "hw.title": "ข้อมูลฮาร์ดแวร์ (hardware.json)", "hw.item": "รายการ", "hw.same": "เหมือนกัน?",
        "hw.yes": "ใช่", "hw.no": "ไม่",
        "hw.missing": "ไม่มี hardware.json ของ: {labels} (ผลจาก vmbench v0.1.0 หรือเก่ากว่า หรือ stage info ล้มเหลว)",
        "hw.txt_fallback": "{labels}: มีแค่ hardware.txt แต่ละหัวข้อของไฟล์อยู่ในเซลล์เดียว (หัวข้อ \"hardware.txt\")",
        "summary.title": "vmbench review: {labels}", "summary.warnings": "คำเตือน", "summary.none": "ไม่มี",
        "summary.legend": "วิธีอ่านชีท Review",
        "legend.median": "ค่าของแต่ละรันคือค่ามัธยฐานของทุกรอบ ตรงกับ report.md; CV = ส่วนเบี่ยงเบนมาตรฐาน (population) / ค่าเฉลี่ยของทุกรอบ",
        "legend.rounds": "จำนวนรอบ = จำนวนค่าที่รันนั้นมี ค่าแต่ละรอบอยู่ในคอลัมน์ <label> รอบ 1, 2, ...",
        "legend.grey": "แถวสีเทา = วัดรอบเดียว ไม่รู้ความแปรปรวน",
        "legend.orange": "CV สีส้ม = {limit}% ขึ้นไป ควรตีความอย่างระวัง",
        "legend.better": "ทิศทางที่ดี: สูงดี / ต่ำดี; - คือค่าประกอบที่ไม่ตัดสิน",
        "legend.verdict": "ผล (2 รันขึ้นไป): ส่วนต่างที่อยู่ภายใน CV ที่มากกว่าของสองรัน หรือไม่เกิน {min}% ถือว่า \"ไม่ต่างชัดเจน\" ต่าง % เป็นค่า ไม่ใช่สูตร",
        "legend.hw": "แถวจาก hardware.json เป็นข้อความ ผลคือ เหมือนกัน / ต่างกัน",
        "cpu.test": "การทดสอบ", "cpu.unit": "หน่วย", "cpu.one": "1 thread {label}", "cpu.max": "max {label}",
        "cpu.scaling": "max / 1t {label}",
        "err.openpyxl": "ต้องมี openpyxl เพื่อเขียนไฟล์ Excel แต่ {python} -I หาไม่พบ\n"
                        "  ติดตั้ง:     sudo apt-get install python3-openpyxl\n"
                        "  หรือ venv:   python3 -m venv ~/.venv-vmbench && ~/.venv-vmbench/bin/pip install openpyxl\n"
                        "               ~/.venv-vmbench/bin/python {script} DIR ...",
        "err.exists": "{path} มีอยู่แล้วและไม่ได้สร้างโดย vmbench เลือก -o อื่นหรือลบไฟล์นั้นก่อน",
        "wrote": "เขียน {path}",
    },
}
LANG = "en"


def t(key, **kw):
    return MESSAGES[LANG][key].format(**kw)


def set_lang(lang):
    global LANG
    if lang not in MESSAGES:
        raise report.InputError(f"unknown language '{lang}' (use one of: {', '.join(MESSAGES)})")
    LANG = lang
    report.set_lang(lang)


# ---- the metric catalog ----

Entry = collections.namedtuple("Entry", "id unit direction tool label what")


def catalog(path=None):
    """[Entry] from the table of lib/metrics.sh (the heredoc between cat <<'METRICS' and METRICS), in table order."""
    path = path or os.path.join(HERE, "lib", "metrics.sh")
    out, inside = [], False
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not inside:
                inside = line.strip() == "cat <<'METRICS'"
                continue
            if line == "METRICS":
                break
            parts = line.split("|")
            if len(parts) == 6:
                out.append(Entry(*parts))
    if not out:
        raise report.InputError(f"{path}: no metric table found")
    return out


# ---- layout.tsv ----

LAYOUT_COLUMNS = ["section", "id", "name", "owner", "priority", "note"]
HW_PATH = re.compile(r"^[a-z_]+(\[\])?(\.[a-z0-9_-]+(\[\])?)*$")
Row = collections.namedtuple("Row", "section kind key name owner priority note line")   # kind: metric, hw, manual


class LayoutError(report.InputError):
    pass


def read_layout(path, ids):
    """[Row] from a layout.tsv. ids: the catalog IDs (an unknown metric ID is an error naming the ID and the line)."""
    try:
        with open(path, encoding="utf-8-sig", newline="") as f:
            lines = f.read().splitlines()
    except OSError as e:
        raise LayoutError(f"{path}: cannot be read ({e.strerror})")
    except UnicodeDecodeError:
        raise LayoutError(f"{path}: not UTF-8 text")
    rows, header, section = [], None, ""
    for n, line in enumerate(lines, 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        cells = [c.strip() for c in line.split("\t")]
        if header is None:
            if [c.lower() for c in cells[:len(LAYOUT_COLUMNS)]] != LAYOUT_COLUMNS:
                raise LayoutError(f"{path}:{n}: the first line must be the header: {' | '.join(LAYOUT_COLUMNS)} "
                                  f"(tab separated), got: {' | '.join(cells)}")
            header = cells
            continue
        if len(cells) > len(LAYOUT_COLUMNS):
            raise LayoutError(f"{path}:{n}: {len(cells)} columns, at most {len(LAYOUT_COLUMNS)} (a tab inside a note?)")
        cells += [""] * (len(LAYOUT_COLUMNS) - len(cells))
        sec, ident, name, owner, prio, note = cells
        section = sec or section
        if ident.startswith("hw:"):
            path_ = ident[3:]
            if not HW_PATH.match(path_):
                raise LayoutError(f"{path}:{n}: '{ident}' is not a hardware.json path (e.g. hw:cpu.stepping, hw:nics[].firmware)")
            rows.append(Row(section, "hw", path_, name, owner, prio, note, n))
        elif ident:
            if ident not in ids:
                raise LayoutError(f"{path}:{n}: unknown metric ID '{ident}' (see: vmbench run --metrics)")
            rows.append(Row(section, "metric", ident, name, owner, prio, note, n))
        else:
            if not name:
                raise LayoutError(f"{path}:{n}: a row without an ID needs a name")
            rows.append(Row(section, "manual", "", name, owner, prio, note, n))
    if header is None:
        raise LayoutError(f"{path}: empty (the first line must be the header: {' | '.join(LAYOUT_COLUMNS)})")
    if not section:
        raise LayoutError(f"{path}: no section name at all (fill the section column of the first row)")
    return rows


def default_rows(entries, measured):
    """Every catalog ID plus any measured ID that the catalog does not know, by stage (no layout)."""
    known = {e.id for e in entries}
    ids = [e.id for e in entries] + [i for i in measured if i not in known]
    ids = sorted(dict.fromkeys(ids), key=report.id_key)
    return [Row(report.section_title(report.section_of(i)), "metric", i, "", "", "", "", 0) for i in ids]


def layout_rows(layout, entries, measured):
    """The layout rows, then a last section with every catalog or measured ID the layout does not name."""
    named = {r.key for r in layout if r.kind == "metric"}
    known = {e.id for e in entries}
    rest = [e.id for e in entries if e.id not in named] + [i for i in measured if i not in known and i not in named]
    rest = sorted(dict.fromkeys(rest), key=report.id_key)
    return layout + [Row(t("section.other"), "metric", i, "", "", "", "", 0) for i in rest]


def print_layout(entries):
    """A starting layout.tsv: the header and one row per catalog ID, in report order; name/owner/priority empty."""
    w = csv.writer(sys.stdout, delimiter="\t", lineterminator="\n", quoting=csv.QUOTE_NONE, escapechar="\\")
    w.writerow(LAYOUT_COLUMNS)
    for e in sorted(entries, key=lambda e: report.id_key(e.id)):
        w.writerow([report.section_title(report.section_of(e.id)), e.id, "", "", "", ""])


# ---- values ----

def hw_json(run):
    """hardware.json of a run as a dict, None when there is none (or it cannot be read)."""
    p = os.path.join(run.path, "hardware.json")
    if not os.path.isfile(p):
        return None
    try:
        with open(p, encoding="utf-8") as f:
            d = json.load(f)
        return d if isinstance(d, dict) else None
    except (OSError, ValueError):
        return None


_MISSING = object()


def hw_text(v):
    """A hardware.json value as cell text."""
    if v is None:
        return ""
    if isinstance(v, bool):
        return "yes" if v else "no"
    if isinstance(v, float) and v == int(v):
        return str(int(v))
    if isinstance(v, dict):
        return ", ".join(f"{k}: {hw_text(x)}" for k, x in v.items())
    if isinstance(v, list):
        return "\n".join(hw_text(x) for x in v)
    return str(v)


def hw_get(d, path):
    """The value at a layout path such as cpu.stepping or nics[].firmware; _MISSING when the path is not there."""
    cur = [d]
    for part in path.split("."):
        many = part.endswith("[]")
        key = part[:-2] if many else part
        nxt = []
        for c in cur:
            if not isinstance(c, dict) or key not in c:
                return _MISSING
            v = c[key]
            if many:
                if not isinstance(v, list):
                    return _MISSING
                nxt.extend(v)
            else:
                nxt.append(v)
        cur = nxt
        if "[]" in path and not cur:
            return []
    return cur if "[]" in path else cur[0]


def match_steps(ident, problems):
    """The FAIL/SKIP steps of the stage of ident that name this test (step 'fio randread8k' ~ disk.fio.db-randread-8k)."""
    stage = ident.split(".")[0]
    flat = re.sub(r"[^a-z0-9]", "", ident.lower())
    own = [p for p in problems if p[0] == stage]
    hits = []
    for p in own:
        words = [re.sub(r"[^a-z0-9]", "", w) for w in p[1].lower().split()]
        words = [w for w in words if len(w) >= 4 and not re.fullmatch(r"r\d+", w)]
        if words and words[-1] in flat:
            hits.append(p)
    return hits, own


def steps_text(problems):
    return "; ".join(f"{s} / {step} = {res}" for s, step, res in problems)


def missing_note(run, ident):
    stage = ident.split(".")[0]
    has_stage = stage in run.stages if run.stages else any(m.id.split(".")[0] == stage for m in run.metrics)
    if not has_stage:
        return t("note.stage_not_run")
    hits, own = match_steps(ident, run.problems)
    if hits:
        return t("note.failed", steps=steps_text(hits))
    if own:
        return t("note.no_value_problems", steps=steps_text(own))
    return t("note.no_value")


# ---- the workbook ----

class Book:
    """openpyxl objects and styles, created only when a workbook is written."""

    def __init__(self):
        try:
            import openpyxl
            from openpyxl.styles import Alignment, Font, PatternFill
            from openpyxl.utils import get_column_letter
        except ImportError:
            raise SystemExit(self.no_openpyxl())
        self.openpyxl = openpyxl
        self.letter = get_column_letter
        self.bold = Font(bold=True)
        self.title = Font(bold=True, size=13)
        self.white = Font(bold=True, color="FFFFFF")
        self.head_fill = PatternFill("solid", fgColor="DDEBF7")
        self.section_fill = PatternFill("solid", fgColor="305496")
        self.once_fill = PatternFill("solid", fgColor="EDEDED")
        self.noisy_fill = PatternFill("solid", fgColor="FCE4D6")
        self.wrap = Alignment(wrap_text=True, vertical="top")
        self.top = Alignment(vertical="top")
        self.wb = openpyxl.Workbook()
        self.wb.properties.creator = CREATOR
        self.sheets = 0

    @staticmethod
    def no_openpyxl():
        print("error: " + t("err.openpyxl", python=os.path.basename(sys.executable) or "python3",
                             script=os.path.abspath(__file__)), file=sys.stderr)
        return 2

    def sheet(self, title):
        title = re.sub(r"[\[\]:*?/\\]", "_", title)[:31] or "Sheet"
        used = {ws.title for ws in self.wb.worksheets} if self.sheets else set()
        base, n = title, 2
        while title in used:
            suffix = f" ({n})"
            title = base[:31 - len(suffix)] + suffix
            n += 1
        if self.sheets == 0:
            ws = self.wb.active
            ws.title = title
        else:
            ws = self.wb.create_sheet(title)
        self.sheets += 1
        return ws

    def header(self, ws, row, values):
        for i, v in enumerate(values, 1):
            c = ws.cell(row, i, v)
            c.font, c.fill, c.alignment = self.bold, self.head_fill, self.wrap

    def widths(self, ws, ws_widths):
        for i, w in enumerate(ws_widths, 1):
            ws.column_dimensions[self.letter(i)].width = w


NUM = "#,##0.00"
PCT = "0.0%"


def review_sheet(book, runs, rows, entries):
    ws = book.sheet(t("sheet.review"))
    base = runs[0]
    by_id = {e.id: e for e in entries}
    lookup = [{m.id: m for m in r.metrics} for r in runs]
    hws = [hw_json(r) for r in runs]
    maxr = [max((len(m.values) for m in r.metrics), default=0) for r in runs]

    cols = [t("col.section"), t("col.details"), t("col.tooling"), t("col.owner"), t("col.priority"),
            t("col.unit"), t("col.better")]
    col = {}
    for i, r in enumerate(runs):
        col[("v", i)] = len(cols) + 1; cols.append(r.label)
        col[("cv", i)] = len(cols) + 1; cols.append(t("col.cv", label=r.label))
        col[("n", i)] = len(cols) + 1; cols.append(t("col.rounds", label=r.label))
    for i, r in enumerate(runs[1:], 1):
        col[("diff", i)] = len(cols) + 1; cols.append(t("col.diff", label=r.label, base=base.label))
        col[("verdict", i)] = len(cols) + 1; cols.append(t("col.verdict", label=r.label))
    for i, r in enumerate(runs):
        for k in range(1, maxr[i] + 1):
            col[("r", i, k)] = len(cols) + 1; cols.append(t("col.round", label=r.label, n=k))
    col["note"] = len(cols) + 1; cols.append(t("col.note"))
    col["id"] = len(cols) + 1; cols.append(t("col.id"))
    book.header(ws, 1, cols)
    width = len(cols)

    quick = [r.info.get("quick", "0") not in ("0", "") for r in runs]
    y, section = 1, None
    for row in rows:
        if row.section != section:
            section = row.section
            y += 1
            for j in range(1, width + 1):
                ws.cell(y, j).fill = book.section_fill
            ws.cell(y, 1, section).font = book.white
        y += 1
        notes = []
        ws.cell(y, 1, section)
        ws.cell(y, 4, row.owner or None)
        ws.cell(y, 5, row.priority or None)
        if row.kind == "metric":
            e = by_id.get(row.key)
            ms = [lk.get(row.key) for lk in lookup]
            first = next((m for m in ms if m), None)
            ws.cell(y, 2, row.name or (e.what if e else (first.name if first else row.key)))
            ws.cell(y, 3, e.tool if e else None)
            unit = first.unit if first and (not e or e.unit == "varies") else (e.unit if e else None)
            ws.cell(y, 6, unit)
            d = {"higher": 1, "lower": -1, "none": 0}.get(e.direction) if e else (
                report.direction(first.name, first.unit) if first else None)
            ws.cell(y, 7, {1: t("better.higher"), -1: t("better.lower"), 0: t("better.none")}.get(d))
            for i, (r, m) in enumerate(zip(runs, ms)):
                who = f"{r.label}: " if len(runs) > 1 else ""
                if m is None:
                    notes.append(who + missing_note(r, row.key))
                    continue
                ws.cell(y, col[("v", i)], m.median).number_format = NUM
                ws.cell(y, col[("n", i)], len(m.values))
                if m.cv is not None:
                    c = ws.cell(y, col[("cv", i)], m.cv / 100)
                    c.number_format = PCT
                    if m.cv >= report.HIGH_CV:
                        c.fill = book.noisy_fill
                        notes.append(who + t("note.cv", cv=f"{m.cv:.1f}", limit=f"{report.HIGH_CV:.0f}"))
                for k, v in enumerate(m.values, 1):
                    ws.cell(y, col[("r", i, k)], v).number_format = NUM
                if quick[i]:
                    notes.append(who + t("note.quick"))
            for i in range(1, len(runs)):
                b, o = ms[0], ms[i]
                if b is None or o is None:
                    ws.cell(y, col[("verdict", i)], t("verdict.none"))
                    continue
                diff, verdict = report.judge(b, o)
                if diff is not None and verdict is not None:
                    ws.cell(y, col[("diff", i)], diff / 100).number_format = PCT
                ws.cell(y, col[("verdict", i)], {1: t("verdict.better", label=runs[i].label),
                                                 -1: t("verdict.better", label=base.label),
                                                 0: t("verdict.same")}.get(verdict, t("verdict.none")))
            present = [m for m in ms if m]
            if present and all(len(m.values) < 2 for m in present):
                for j in range(2, width + 1):
                    if ws.cell(y, j).fill != book.noisy_fill:
                        ws.cell(y, j).fill = book.once_fill
            ws.cell(y, col["id"], row.key)
        elif row.kind == "hw":
            ws.cell(y, 2, row.name or row.key)
            ws.cell(y, 3, "hardware.json")
            texts = []
            for i, (r, d) in enumerate(zip(runs, hws)):
                who = f"{r.label}: " if len(runs) > 1 else ""
                if d is None:
                    notes.append(who + t("note.no_hwjson"))
                    texts.append(None)
                    continue
                v = hw_get(d, row.key)
                if v is _MISSING:
                    notes.append(who + t("note.hw_missing"))
                    texts.append(None)
                    continue
                s = hw_text(v)
                texts.append(s)
                ws.cell(y, col[("v", i)], s).alignment = book.wrap
            for i in range(1, len(runs)):
                if texts[0] is None or texts[i] is None:
                    ws.cell(y, col[("verdict", i)], t("verdict.none"))
                else:
                    ws.cell(y, col[("verdict", i)], t("verdict.hw_same") if texts[0] == texts[i] else t("verdict.hw_differs"))
            ws.cell(y, col["id"], "hw:" + row.key)
        else:
            ws.cell(y, 2, row.name)
        if row.note:
            notes.append(row.note)
        if notes:
            ws.cell(y, col["note"], " · ".join(notes)).alignment = book.wrap
    ws.freeze_panes = "H2"
    ws.auto_filter.ref = f"A1:{book.letter(width)}1"
    book.widths(ws, [14, 44, 12, 14, 10, 10, 8] + [14, 8, 8] * len(runs) + [12, 22] * (len(runs) - 1)
                + [11] * sum(maxr) + [44, 34])
    return ws


def flatten_hw(d):
    """[(section, item, text)] of a hardware.json: scalars and small dicts one row each, a list of records one row
    per record (named by its locator / name / ctrl)."""
    out = []

    def walk(section, prefix, v):
        if isinstance(v, dict) and section not in ("nvme_models",) and not prefix.endswith(
                ("configured_speeds", "temperatures", "fans", "offloads")):
            for k, x in v.items():
                walk(section, f"{prefix}.{k}" if prefix else k, x)
        elif isinstance(v, list) and v and all(isinstance(x, dict) for x in v):
            for x in v:
                name = next((x.get(k) for k in ("locator", "name", "ctrl") if x.get(k)), "?")
                rest = {k: y for k, y in x.items() if y != name}
                out.append((section, f"{prefix} {name}", "; ".join(f"{k}={hw_text(y)}" for k, y in rest.items())))
        else:
            out.append((section, prefix or section, hw_text(v)))

    for key, v in d.items():
        if key == "schema":
            continue
        walk(key, key if not isinstance(v, dict) else "", v)
    return out


def hardware_txt_sections(run):
    p = os.path.join(run.path, "hardware.txt")
    if not os.path.isfile(p):
        return None
    out, cur = collections.OrderedDict(), None
    with open(p, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")
            if line.startswith("--- "):
                cur = line[4:].strip()
                out[cur] = []
            elif cur is not None:
                out[cur].append(line)
    return [("hardware.txt", k, "\n".join(v)) for k, v in out.items()]


def natural(s):
    return [int(p) if p.isdigit() else p for p in re.split(r"(\d+)", s)]


def hardware_sheet(book, runs):
    ws = book.sheet(t("sheet.hardware"))
    ws.cell(1, 1, t("hw.title")).font = book.title
    per_run, missing, txt_only = [], [], []
    for r in runs:
        d = hw_json(r)
        if d is not None:
            per_run.append({(s, i): v for s, i, v in flatten_hw(d)})
            continue
        missing.append(r.label)
        txt = hardware_txt_sections(r)
        if txt:
            txt_only.append(r.label)
        per_run.append({(s, i): v for s, i, v in (txt or [])})
    notes = []
    if missing:
        notes.append(t("hw.missing", labels=", ".join(missing)))
    if txt_only:
        notes.append(t("hw.txt_fallback", labels=", ".join(txt_only)))
    for k, n in enumerate(notes):
        ws.cell(2 + k, 1, n)
    y = 3 + len(notes)
    two = len(runs) > 1
    book.header(ws, y, [t("col.section"), t("hw.item")] + [r.label for r in runs] + ([t("hw.same")] if two else []))
    order = {k: n for n, k in enumerate(hw.skeleton())}
    keys = []
    for p in per_run:
        for k in p:
            if k not in keys:
                keys.append(k)
    keys.sort(key=lambda k: (k[0] == "hardware.txt", order.get(k[0], len(order)), natural(k[1]) if " " in k[1] else [], ))
    with_json = [i for i, r in enumerate(runs) if r.label not in missing]
    for s, item in keys:
        y += 1
        ws.cell(y, 1, s)
        ws.cell(y, 2, item)
        for i, p in enumerate(per_run):
            if (s, item) in p:
                ws.cell(y, 3 + i, p[(s, item)]).alignment = book.wrap
        if two:
            vals = [per_run[i].get((s, item)) for i in with_json]
            same = "-" if len(with_json) < 2 or s == "hardware.txt" else (t("hw.yes") if len(set(vals)) == 1 else t("hw.no"))
            ws.cell(y, 3 + len(runs), same)
    ws.freeze_panes = ws.cell(4 + len(notes), 3).coordinate
    book.widths(ws, [12, 30] + [48] * len(runs) + [10])


def summary_sheet(book, runs):
    ws = book.sheet(t("sheet.summary"))
    ws.cell(1, 1, t("summary.title", labels=" vs ".join(r.label for r in runs))).font = book.title
    env = report.env_table(runs)
    book.header(ws, 3, env.headers)
    y = 3
    for row in env.rows:
        y += 1
        for j, v in enumerate(row, 1):
            ws.cell(y, j, report.cell_text(v)).alignment = book.top
    warnings = report.compare_warnings(runs) + report.disk_warning(runs) if len(runs) > 1 else report.disk_warning(runs)
    for r in runs:
        warnings += report.run_warnings(r)
    y += 2
    ws.cell(y, 1, t("summary.warnings")).font = book.bold
    for w in warnings or [t("summary.none")]:
        y += 1
        ws.cell(y, 1, w)
    y += 2
    ws.cell(y, 1, t("summary.legend")).font = book.bold
    for line in (t("legend.median"), t("legend.rounds"), t("legend.grey"),
                 t("legend.orange", limit=f"{report.HIGH_CV:.0f}"), t("legend.better"),
                 t("legend.verdict", min=f"{report.MIN_DIFF:.0f}"), t("legend.hw")):
        y += 1
        ws.cell(y, 1, line)
    book.widths(ws, [28] + [60] * len(runs))


def cpu_sheet(book, runs):
    ws = book.sheet(t("sheet.cpu"))
    cols = ["ID", t("cpu.test"), t("cpu.unit")]
    for r in runs:
        cols += [t("cpu.one", label=r.label), t("cpu.max", label=r.label), t("cpu.scaling", label=r.label)]
    book.header(ws, 1, cols)
    pairs = collections.OrderedDict()
    for i, r in enumerate(runs):
        for m in r.metrics:
            if m.id.startswith("cpu.") and m.variant in ("1t", "max"):
                pairs.setdefault(report.id_base(m.id), [dict() for _ in runs])[i][m.variant] = m
    y = 1
    for b in sorted(pairs, key=report.id_key):
        y += 1
        first = next(m for d in pairs[b] for m in d.values())
        ws.cell(y, 1, b)
        ws.cell(y, 2, first.base)
        ws.cell(y, 3, first.unit)
        for i, d in enumerate(pairs[b]):
            one, mx = d.get("1t"), d.get("max")
            c0 = 4 + 3 * i
            if one:
                ws.cell(y, c0, one.median).number_format = NUM
            if mx:
                ws.cell(y, c0 + 1, mx.median).number_format = NUM
            if one and mx and one.median:
                ws.cell(y, c0 + 2, mx.median / one.median).number_format = NUM
    ws.freeze_panes = "D2"
    book.widths(ws, [34, 30, 10] + [13, 13, 11] * len(runs))


def raw_sheet(book, run):
    ws = book.sheet(t("sheet.raw", label=run.label))
    y = 0
    with open(os.path.join(run.path, "results.tsv"), encoding="utf-8", errors="replace", newline="") as f:
        for r in csv.reader(f, delimiter="\t"):
            y += 1
            for j, v in enumerate(r, 1):
                if y > 1:
                    try:
                        v = float(v) if re.fullmatch(r"-?\d+(\.\d+)?([eE][-+]?\d+)?", v) else v
                        v = int(v) if isinstance(v, float) and j == 5 and v == int(v) else v
                    except ValueError:
                        pass
                c = ws.cell(y, j, v)
                if y == 1:
                    c.font, c.fill = book.bold, book.head_fill
    ws.freeze_panes = "A2"
    book.widths(ws, [36, 34, 14, 10, 7])


def check_target(book, path):
    if not os.path.exists(path):
        return
    try:
        with open(path, "rb") as f:
            wb = book.openpyxl.load_workbook(f, read_only=True)
            creator = wb.properties.creator
            wb.close()
    except Exception:  # noqa: BLE001 - anything that is not a readable workbook is not ours
        creator = None
    if creator != CREATOR:
        raise report.InputError(t("err.exists", path=path))


def write(dirs, out, layout_path=None):
    entries = catalog()
    ids = {e.id for e in entries}
    layout = read_layout(layout_path, ids) if layout_path else None
    runs = [report.Run(d) for d in dirs]
    report.unique_labels(runs)
    measured = list(dict.fromkeys(m.id for r in runs for m in r.metrics))
    rows = layout_rows(layout, entries, measured) if layout else default_rows(entries, measured)
    out = out or os.path.join(runs[0].path, "review.xlsx")
    book = Book()
    check_target(book, out)
    review_sheet(book, runs, rows, entries)
    hardware_sheet(book, runs)
    summary_sheet(book, runs)
    cpu_sheet(book, runs)
    for r in runs:
        raw_sheet(book, r)
    tmp = out + ".tmp"
    try:
        book.wb.save(tmp)
        os.replace(tmp, out)
    except OSError as e:
        if os.path.exists(tmp):
            os.remove(tmp)
        raise report.InputError(f"{out}: cannot be written ({e.strerror})")
    print(t("wrote", path=out), file=sys.stderr)
    return out


def main(argv=None):
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")
    p = argparse.ArgumentParser(prog="vmbench report xlsx",
                                description="Excel review sheet of result folders; the first folder is the baseline.")
    p.add_argument("dirs", nargs="*", metavar="DIR", help="result folders")
    p.add_argument("--layout", metavar="FILE", help="layout.tsv: sections, names, owner, priority, notes, hw: rows")
    p.add_argument("-o", "--out", metavar="OUT.xlsx", help="output file (default: DIR1/review.xlsx)")
    p.add_argument("--lang", choices=tuple(MESSAGES), default=None, help="language (default: $VMBENCH_LANG, else en)")
    p.add_argument("--print-layout", action="store_true", help="print a starting layout.tsv and exit")
    p.add_argument("--check-layout", metavar="FILE", help="check a layout.tsv and exit")
    a = p.parse_args(argv)
    try:
        set_lang(a.lang or os.environ.get("VMBENCH_LANG") or "en")
        if a.print_layout:
            if a.dirs or a.layout or a.out or a.check_layout:
                p.error("--print-layout takes no other arguments")
            print_layout(catalog())
            return 0
        if a.check_layout:
            if a.dirs or a.layout or a.out:
                p.error("--check-layout takes no other arguments")
            rows = read_layout(a.check_layout, {e.id for e in catalog()})
            print(f"{a.check_layout}: ok, {len(rows)} rows "
                  f"({sum(r.kind == 'metric' for r in rows)} metric, {sum(r.kind == 'hw' for r in rows)} hw:, "
                  f"{sum(r.kind == 'manual' for r in rows)} by hand)")
            return 0
        if not a.dirs:
            p.error("at least one result folder is needed")
        write(a.dirs, a.out, a.layout)
    except report.InputError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    except BrokenPipeError:
        os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
    return 0


if __name__ == "__main__":
    sys.exit(main())
