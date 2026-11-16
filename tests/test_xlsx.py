"""Tests for xlsx.py (vmbench report xlsx / layout): the catalog, layout.tsv, and the workbook read back with openpyxl.

The workbook tests are skipped when openpyxl is not installed for this python (CI installs python3-openpyxl); the
catalog, layout and "openpyxl missing" tests always run. Only the synthetic folders under tests/fixtures are used.
"""
import importlib.util
import os
import string
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
FIX = os.path.join(HERE, "fixtures")
XLSX = os.path.join(ROOT, "xlsx.py")
LAYOUT = os.path.join(FIX, "layout-sample.tsv")

spec = importlib.util.spec_from_file_location("xlsx_mod", XLSX)
xlsx = importlib.util.module_from_spec(spec)
sys.modules["xlsx_mod"] = xlsx
spec.loader.exec_module(xlsx)
report = xlsx.report

try:
    import openpyxl
except ImportError:
    openpyxl = None
need_openpyxl = unittest.skipIf(openpyxl is None, "openpyxl is not installed (sudo apt-get install python3-openpyxl)")


def run(*args, flags=("-I", "-B"), env=None, cwd=None):
    e = {k: v for k, v in os.environ.items() if k != "VMBENCH_LANG"}
    e.update(env or {})
    return subprocess.run([sys.executable, *flags, XLSX, *args], capture_output=True, text=True, encoding="utf-8",
                          env=e, cwd=cwd)


def metrics_table():
    out = subprocess.run(["bash", os.path.join(ROOT, "vmbench"), "run", "--metrics"], capture_output=True, text=True,
                         check=True).stdout
    return [line.split("|")[0] for line in out.splitlines() if line.count("|") == 5]


def sheet_rows(ws, header_row=1):
    """[dict] of the rows under the header row, keyed by the header text; section rows have only column A."""
    head = [c.value for c in ws[header_row]]
    out = []
    for r in ws.iter_rows(min_row=header_row + 1, values_only=True):
        out.append(dict(zip(head, r)))
    return out


def load(path):
    """openpyxl.load_workbook without leaving the file open (a path argument does, under -W error::ResourceWarning)."""
    with open(path, "rb") as f:
        return openpyxl.load_workbook(f)


def placeholders(message):
    return sorted(name for _, name, _, _ in string.Formatter().parse(message) if name is not None)


