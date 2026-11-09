"""Tests for the stable metric IDs: the table in run-benchmark.sh, docs/tests.md, the legacy mapping in
report.py, the recording calls in the script, and loading of old and new result folders.

They use only the synthetic folders under tests/fixtures, the standard library, and `bash run-benchmark.sh --metrics`
(which needs no benchmark tools and no network).
"""
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
FIX = os.path.join(HERE, "fixtures")
SCRIPT = os.path.join(ROOT, "run-benchmark.sh")
DOCS = os.path.join(ROOT, "docs", "tests.md")

spec = importlib.util.spec_from_file_location("report", os.path.join(ROOT, "report.py"))
report = importlib.util.module_from_spec(spec)
sys.modules["report"] = report
spec.loader.exec_module(report)

STAGES = {"cpu", "mem", "disk", "pg", "net", "web", "burnin", "info"}
DIRECTION = {"higher": 1, "lower": -1, "none": 0}
# ids that the script builds from a variable, so a literal `rec <id>` cannot be found for them
DYNAMIC = (re.compile(r"cpu\.cpubench\..+\.(1t|max)$"), re.compile(r"disk\.fio\.randread-4k\.sweep-qd\d+$"))


def script_table():
    """{id: dict} from `bash run-benchmark.sh --metrics`: id|unit|direction|tool|label|measures."""
    out = subprocess.run(["bash", SCRIPT, "--metrics"], capture_output=True, text=True, check=True).stdout
    table = {}
    for line in out.splitlines():
        parts = line.split("|")
        assert len(parts) == 6, f"table line with {len(parts)} columns: {line!r}"
        ident, unit, direction, tool, label, measures = parts
        assert ident not in table, f"duplicate id {ident}"
        table[ident] = dict(unit=unit, direction=direction, tool=tool, label=label, measures=measures)
    return table


def docs_table():
    """{id: dict} from the table in docs/tests.md: | ID | what | tool | unit | direction | stage |."""
    table = {}
    with open(DOCS, encoding="utf-8") as f:
        for line in f:
            m = re.match(r"^\| `([^`]+)` \| (.*) \| (.*) \| (.*) \| (.*) \| (.*) \|$", line.rstrip("\n"))
            if m:
                ident, measures, tool, unit, direction, stage = m.groups()
                assert ident not in table, f"duplicate id {ident} in docs/tests.md"
                table[ident] = dict(measures=measures, tool=tool, unit=unit, direction=direction, stage=stage)
    return table


def sample_label(entry, ident):
    """The metric text the script writes for this id, with 8 vCPUs and an example value for {x}."""
    t = "1" if ident.endswith(".1t") else "8"
    return entry["label"].replace("{t}", t).replace("{x}", "123")


def split_threads(label):
    m = re.match(r"^(.*) (\d+)t$", label)
    if not m:
        return label, ""
    return m.group(1), "1t" if m.group(2) == "1" else "max"


