"""Tests for report.py. They use only the synthetic folders under tests/fixtures and the standard library.

Run:  python3 -I -B -m unittest discover -s tests -v     (or: bash tests/run.sh)
"""
import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from html.parser import HTMLParser

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
FIX = os.path.join(HERE, "fixtures")
REPORT = os.path.join(ROOT, "report.py")

spec = importlib.util.spec_from_file_location("report", REPORT)
report = importlib.util.module_from_spec(spec)
sys.modules["report"] = report
spec.loader.exec_module(report)


def fixture(name):
    return report.Run(os.path.join(FIX, name))


def metric(name, values, unit="IOPS", row="35"):
    import statistics
    mean = statistics.mean(values)
    cv = statistics.pstdev(values) / mean * 100 if len(values) > 1 and mean else None
    return report.Metric(row, name, name, "", unit, values, statistics.median(values), cv)


def cli(*args):
    return subprocess.run([sys.executable, "-I", "-B", REPORT, *args], capture_output=True, text=True, encoding="utf-8")


class Balanced(HTMLParser):
    """Counts tags that were closed wrongly or never closed."""
    def __init__(self):
        super().__init__()
        self.stack, self.errors = [], 0

    def handle_starttag(self, tag, attrs):
        if tag != "meta":
            self.stack.append(tag)

    def handle_endtag(self, tag):
        if not self.stack or self.stack.pop() != tag:
            self.errors += 1


class Direction(unittest.TestCase):
    def test_latency_units_are_lower_is_better(self):
        for unit in ("ns", "us", "ms"):
            self.assertEqual(report.direction("anything", unit), -1, unit)

    def test_error_counts_and_loss_are_lower_is_better(self):
        self.assertEqual(report.direction("burn-in errors (60s)", "count"), -1)
        self.assertEqual(report.direction("iperf3 udp lost packets %", "%"), -1)

    def test_throughput_is_higher_is_better(self):
        for unit in ("IOPS", "MB/s", "events/s", "RPS", "ops/s"):
            self.assertEqual(report.direction("x", unit), 1, unit)

    def test_context_values_are_not_judged(self):
        self.assertEqual(report.direction("cpu steal avg", "%"), 0)
        self.assertEqual(report.direction("steadystate attained (1=yes)", "flag"), 0)
        self.assertEqual(report.direction("fio fill write 1M", "MB/s"), 0)


class Sections(unittest.TestCase):
    def test_rows_map_to_sections(self):
        expected = {"7": "CPU", "23": "CPU", "26": "Memory", "35": "Disk", "46": "Disk", "47": "PostgreSQL",
                    "52": "Network", "55": "Web", "65": "Burn-in", "info": report.INFO_SECTION}
        for row, section in expected.items():
            self.assertEqual(report.section_of(row), section, row)


