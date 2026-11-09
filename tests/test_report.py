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


def metric(name, values, unit="IOPS", ident="disk.fio.randread-4k.qd32x4"):
    import statistics
    mean = statistics.mean(values)
    cv = statistics.pstdev(values) / mean * 100 if len(values) > 1 and mean else None
    return report.Metric(ident, name, name, "", unit, values, statistics.median(values), cv)


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
    def test_ids_map_to_sections(self):
        expected = {"cpu.sysbench.prime.1t": "CPU", "cpu.cpubench.int.sort.max": "CPU", "mem.stream.triad.max": "Memory",
                    "disk.fio.randread-4k.qd32x4": "Disk", "disk.wal.commit-iops.qd1": "Disk",
                    "pg.pgbench.tpcb.tps": "PostgreSQL", "net.sockperf.pingpong.avg": "Network",
                    "web.cpubench.mix.max-rps": "Web", "burnin.errors": "Burn-in",
                    "info.cpu.steal.avg": report.INFO_SECTION, "something.unknown": report.INFO_SECTION}
        for ident, section in expected.items():
            self.assertEqual(report.section_of(ident), section, ident)

    def test_variant_suffix_is_not_part_of_the_test(self):
        self.assertEqual(report.id_base("cpu.sysbench.prime.1t"), "cpu.sysbench.prime")
        self.assertEqual(report.id_base("cpu.sysbench.prime.max"), "cpu.sysbench.prime")
        self.assertEqual(report.id_base("disk.wal.fdatasync.avg"), "disk.wal.fdatasync.avg")
        self.assertEqual(report.id_base("info.cpu.steal.peak"), "info.cpu.steal.peak")


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
        keys = lambda run: {(m.id, m.base, m.variant) for m in run.metrics if m.id.startswith("cpu.")}
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

    # ---- repeated mem, web and disk rows (rounds-a / rounds-b: synthetic, 3 rounds of mem and web, 2 of one disk test)
    @staticmethod
    def by_id(run, ident):
        return next(m for m in run.metrics if m.id == ident)

    def test_mem_and_web_rounds_have_median_and_cv(self):
        a = fixture("rounds-a")
        for ident in ("mem.stream.triad.max", "mem.stream.copy.max", "mem.lmbench.lat-mem-rd.1t", "web.cpubench.mix.max-rps"):
            m = self.by_id(a, ident)
            self.assertEqual(len(m.values), 3, ident)
            self.assertIsNotNone(m.cv, ident)
            self.assertNotEqual(report.mark(m), "*", ident)
            self.assertTrue(report.cv_text(m).endswith("%"), ident)
        triad = self.by_id(a, "mem.stream.triad.max")
        self.assertEqual(triad.median, 130000.0)
        self.assertAlmostEqual(triad.cv, 0.82, places=1)
        self.assertEqual(report.mark(triad), "")           # CV below 5%: no mark
        web = self.by_id(a, "web.cpubench.mix.max-rps")
        self.assertEqual(report.mark(web), "!")            # CV above 5%: noisy
        self.assertAlmostEqual(web.cv, 6.8, places=1)

    def test_star_only_where_there_is_one_round(self):
        a = fixture("rounds-a")
        self.assertEqual(report.mark(self.by_id(a, "disk.fio.randread-4k.qd1.p99")), "*")      # 1 round
        self.assertEqual(report.mark(self.by_id(a, "disk.fio.randread-4k.qd32x4")), "")        # 2 rounds
        self.assertEqual(len(self.by_id(a, "disk.fio.randread-4k.qd32x4").values), 2)

    def test_rounds_per_stage_come_from_meta(self):
        self.assertEqual(fixture("rounds-a").info["rounds"], "cpu 3, mem 3, disk 2, web 3")
        self.assertEqual(fixture("new-a").info["rounds"], "3")   # a meta.json without rounds_by_stage keeps the single number

    def test_show_prints_cv_for_repeated_mem_and_web(self):
        r = cli("show", os.path.join(FIX, "rounds-a"), "--no-files")
        self.assertEqual(r.returncode, 0, r.stderr)
        triad = next(line for line in r.stdout.splitlines() if line.startswith("mem.stream.triad "))
        self.assertRegex(triad, r"\b3\s+0\.8%")      # rounds column, then the CV
        web = next(line for line in r.stdout.splitlines() if line.startswith("web.cpubench.mix.max-rps "))
        self.assertRegex(web, r"27,000!\s+3\s+6\.8%")
        self.assertNotRegex(triad, r"n/a")
        self.assertIn("cpu 3, mem 3, disk 2, web 3", r.stdout)

    def test_compare_uses_cv_of_repeated_mem_and_web(self):
        a, b = fixture("rounds-a"), fixture("rounds-b")
        diff, verdict = report.judge(self.by_id(a, "mem.stream.triad.max"), self.by_id(b, "mem.stream.triad.max"))
        self.assertAlmostEqual(diff, 10.0, places=1)
        self.assertEqual(verdict, 1)                      # +10% on a 1% CV: clearly better
        diff, verdict = report.judge(self.by_id(a, "web.cpubench.mix.max-rps"), self.by_id(b, "web.cpubench.mix.max-rps"))
        self.assertAlmostEqual(diff, 2.96, places=1)
        self.assertEqual(verdict, 0)                      # +3% on a 6.8% CV: not clearly different
        diff, verdict = report.judge(self.by_id(a, "mem.lmbench.lat-mem-rd.1t"), self.by_id(b, "mem.lmbench.lat-mem-rd.1t"))
        self.assertEqual(verdict, 0)

    def test_compare_output_has_rounds_and_no_once_mark_for_repeated_tests(self):
        r = cli("compare", os.path.join(FIX, "rounds-a"), os.path.join(FIX, "rounds-b"), "--no-files")
        self.assertEqual(r.returncode, 0, r.stderr)
        triad = next(line for line in r.stdout.splitlines() if line.startswith("mem.stream.triad "))
        self.assertIn("+10.0%", triad)
        self.assertNotIn("*", triad)                      # both sides have 3 rounds
        single = next(line for line in r.stdout.splitlines() if line.startswith("disk.fio.randread-4k.qd1.p99 "))
        self.assertIn("160.0*", single)                   # one round on both sides: still marked

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
        for word in ("vCPU", "RAM", "cpubench", "rounds"):
            self.assertIn(word, text)

    def test_matching_setups_are_not_flagged(self):
        text = "\n".join(report.compare_warnings([fixture("vm-a"), fixture("vm-b")]))
        for word in ("vCPU", "RAM", "cpubench versions differ"):
            self.assertNotIn(word, text)

    def test_cpubench_build_tag_alone_is_not_a_version_difference(self):
        a, b = fixture("vm-a"), fixture("vm-b")
        b.info["cpubench"] = a.info["cpubench"].replace("GOAMD64=v1", "GOARM64=v8.0")
        self.assertNotIn("versions differ", "\n".join(report.compare_warnings([a, b])))

    def test_environment_table_counts_problems_with_reasons(self):
        table = report.env_table([fixture("vm-c")])
        status = next(r for r in table.rows if r[0] == "Stage status")
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