class ScriptTable(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.table = script_table()

    def test_ids_follow_the_naming_scheme(self):
        for ident in self.table:
            self.assertRegex(ident, r"^[a-z0-9]+(\.[a-z0-9-]+)+$", ident)
            self.assertIn(ident.split(".")[0], STAGES, ident)

    def test_variant_suffix_only_means_threads(self):
        for ident, e in self.table.items():
            if ident.startswith("cpu.") and ident.endswith((".1t", ".max")):
                self.assertIn("{t}", e["label"], ident)

    def test_every_field_is_filled(self):
        for ident, e in self.table.items():
            for key, v in e.items():
                self.assertTrue(v.strip(), f"{ident}: empty {key}")
            self.assertIn(e["direction"], DIRECTION, ident)

    def test_direction_agrees_with_report_py(self):
        for ident, e in self.table.items():
            unit = "ops/s" if e["unit"] == "varies" else e["unit"]
            self.assertEqual(report.direction(sample_label(e, ident), unit), DIRECTION[e["direction"]], ident)

    def test_every_stage_has_metrics(self):
        self.assertEqual({i.split(".")[0] for i in self.table}, STAGES)


class DocsAgreeWithScript(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.script, cls.docs = script_table(), docs_table()

    def test_same_ids(self):
        self.assertEqual(sorted(set(self.script) - set(self.docs)), [], "in the script but not in docs/tests.md")
        self.assertEqual(sorted(set(self.docs) - set(self.script)), [], "in docs/tests.md but not in the script")

    def test_same_columns(self):
        for ident, s in self.script.items():
            d = self.docs[ident]
            self.assertEqual((d["measures"], d["tool"], d["unit"], d["direction"], d["stage"]),
                             (s["measures"], s["tool"], s["unit"], s["direction"], ident.split(".")[0]), ident)

    def test_same_order(self):
        with open(DOCS, encoding="utf-8") as f:
            text = f.read()
        found = re.findall(r"^\| `([^`]+)` \|", text, re.M)
        self.assertEqual(found, list(self.script))


class RecordingCalls(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.table = script_table()
        with open(SCRIPT, encoding="utf-8") as f:
            cls.source = f.read()

    def recorded(self):
        return set(re.findall(r"\brec \"?([a-z0-9]+(?:\.[a-z0-9-]+)+)\"?[ ;]", self.source))

    def test_every_recorded_id_is_in_the_table(self):
        for ident in self.recorded():
            self.assertIn(ident, self.table, f"rec uses an id that is not in the table: {ident}")

    def test_every_table_id_is_recorded_somewhere(self):
        recorded = self.recorded()
        for ident in self.table:
            ok = ident in recorded or any(p.match(ident) for p in DYNAMIC)
            self.assertTrue(ok, f"{ident} is in the table but no rec call writes it")

    def test_no_numeric_rows_are_left(self):
        self.assertIsNone(re.search(r"\brec [0-9]", self.source))
        self.assertNotIn("ROWMAP", self.source)


class LegacyMapping(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.table = script_table()

    def test_every_id_has_a_legacy_row(self):
        bases = {ident for _, _, ident in report.LEGACY}
        for ident in self.table:
            self.assertTrue(ident in bases or report.id_base(ident) in bases, f"no LEGACY entry for {ident}")

    def test_every_legacy_entry_is_a_real_id(self):
        ids = set(self.table)
        bases = {report.id_base(i) for i in ids}
        for row, _, ident in report.LEGACY:
            self.assertTrue(ident in ids or ident in bases, f"LEGACY row {row} maps to unknown id {ident}")

    def test_old_metric_text_maps_to_the_same_id(self):
        """What the old script wrote (row + text) and what the new script writes (id) must meet."""
        rows = {}
        for row, _, ident in report.LEGACY:
            rows.setdefault(ident, []).append(row)
        for ident, e in self.table.items():
            base, variant = split_threads(sample_label(e, ident))
            base = re.sub(r" \(N=\d+\)$", "", base)
            key = ident if ident in rows else report.id_base(ident)
            for row in rows[key]:
                self.assertEqual(report.legacy_id(row, base, variant), ident, f"row {row} {base!r} {variant}")

    def test_unknown_rows_keep_their_stage(self):
        self.assertEqual(report.legacy_id("40", "something new", ""), "disk.row40.something-new")
        self.assertEqual(report.legacy_id("info", "disk temp", ""), "info.rowinfo.disk-temp")
        self.assertEqual(report.legacy_id("99", "x", "1t"), "burnin.row99.x-1t")
        self.assertEqual(report.section_of("disk.row40.something-new"), "Disk")

    def test_legacy_names_in_fixtures_are_all_known(self):
        for name in ("vm-a", "vm-b", "vm-c"):
            for m in report.Run(os.path.join(FIX, name)).metrics:
                self.assertNotIn(".row", m.id, f"{name}: {m.name} fell through to the fallback id")


def write_run(folder, results, meta=None, info=None):
    with open(os.path.join(folder, "results.tsv"), "w", encoding="utf-8") as f:
        f.write(results)
    if meta is not None:
        with open(os.path.join(folder, "meta.json"), "w", encoding="utf-8") as f:
            f.write(meta if isinstance(meta, str) else json.dumps(meta))
    if info is not None:
        with open(os.path.join(folder, "info.txt"), "w", encoding="utf-8") as f:
            f.write(info)


NEW_HEADER = "id\tmetric\tvalue\tunit\tround\n"


class OldAndNewFormat(unittest.TestCase):
    def test_old_folder_gets_ids(self):
        a = report.Run(os.path.join(FIX, "vm-a"))
        ids = {m.id for m in a.metrics}
        self.assertIn("cpu.sysbench.prime.1t", ids)
        self.assertIn("cpu.sysbench.prime.max", ids)
        self.assertIn("mem.stream.triad.max", ids)
        self.assertIn("info.cpu.steal.peak", ids)

    def test_new_folder_reads_ids_from_the_file(self):
        with tempfile.TemporaryDirectory() as d:
            write_run(d, NEW_HEADER + "disk.fio.seq-read-1m\tfio seq read 1M\t500\tMB/s\t1\n"
                         "some.future.id\tfuture thing\t5\tMB/s\t1\n")
            run = report.Run(d)
        self.assertEqual([m.id for m in run.metrics], ["disk.fio.seq-read-1m", "some.future.id"])

    def test_old_and_new_fixture_give_identical_results(self):
        old, new = report.Run(os.path.join(FIX, "vm-a")), report.Run(os.path.join(FIX, "new-a"))
        key = lambda r: [(m.id, m.name, m.base, m.variant, m.unit, m.values, m.median, m.cv) for m in r.metrics]
        self.assertEqual(key(old), key(new))

    def test_verdicts_are_the_same_for_old_and_new_format(self):
        va, vb = report.Run(os.path.join(FIX, "vm-a")), report.Run(os.path.join(FIX, "vm-b"))
        na = report.Run(os.path.join(FIX, "new-a"))
        for m_old, m_new in zip(va.metrics, na.metrics):
            for other in vb.metrics:
                if other.name == m_old.name:
                    self.assertEqual(report.judge(m_old, other), report.judge(m_new, other), m_old.name)

    def test_old_and_new_runs_can_be_compared(self):
        old, new = report.Run(os.path.join(FIX, "vm-b")), report.Run(os.path.join(FIX, "new-a"))
        summary, tables = report.compare_tables([old, new])
        cells = [r for t in tables for r in t.rows]
        sysbench = [r for r in cells if r[0] == "cpu.sysbench.prime"]
        self.assertEqual(len(sysbench), 2)
        self.assertNotIn("ไม่มีข้อมูล", [report.cell_text(c) for r in sysbench for c in r])

    def test_tables_use_ids_not_row_numbers(self):
        for name in ("vm-a", "new-a"):
            run = report.Run(os.path.join(FIX, name))
            first = [r[0] for t in report.show_tables(run) for r in t.rows]
            self.assertIn("cpu.sysbench.prime", first)
            self.assertFalse(any(x.isdigit() for x in first), name)

    def test_order_follows_the_test_plan_not_the_file(self):
        with tempfile.TemporaryDirectory() as d:
            write_run(d, NEW_HEADER + "info.cpu.steal.avg\tcpu steal avg\t1\t%\t1\n"
                         "disk.fio.seq-read-1m\tfio seq read 1M\t5\tMB/s\t1\n"
                         "cpu.sysbench.prime.1t\tsysbench cpu 1t\t5\tevents/s\t1\n")
            ids = [m.id for m in report.Run(d).metrics]
        self.assertEqual(ids, ["cpu.sysbench.prime.1t", "disk.fio.seq-read-1m", "info.cpu.steal.avg"])

    def test_old_file_without_a_header_is_read_as_old(self):
        with tempfile.TemporaryDirectory() as d:
            write_run(d, "35\tfio randread 4k qd32x4\t100\tIOPS\t1\n")
            self.assertEqual(report.Run(d).metrics[0].id, "disk.fio.randread-4k.qd32x4")


class Meta(unittest.TestCase):
    def test_meta_json_is_used_when_present(self):
        b = report.Run(os.path.join(FIX, "new-b"))   # has no info.txt at all
        self.assertEqual(b.label, "new-b")
        self.assertEqual(b.nproc, "8")
        self.assertEqual(b.arch, "aarch64")
        self.assertEqual(b.version, "v0.0.0-fixture")
        self.assertEqual(b.stages, ["info", "cpu", "mem", "disk", "web", "burnin"])
        self.assertEqual(b.info["quick"], "0")
        self.assertEqual(b.info["rounds"], "3")
        self.assertEqual(b.info["date"], "2000-01-02T00:00:00Z")

    def test_cpubench_version_comes_from_meta(self):
        a = report.Run(os.path.join(FIX, "new-a"))
        self.assertTrue(a.info["cpubench"].startswith("cpubench v0.1.0"))

    def test_meta_wins_over_info_txt_but_info_txt_fills_the_rest(self):
        with tempfile.TemporaryDirectory() as d:
            write_run(d, NEW_HEADER + "cpu.sysbench.prime.1t\tsysbench cpu 1t\t5\tevents/s\t1\n",
                      meta={"label": "from-meta", "nproc": 4, "quick": True, "arch": "aarch64"},
                      info="label: from-info\nkernel: Linux 6.8.0 x86_64\nnproc: 8  ram_gb: 16\nModel name:  Some CPU\n")
            run = report.Run(d)
        self.assertEqual((run.label, run.nproc, run.info["quick"], run.arch), ("from-meta", "4", "1", "aarch64"))
        self.assertEqual((run.info["ram_gb"], run.cpu), ("16", "Some CPU"))

    def test_old_folder_falls_back_to_info_txt(self):
        a = report.Run(os.path.join(FIX, "vm-a"))
        self.assertEqual(a.meta, {})
        self.assertEqual((a.label, a.nproc, a.arch, a.version, a.stages), ("vm-a", "8", "x86_64", "", []))

    def test_broken_meta_json_falls_back_and_warns(self):
        for bad in ("{not json", "[1, 2]"):
            with tempfile.TemporaryDirectory() as d:
                write_run(d, NEW_HEADER + "cpu.sysbench.prime.1t\tsysbench cpu 1t\t5\tevents/s\t1\n", meta=bad,
                          info="label: from-info\nnproc: 8  ram_gb: 16\n")
                run = report.Run(d)
                self.assertEqual(run.label, "from-info")
                self.assertTrue(any("meta.json" in w for w in report.run_warnings(run)), bad)

    def test_odd_meta_values_do_not_crash(self):
        with tempfile.TemporaryDirectory() as d:
            write_run(d, NEW_HEADER + "cpu.sysbench.prime.1t\tsysbench cpu 1t\t5\tevents/s\t1\n",
                      meta={"label": None, "nproc": [1], "stages": "cpu", "vmbench_version": 3, "arch": 7})
            run = report.Run(d)
            self.assertEqual((run.version, run.stages), ("", []))
            report.env_table([run])

    def test_environment_table_shows_version_and_stages(self):
        table = report.env_table([report.Run(os.path.join(FIX, "new-a")), report.Run(os.path.join(FIX, "vm-a"))])
        rows = {r[0]: r[1:] for r in table.rows}
        self.assertEqual(rows["vmbench"], ["v0.0.0-fixture", "-"])
        self.assertEqual(rows["ขั้นตอนที่รัน"][0], "cpu mem disk web")

    def test_different_vmbench_versions_are_flagged_only_when_both_are_known(self):
        a, b = report.Run(os.path.join(FIX, "new-a")), report.Run(os.path.join(FIX, "new-b"))
        self.assertNotIn("vmbench คนละเวอร์ชัน", "\n".join(report.compare_warnings([a, b])))
        b.meta["vmbench_version"] = "v9"
        self.assertIn("vmbench คนละเวอร์ชัน", "\n".join(report.compare_warnings([a, b])))
        self.assertNotIn("vmbench คนละเวอร์ชัน", "\n".join(report.compare_warnings([a, report.Run(os.path.join(FIX, "vm-a"))])))

    def test_fixture_meta_has_no_addresses(self):
        for name in ("new-a", "new-b"):
            with open(os.path.join(FIX, name, "meta.json"), encoding="utf-8") as f:
                text = f.read()
            self.assertIsNone(re.search(r"\b\d{1,3}(\.\d{1,3}){3}\b", text), name)
            self.assertNotIn("host", text)


class CommandLine(unittest.TestCase):
    def run_cli(self, *args):
        return subprocess.run([sys.executable, "-I", "-B", os.path.join(ROOT, "report.py"), *args],
                              capture_output=True, text=True, encoding="utf-8")

    def test_show_works_on_the_new_format(self):
        r = self.run_cli("show", os.path.join(FIX, "new-a"), "--no-files")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("cpu.sysbench.prime", r.stdout)

    def test_compare_old_with_new_format(self):
        r = self.run_cli("compare", os.path.join(FIX, "vm-a"), os.path.join(FIX, "new-b"), "--no-files")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("mem.stream.triad", r.stdout)


if __name__ == "__main__":
    unittest.main()