class Loading(unittest.TestCase):
    def test_metadata_is_read(self):
        a = fixture("vm-a")
        self.assertEqual(a.label, "vm-a")
        self.assertEqual(a.nproc, "8")
        self.assertEqual(a.arch, "x86_64")
        self.assertEqual(a.cpu, "Fixture CPU A")
        avg, top = a.steal
        self.assertAlmostEqual(avg, 0.05)
        self.assertAlmostEqual(top, 0.15)

    def test_thread_counts_become_1t_and_max(self):
        a = fixture("vm-a")
        sysbench = {m.variant: m for m in a.metrics if m.base == "sysbench cpu"}
        self.assertEqual(set(sysbench), {"1t", "max"})
        self.assertEqual(sysbench["max"].name, "sysbench cpu 8t")

    def test_8_and_16_vcpu_runs_pair_up(self):
        keys = lambda run: {(m.row, m.base, m.variant) for m in run.metrics if m.row in ("7", "8", "11", "13")}
        self.assertEqual(keys(fixture("vm-a")), keys(fixture("vm-c")))

    def test_median_and_cv_over_rounds(self):
        rsa = next(m for m in fixture("vm-a").metrics if m.base == "cpubench crypto/rsa2048-sign" and m.variant == "max")
        self.assertEqual(len(rsa.values), 3)
        self.assertGreater(rsa.cv, report.HIGH_CV)
        self.assertEqual(report.mark(rsa), "!")

    def test_single_round_is_marked_and_has_no_cv(self):
        triad = fixture("vm-a").find("stream triad")
        self.assertEqual(len(triad.values), 1)
        self.assertIsNone(triad.cv)
        self.assertEqual(report.mark(triad), "*")
        self.assertEqual(report.cv_text(triad), "n/a")

    def test_array_size_is_taken_out_of_the_metric_name(self):
        with tempfile.TemporaryDirectory() as d:
            with open(os.path.join(d, "results.tsv"), "w") as f:
                f.write("row\tmetric\tvalue\tunit\tround\n26\tstream triad (N=100000000)\t100\tMB/s\t1\n")
            run = report.Run(d)
        self.assertEqual(run.stream_n, "100000000")
        self.assertEqual(run.metrics[0].name, "stream triad")

    def test_folder_without_results_is_an_input_error(self):
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(report.InputError):
                report.Run(d)

    def test_fail_and_skip_reasons_are_kept(self):
        c = fixture("vm-c")
        self.assertEqual([p[2] for p in c.problems], ["FAIL see web.log", "SKIP PEER not set"])


class Judging(unittest.TestCase):
    def test_lower_latency_is_better(self):
        a, b = fixture("vm-a"), fixture("vm-b")
        diff, verdict = report.judge(a.find("wal fdatasync avg"), b.find("wal fdatasync avg"))
        self.assertEqual(verdict, 1)
        self.assertLess(diff, 0)

    def test_higher_throughput_is_better(self):
        a, b = fixture("vm-a"), fixture("vm-b")
        self.assertEqual(report.judge(a.find("stream triad"), b.find("stream triad"))[1], 1)
        self.assertEqual(report.judge(b.find("stream triad"), a.find("stream triad"))[1], -1)

    def test_a_run_never_beats_itself(self):
        a = fixture("vm-a")
        for m in a.metrics:
            if report.direction(m.name, m.unit):
                self.assertEqual(report.judge(m, m)[1], 0, m.name)

    def test_difference_inside_the_noise_is_not_a_win(self):
        noisy = metric("x", [90, 100, 110])            # about 8 % CV
        better = metric("x", [105])
        self.assertEqual(report.judge(noisy, better)[1], 0)

    def test_difference_above_the_noise_is_a_win(self):
        steady = metric("x", [100, 100, 100])
        better = metric("x", [130, 130, 130])
        self.assertEqual(report.judge(steady, better)[1], 1)

    def test_tiny_difference_is_not_a_win_without_cv(self):
        self.assertEqual(report.judge(metric("x", [100]), metric("x", [100.5]))[1], 0)
        self.assertEqual(report.judge(metric("x", [100]), metric("x", [103]))[1], 1)

    def test_steal_is_shown_but_not_judged(self):
        a, b = fixture("vm-a"), fixture("vm-b")
        self.assertEqual(report.judge(a.find("cpu steal avg"), b.find("cpu steal avg")), (None, None))

    def test_zero_baseline_does_not_crash(self):
        diff, verdict = report.judge(fixture("vm-b").find("burn-in errors (60s)"), fixture("vm-c").find("burn-in errors (60s)"))
        self.assertIsNone(diff)
        self.assertEqual(verdict, -1)          # 0 errors against 2 errors: the baseline is better