class Catalog(unittest.TestCase):
    def test_catalog_is_the_metric_table(self):
        self.assertEqual([e.id for e in xlsx.catalog()], metrics_table())

    def test_print_layout_has_a_header_and_every_id(self):
        p = subprocess.run(["bash", os.path.join(ROOT, "vmbench"), "report", "layout"], capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        lines = p.stdout.splitlines()
        self.assertEqual(len(lines), len(metrics_table()) + 1)
        self.assertEqual(lines[0].split("\t"), xlsx.LAYOUT_COLUMNS)
        ids = [line.split("\t")[1] for line in lines[1:]]
        self.assertEqual(sorted(ids), sorted(metrics_table()))
        self.assertEqual(ids, sorted(ids, key=report.id_key))
        # the printed file is a valid layout
        with tempfile.TemporaryDirectory() as d:
            f = os.path.join(d, "layout.tsv")
            with open(f, "w", encoding="utf-8") as fh:
                fh.write(p.stdout)
            self.assertEqual(run("--check-layout", f).returncode, 0)

    def test_print_layout_in_thai(self):
        p = run("--print-layout", "--lang", "th")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn(report.MESSAGES["th"]["section.info"], p.stdout)


class Layout(unittest.TestCase):
    ids = {e.id for e in xlsx.catalog()}

    def layout(self, text):
        d = tempfile.mkdtemp()
        self.addCleanup(lambda: (os.remove(os.path.join(d, "l.tsv")), os.rmdir(d)))
        with open(os.path.join(d, "l.tsv"), "w", encoding="utf-8") as f:
            f.write(text)
        return os.path.join(d, "l.tsv")

    def test_sample(self):
        rows = xlsx.read_layout(LAYOUT, self.ids)
        self.assertEqual([r.kind for r in rows], ["hw", "hw", "metric", "metric", "metric", "hw", "hw", "hw", "metric",
                                                  "metric", "manual", "manual"])
        self.assertEqual(rows[1].section, "CPU")          # an empty section keeps the one above
        self.assertEqual(rows[-1].section, "Application")
        self.assertEqual(rows[2].note, "not for x86 vs ARM (compiler)")

    def test_unknown_id_names_the_id_and_the_line(self):
        f = self.layout("section\tid\tname\towner\tpriority\tnote\nCPU\tcpu.bogus.test\n")
        with self.assertRaises(xlsx.LayoutError) as e:
            xlsx.read_layout(f, self.ids)
        self.assertIn(":2: unknown metric ID 'cpu.bogus.test'", str(e.exception))
        p = run("--check-layout", f)
        self.assertEqual(p.returncode, 2)
        self.assertIn("cpu.bogus.test", p.stderr)

    def test_errors(self):
        cases = {"wrong header": ("id\tsection\n", "the first line must be the header"),
                 "empty": ("# only a comment\n", "empty"),
                 "bad hw path": ("section\tid\tname\towner\tpriority\tnote\nCPU\thw:CPU Model\n", "not a hardware.json path"),
                 "no name": ("section\tid\tname\towner\tpriority\tnote\nApp\t\t\n", "needs a name"),
                 "too many columns": ("section\tid\tname\towner\tpriority\tnote\nCPU\tcpu.sysbench.prime.1t\ta\tb\tc\td\te\n", "at most 6"),
                 "no section": ("section\tid\tname\towner\tpriority\tnote\n\tcpu.sysbench.prime.1t\n", "no section name")}
        for name, (text, msg) in cases.items():
            with self.subTest(name), self.assertRaises(xlsx.LayoutError) as e:
                xlsx.read_layout(self.layout(text), self.ids)
            self.assertIn(msg, str(e.exception))

    def test_short_rows_comments_and_bom(self):
        f = self.layout("﻿section\tid\tname\towner\tpriority\tnote\n# comment\n\nCPU\tcpu.sysbench.prime.1t\n")
        rows = xlsx.read_layout(f, self.ids)
        self.assertEqual([(r.section, r.key, r.name) for r in rows], [("CPU", "cpu.sysbench.prime.1t", "")])

    def test_unlisted_ids_go_to_other(self):
        entries = xlsx.catalog()
        rows = xlsx.layout_rows(xlsx.read_layout(LAYOUT, self.ids), entries, ["cpu.row99.legacy-thing"])
        other = [r.key for r in rows if r.section == xlsx.t("section.other")]
        self.assertNotIn("cpu.sysbench.prime.1t", other)
        self.assertIn("cpu.7z.rating.max", other)
        self.assertIn("cpu.row99.legacy-thing", other)
        self.assertEqual(len(other), len(entries) - 5 + 1)


class Messages(unittest.TestCase):
    def test_same_keys_and_placeholders(self):
        en, th = xlsx.MESSAGES["en"], xlsx.MESSAGES["th"]
        self.assertEqual(set(en), set(th))
        for k in en:
            self.assertEqual(placeholders(en[k]), placeholders(th[k]), k)

    def test_report_messages_are_not_extended(self):
        self.assertFalse(any(k.startswith(("col.section", "sheet.", "hw.", "legend.")) for k in report.MESSAGES["en"]))


class NoOpenpyxl(unittest.TestCase):
    def test_exit_2_with_install_hint(self):
        # -S: no site-packages, so no openpyxl whatever this machine has installed
        with tempfile.TemporaryDirectory() as d:
            p = run(os.path.join(FIX, "vm-a"), "-o", os.path.join(d, "x.xlsx"), flags=("-I", "-B", "-S"))
            self.assertEqual(p.returncode, 2, p.stderr)
            self.assertIn("sudo apt-get install python3-openpyxl", p.stderr)
            self.assertFalse(os.path.exists(os.path.join(d, "x.xlsx")))
        self.assertEqual(run("--print-layout", flags=("-I", "-B", "-S")).returncode, 0)
        self.assertEqual(run("--check-layout", LAYOUT, flags=("-I", "-B", "-S")).returncode, 0)

    def test_report_show_and_compare_do_not_need_openpyxl(self):
        rp = os.path.join(ROOT, "report.py")
        for args in (["show", os.path.join(FIX, "vm-a")], ["compare", os.path.join(FIX, "vm-a"), os.path.join(FIX, "vm-b")]):
            p = subprocess.run([sys.executable, "-I", "-B", "-S", rp, *args, "--no-files"], capture_output=True, text=True)
            self.assertEqual(p.returncode, 0, p.stderr)


@need_openpyxl
class Workbook(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def make(self, *dirs, layout=None, lang=None, name="out.xlsx"):
        out = os.path.join(self.tmp.name, name)
        args = [os.path.join(FIX, d) for d in dirs] + ["-o", out]
        if layout:
            args += ["--layout", layout]
        if lang:
            args += ["--lang", lang]
        p = run(*args)
        self.assertEqual(p.returncode, 0, p.stderr)
        return load(out)

    def test_generic_every_id_and_the_medians_of_report(self):
        wb = self.make("vm-a")
        self.assertEqual(wb.sheetnames, ["Review", "Hardware", "Summary", "CPU 1t vs max", "Raw vm-a"])
        ws = wb["Review"]
        self.assertEqual(ws.freeze_panes, "H2")
        head = [c.value for c in ws[1]]
        self.assertEqual(head[:10], ["Section", "Details", "Tooling", "Owner", "Priority", "Unit", "Better",
                                     "vm-a", "CV vm-a", "Rounds vm-a"])
        self.assertEqual(head[-2:], ["Note", "ID"])
        rows = [r for r in sheet_rows(ws) if r["ID"]]
        ids = [r["ID"] for r in rows]
        self.assertEqual(sorted(ids), sorted(metrics_table()))
        self.assertEqual(ids, sorted(ids, key=report.id_key))
        by = {r["ID"]: r for r in rows}
        run_ = report.Run(os.path.join(FIX, "vm-a"))
        for m in run_.metrics:
            self.assertAlmostEqual(by[m.id]["vm-a"], m.median, msg=m.id)
            self.assertEqual(by[m.id]["Rounds vm-a"], len(m.values), m.id)
            for k, v in enumerate(m.values, 1):
                self.assertAlmostEqual(by[m.id][f"vm-a r{k}"], v)
        # a stage that did not run, and the section rows
        self.assertEqual(by["nvme.fio.seq-read-1m.all-disks"]["Note"], "stage not run")
        sections = [r["Section"] for r in sheet_rows(ws) if not r["ID"]]
        self.assertEqual(sections[:3], ["CPU", "Memory", "Disk"])
        self.assertEqual(by["cpu.sysbench.prime.1t"]["Better"], "Higher")
        self.assertEqual(by["mem.lmbench.lat-mem-rd.1t"]["Better"], "Lower")
        # a value measured once is grey, CV is a fraction with a percent format
        cv_row = next(i for i, r in enumerate(ws.iter_rows(min_row=1, values_only=True), 1) if r[-1] == "cpu.sysbench.prime.1t")
        self.assertEqual(ws.cell(cv_row, 9).number_format, "0.0%")
        once_row = next(i for i, r in enumerate(ws.iter_rows(min_row=1, values_only=True), 1) if r[-1] == "mem.stream.triad.max")
        self.assertEqual(ws.cell(once_row, 8).fill.fgColor.rgb[-6:], "EDEDED")

    def test_raw_sheet_is_results_tsv(self):
        wb = self.make("vm-a")
        ws = wb["Raw vm-a"]
        with open(os.path.join(FIX, "vm-a", "results.tsv"), encoding="utf-8") as f:
            lines = [l.rstrip("\n").split("\t") for l in f if l.strip()]
        self.assertEqual(ws.max_row, len(lines))
        self.assertEqual([c.value for c in ws[1]], lines[0])
        self.assertAlmostEqual(ws.cell(2, 3).value, float(lines[1][2]))

    def test_layout_order_headings_notes_and_other(self):
        wb = self.make("new-a", layout=LAYOUT)
        ws = wb["Review"]
        rows = sheet_rows(ws)
        sections = [r["Section"] for r in rows if not r["ID"] and not r["Details"]]
        self.assertEqual(sections, ["CPU", "Memory", "Disk", "NVMe", "Application", "Other measured values"])
        listed = [r["ID"] or r["Details"] for r in rows if r["ID"] or r["Details"]][:12]
        self.assertEqual(listed, ["hw:cpu.model", "hw:cpu.stepping", "cpu.sysbench.prime.1t", "cpu.sysbench.prime.max",
                                  "mem.stream.triad.max", "hw:memory.populated", "hw:nics[].firmware", "hw:cpu.no_such_key",
                                  "disk.fio.db-randread-8k", "nvme.fio.seq-read-1m.all-disks", "Node JS transactions",
                                  "PSU failover"])
        by = {r["ID"] or r["Details"]: r for r in rows}
        self.assertEqual(by["cpu.sysbench.prime.1t"]["Details"], "sysbench 1 thread")
        self.assertEqual(by["cpu.sysbench.prime.1t"]["Owner"], "Team A")
        self.assertEqual(by["cpu.sysbench.prime.1t"]["Note"], "not for x86 vs ARM (compiler)")
        self.assertTrue(by["cpu.sysbench.prime.max"]["Details"].startswith("Prime-number counting"))   # name from the catalog
        self.assertEqual(by["hw:cpu.model"]["new-a"], "Intel(R) Xeon(R) Gold 6430")
        self.assertEqual(by["hw:memory.populated"]["new-a"], "3")
        self.assertEqual(by["hw:nics[].firmware"]["new-a"], "1.2.3\n22.36.1010 (EX_0000000001)")
        self.assertEqual(by["hw:cpu.no_such_key"]["Note"], "not in hardware.json")
        self.assertIsNone(by["hw:cpu.no_such_key"]["new-a"])
        self.assertIsNone(by["disk.fio.db-randread-8k"]["new-a"])
        self.assertEqual(by["disk.fio.db-randread-8k"]["Note"], "no value")
        self.assertEqual(by["nvme.fio.seq-read-1m.all-disks"]["Note"], "stage not run")
        self.assertEqual(by["PSU failover"]["Owner"], "DC team")
        self.assertIsNone(by["PSU failover"]["new-a"])
        other = [r["ID"] for r in rows[[i for i, r in enumerate(rows) if r["Section"] == "Other measured values"][0]:] if r["ID"]]
        self.assertIn("cpu.7z.rating.max", other)
        self.assertIn("cpu.openssl.aes-256-gcm.1t", other)   # measured, not in the layout: kept, not dropped
        self.assertNotIn("cpu.sysbench.prime.1t", other)

    def test_two_runs_diff_and_verdict_are_judge(self):
        wb = self.make("vm-a", "vm-b")
        ws = wb["Review"]
        head = [c.value for c in ws[1]]
        self.assertIn("Diff % vm-b vs vm-a", head)
        self.assertIn("Verdict vm-b", head)
        self.assertLess(head.index("Verdict vm-b"), head.index("vm-a r1"))
        rows = {r["ID"]: r for r in sheet_rows(ws) if r["ID"]}
        a, b = report.Run(os.path.join(FIX, "vm-a")), report.Run(os.path.join(FIX, "vm-b"))
        bm = {m.id: m for m in b.metrics}
        checked = 0
        for m in a.metrics:
            o = bm.get(m.id)
            if not o:
                continue
            diff, verdict = report.judge(m, o)
            r = rows[m.id]
            if diff is None or verdict is None:
                self.assertIsNone(r["Diff % vm-b vs vm-a"], m.id)
            else:
                self.assertAlmostEqual(r["Diff % vm-b vs vm-a"], diff / 100, msg=m.id)
            want = {1: "vm-b better", -1: "vm-a better", 0: "not clearly different"}.get(verdict, "-")
            self.assertEqual(r["Verdict vm-b"], want, m.id)
            checked += 1
        self.assertGreater(checked, 10)
        self.assertEqual(rows["burnin.errors"]["Verdict vm-b"], "-")
        self.assertIn("vm-a: stage not run", rows["burnin.errors"]["Note"])

    def test_rounds_are_the_real_count(self):
        wb = self.make("rounds-a")
        rows = {r["ID"]: r for r in sheet_rows(wb["Review"]) if r["ID"]}
        self.assertEqual(rows["disk.fio.randread-4k.qd32x4"]["Rounds rounds-a"], 2)
        self.assertEqual(rows["disk.fio.randread-4k.qd1.p99"]["Rounds rounds-a"], 1)
        self.assertEqual(rows["cpu.sysbench.prime.1t"]["Rounds rounds-a"], 3)
        self.assertIsNone(rows["disk.fio.randread-4k.qd32x4"]["rounds-a r3"])

    def test_failed_step_note(self):
        with tempfile.TemporaryDirectory() as d:
            src = os.path.join(FIX, "new-a")
            for f in os.listdir(src):
                with open(os.path.join(src, f), encoding="utf-8") as a, open(os.path.join(d, f), "w", encoding="utf-8") as b:
                    b.write(a.read())
            with open(os.path.join(d, "status.tsv"), "a", encoding="utf-8") as f:
                f.write("disk\tfio randread8k\tFAIL exit 1, see fio-43.json.err\ndisk\tfio pre\tOK\n")
            out = os.path.join(d, "r.xlsx")
            p = run(d, "-o", out)
            self.assertEqual(p.returncode, 0, p.stderr)
            rows = {r["ID"]: r for r in sheet_rows(load(out)["Review"]) if r["ID"]}
        self.assertEqual(rows["disk.fio.db-randread-8k"]["Note"], "disk / fio randread8k = FAIL exit 1, see fio-43.json.err")
        self.assertIn("no value (disk / fio randread8k", rows["disk.fio.db-randwrite-8k"]["Note"])

    def test_hardware_sheet(self):
        wb = self.make("new-a", "new-b", "vm-a")
        ws = wb["Hardware"]
        self.assertIn("No hardware.json for: vm-a", ws.cell(2, 1).value)
        hrow = next(i for i in range(1, 8) if ws.cell(i, 1).value == "Section")
        rows = sheet_rows(ws, hrow)
        by = {(r["Section"], r["Item"]): r for r in rows}
        self.assertEqual(by[("cpu", "model")]["new-a"], "Intel(R) Xeon(R) Gold 6430")
        self.assertEqual(by[("cpu", "model")]["Same?"], "yes")
        self.assertIsNone(by[("cpu", "model")]["vm-a"])
        self.assertEqual(by[("system", "bios_version")]["Same?"], "no")
        self.assertEqual(by[("system", "bmc.firmware")]["new-a"], "7.10")
        self.assertIn("size_mb=32768", by[("memory", "dimms CPU1_A1")]["new-a"])
        self.assertIsNone(by[("memory", "dimms CPU1_B1")]["new-b"])
        self.assertEqual(by[("memory", "dimms CPU1_B1")]["Same?"], "no")
        self.assertIn(("nics", "nics ens1f0"), by)
        self.assertIn(("bmc", "temperatures"), by)
        # Review rows for hw: compare text
        wb2 = self.make("new-a", "new-b", layout=LAYOUT, name="l.xlsx")
        r = {x["ID"]: x for x in sheet_rows(wb2["Review"]) if x["ID"]}
        self.assertEqual(r["hw:cpu.model"]["Verdict new-b"], "same")
        self.assertEqual(r["hw:memory.populated"]["Verdict new-b"], "differs")

    def test_hardware_txt_fallback(self):
        with tempfile.TemporaryDirectory() as d:
            src = os.path.join(FIX, "vm-a")
            for f in os.listdir(src):
                with open(os.path.join(src, f), encoding="utf-8") as a, open(os.path.join(d, f), "w", encoding="utf-8") as b:
                    b.write(a.read())
            with open(os.path.join(d, "hardware.txt"), "w", encoding="utf-8") as f:
                f.write("--- cpu (model, stepping, microcode)\nModel name: X\nStepping: 4\n--- disks\nsda 1T\n")
            out = os.path.join(d, "r.xlsx")
            self.assertEqual(run(d, "-o", out).returncode, 0)
            vals = [[c for c in r] for r in load(out)["Hardware"].iter_rows(values_only=True)]
        self.assertIn(["hardware.txt", "cpu (model, stepping, microcode)", "Model name: X\nStepping: 4"], vals)
        self.assertTrue(any(v and "only hardware.txt" in str(v[0]) for v in vals))

    def test_summary_and_cpu_sheets(self):
        wb = self.make("vm-a", "vm-b")
        ws = wb["Summary"]
        col_a = [r[0] for r in ws.iter_rows(values_only=True)]
        self.assertIn("Warnings", col_a)
        self.assertIn("How to read the Review sheet", col_a)
        cpu = sheet_rows(wb["CPU 1t vs max"])
        sb = next(r for r in cpu if r["ID"] == "cpu.sysbench.prime")
        a = {m.id: m for m in report.Run(os.path.join(FIX, "vm-a")).metrics}
        self.assertAlmostEqual(sb["max / 1t vm-a"], a["cpu.sysbench.prime.max"].median / a["cpu.sysbench.prime.1t"].median)

    def test_thai(self):
        wb = self.make("vm-a", "vm-b", lang="th")
        head = [c.value for c in wb["Review"][1]]
        self.assertEqual(head[0], "หัวข้อ")
        self.assertIn("ผล vm-b", head)
        p = run(os.path.join(FIX, "vm-a"), "-o", os.path.join(self.tmp.name, "t.xlsx"), env={"VMBENCH_LANG": "th"})
        self.assertEqual(p.returncode, 0)
        wb = load(os.path.join(self.tmp.name, "t.xlsx"))
        self.assertEqual(wb["Review"].cell(1, 1).value, "หัวข้อ")

    def test_same_labels_are_made_unique(self):
        wb = self.make("vm-a", "vm-a")
        head = [c.value for c in wb["Review"][1]]
        self.assertEqual(head[7], "vm-a#1")
        self.assertIn("vm-a#2", head)

    def test_default_output_and_overwrite_rules(self):
        d = os.path.join(self.tmp.name, "run")
        os.makedirs(d)
        src = os.path.join(FIX, "vm-a")
        for f in os.listdir(src):
            with open(os.path.join(src, f), encoding="utf-8") as a, open(os.path.join(d, f), "w", encoding="utf-8") as b:
                b.write(a.read())
        self.assertEqual(run(d).returncode, 0)
        self.assertTrue(os.path.isfile(os.path.join(d, "review.xlsx")))
        self.assertEqual(run(d).returncode, 0)   # a review.xlsx of ours is replaced
        foreign = os.path.join(self.tmp.name, "team.xlsx")
        wb = openpyxl.Workbook()
        wb.save(foreign)
        before = os.path.getmtime(foreign)
        p = run(d, "-o", foreign)
        self.assertEqual(p.returncode, 2)
        self.assertIn("was not written by vmbench", p.stderr)
        self.assertEqual(os.path.getmtime(foreign), before)

    def test_bad_input(self):
        self.assertEqual(run(os.path.join(FIX, "nothing")).returncode, 2)
        self.assertEqual(run().returncode, 2)
        p = run(os.path.join(FIX, "vm-a"), "--layout", os.path.join(FIX, "nothing.tsv"), "-o", os.path.join(self.tmp.name, "x.xlsx"))
        self.assertEqual(p.returncode, 2)
        self.assertIn("cannot be read", p.stderr)


if __name__ == "__main__":
    unittest.main()