class Warnings(unittest.TestCase):
    def texts(self, *names):
        runs = [fixture(n) for n in names]
        out = report.compare_warnings(runs)
        for r in runs:
            out += report.run_warnings(r)
        return "\n".join(out)

    def test_quick_run_is_flagged(self):
        self.assertIn("QUICK", self.texts("vm-c"))
        self.assertNotIn("QUICK", self.texts("vm-a"))

    def test_failed_stage_is_listed_with_its_reason(self):
        self.assertIn("web / max RPS = FAIL see web.log", self.texts("vm-c"))

    def test_high_steal_is_flagged(self):
        self.assertIn("steal", self.texts("vm-b"))
        self.assertNotIn("steal", self.texts("vm-a"))

    def test_noisy_values_are_listed(self):
        self.assertIn("rsa2048-sign", self.texts("vm-a"))

    def test_mismatched_setups_are_flagged(self):
        text = self.texts("vm-a", "vm-c")
        for word in ("vCPU", "RAM", "cpubench", "จำนวนรอบ"):
            self.assertIn(word, text)

    def test_matching_setups_are_not_flagged(self):
        text = "\n".join(report.compare_warnings([fixture("vm-a"), fixture("vm-b")]))
        for word in ("vCPU", "RAM", "cpubench คนละเวอร์ชัน"):
            self.assertNotIn(word, text)

    def test_cpubench_build_tag_alone_is_not_a_version_difference(self):
        a, b = fixture("vm-a"), fixture("vm-b")
        b.info["cpubench"] = a.info["cpubench"].replace("GOAMD64=v1", "GOARM64=v8.0")
        self.assertNotIn("คนละเวอร์ชัน", "\n".join(report.compare_warnings([a, b])))

    def test_environment_table_counts_problems_with_reasons(self):
        table = report.env_table([fixture("vm-c")])
        status = next(r for r in table.rows if r[0] == "สถานะขั้นตอน")
        self.assertIn("FAIL 1", status[1])
        self.assertIn("SKIP 1", status[1])


class CommandLine(unittest.TestCase):
    def test_show_prints_tables(self):
        r = cli("show", os.path.join(FIX, "vm-a"), "--no-files")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("sysbench cpu", r.stdout)
        self.assertIn("stream triad", r.stdout)

    def test_compare_prints_both_machines(self):
        r = cli("compare", os.path.join(FIX, "vm-a"), os.path.join(FIX, "vm-b"), "--no-files")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("vm-a (baseline)", r.stdout)
        self.assertIn("vm-b", r.stdout)

    def test_compare_three_runs(self):
        r = cli("compare", *[os.path.join(FIX, n) for n in ("vm-a", "vm-b", "vm-c")], "--no-files")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("vm-c", r.stdout)

    def test_no_files_writes_nothing(self):
        with tempfile.TemporaryDirectory() as d:
            r = cli("show", os.path.join(FIX, "vm-a"), "--no-files", "--out", d)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(os.listdir(d), [])

    def test_files_are_written_and_html_is_well_formed(self):
        with tempfile.TemporaryDirectory() as d:
            r = cli("compare", os.path.join(FIX, "vm-a"), os.path.join(FIX, "vm-c"), "--out", d)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(sorted(os.listdir(d)), ["report.html", "report.md"])
            with open(os.path.join(d, "report.html"), encoding="utf-8") as f:
                p = Balanced()
                p.feed(f.read())
            self.assertEqual((p.errors, p.stack), (0, []))
            with open(os.path.join(d, "report.md"), encoding="utf-8") as f:
                self.assertIn("|---|", f.read())

    def test_missing_folder_exits_2_with_a_message(self):
        r = cli("show", os.path.join(FIX, "does-not-exist"))
        self.assertEqual(r.returncode, 2)
        self.assertIn("error:", r.stderr)

    def test_compare_needs_two_folders(self):
        r = cli("compare", os.path.join(FIX, "vm-a"))
        self.assertEqual(r.returncode, 2)

    def test_output_survives_a_closed_pipe(self):
        p = subprocess.Popen([sys.executable, "-I", "-B", REPORT, "show", os.path.join(FIX, "vm-a"), "--no-files"],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        p.stdout.readline()
        p.stdout.close()
        code = p.wait(timeout=30)
        err = p.stderr.read()
        p.stderr.close()
        self.assertEqual(code, 0)
        self.assertNotIn(b"Traceback", err)


if __name__ == "__main__":
    unittest.main()
