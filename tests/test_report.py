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

    @staticmethod
    def with_pg(name, profile):
        """A fixture with one pg metric and meta.json pg_profile = profile (None: the key is missing)."""
        r = fixture(name)
        r.metrics.append(metric("pgbench tpcb-like tps (-c 16)", [1000.0], "TPS", "pg.pgbench.tpcb.tps"))
        if profile is not None:
            r.meta["pg_profile"] = profile
        return r

    def test_different_pg_profiles_are_flagged(self):
        text = "\n".join(report.compare_warnings([self.with_pg("vm-a", "bench"), self.with_pg("vm-b", "production")]))
        self.assertIn("different profiles", text)
        self.assertIn("vm-a=bench", text)
        self.assertIn("vm-b=production", text)

    def test_same_pg_profile_is_not_flagged(self):
        runs = [self.with_pg("vm-a", "production"), self.with_pg("vm-b", "production")]
        self.assertNotIn("different profiles", "\n".join(report.compare_warnings(runs)))

    def test_pg_profile_of_an_older_run_counts_as_unset(self):
        text = "\n".join(report.compare_warnings([self.with_pg("vm-a", None), self.with_pg("vm-b", "production")]))
        self.assertIn("vm-a=unset", text)

    def test_pg_profile_is_ignored_without_pg_results(self):
        a, b = fixture("vm-a"), self.with_pg("vm-b", "production")
        a.meta["pg_profile"] = "bench"   # no pg metric: the value is not about this comparison
        self.assertEqual(a.pg_profile, "")
        self.assertNotIn("different profiles", "\n".join(report.compare_warnings([a, b])))

    def test_environment_table_shows_pg_profile(self):
        table = report.env_table([self.with_pg("vm-a", "production"), self.with_pg("vm-b", None), fixture("vm-c")])
        row = next(r for r in table.rows if r[0] == "PostgreSQL profile")
        self.assertEqual(row[1:], ["production", "unset (set up before 0.2.1)", "-"])

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



class HardwareDifferences(unittest.TestCase):
    """report compare: the hardware.json fields that differ (new-a and new-b differ on purpose, see their files)."""
    WANT = ["cpu.microcode", "system.bios_version", "memory.populated", "memory.dimms count", "memory.dimms CPU1_B1",
            "memory.configured_speeds", "nics ens1f0"]

    def setUp(self):
        report.set_lang("en")
        self.addCleanup(report.set_lang, "en")

    def test_only_the_fields_that_differ(self):
        table, line = report.hw_differences([fixture("new-a"), fixture("new-b")])
        self.assertEqual([r[0] for r in table.rows], self.WANT)
        self.assertEqual(table.headers, ["Item", "new-a", "new-b"])
        rows = {r[0]: r[1:] for r in table.rows}
        self.assertEqual(rows["system.bios_version"], ["2.1.4", "2.2.0"])
        self.assertEqual(rows["memory.dimms count"], ["3", "2"])
        self.assertEqual(rows["memory.dimms CPU1_B1"][1], "-")
        self.assertEqual(rows["nics ens1f0"], ["firmware=22.36.1010 (EX_0000000001)", "firmware=22.39.2048 (EX_0000000001)"])
        self.assertEqual(line, "hardware.json: 54 fields compared, 6 differ")

    def test_same_fields_bmc_readings_and_reasons_are_not_listed(self):
        table, _ = report.hw_differences([fixture("new-a"), fixture("new-b")])
        items = " ".join(r[0] for r in table.rows)
        for same in ("cpu.model", "cpu.stepping", "system.bmc.firmware", "nics eno1", "disks", "nvme"):
            self.assertNotIn(same, items)
        self.assertNotIn("bmc.power_w", items)          # differs in the fixtures, but is a reading, not a fact
        self.assertNotIn("unavailable", items)           # differs too: reasons, not hardware

    def test_identical_machines_give_only_the_summary_line(self):
        table, line = report.hw_differences([fixture("new-a"), fixture("new-a")])
        self.assertIsNone(table)
        self.assertEqual(line, "hardware.json: 54 fields compared, 0 differ")

    def test_a_run_without_hardware_json_gives_no_table_and_a_warning(self):
        self.assertEqual(report.hw_differences([fixture("vm-a"), fixture("vm-b")]), (None, None))
        for pair, missing in ((("vm-a", "vm-b"), "vm-a, vm-b"), (("new-a", "vm-a"), "vm-a")):
            r = cli("compare", *[os.path.join(FIX, n) for n in pair], "--no-files")
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertNotIn("Hardware differences", r.stdout)
            self.assertIn(f"- no hardware.json for {missing} (", r.stdout)

    def test_text_md_and_html(self):
        with tempfile.TemporaryDirectory() as d:
            r = cli("compare", os.path.join(FIX, "new-a"), os.path.join(FIX, "new-b"), "--out", d)
            self.assertEqual(r.returncode, 0, r.stderr)
            out = r.stdout
            self.assertLess(out.index("== Environment"), out.index("== Hardware differences =="))
            self.assertIn("hardware.json: 54 fields compared, 6 differ", out)
            with open(os.path.join(d, "report.md"), encoding="utf-8") as f:
                md = f.read()
            self.assertIn("## Hardware differences", md)
            self.assertIn("| system.bios_version | 2.1.4 | 2.2.0 |", md)
            with open(os.path.join(d, "report.html"), encoding="utf-8") as f:
                page = f.read()
            self.assertIn("<h2>Hardware differences</h2>", page)
            self.assertIn("6 differ", page)
            p = Balanced()
            p.feed(page)
            self.assertEqual((p.errors, p.stack), (0, []))

    def test_thai(self):
        r = cli("compare", os.path.join(FIX, "new-a"), os.path.join(FIX, "new-b"), "--no-files", "--lang", "th")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("== ฮาร์ดแวร์ที่ต่างกัน ==", r.stdout)
        self.assertIn("รายการ", r.stdout)
        self.assertIn("เทียบ 54 ฟิลด์ ต่างกัน 6 ฟิลด์", r.stdout)
        r = cli("compare", os.path.join(FIX, "vm-a"), os.path.join(FIX, "vm-b"), "--no-files", "--lang", "th")
        self.assertIn("ไม่มี hardware.json ของ vm-a, vm-b", r.stdout)

    def test_show_is_unchanged(self):
        r = cli("show", os.path.join(FIX, "new-a"), "--no-files")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn("Hardware differences", r.stdout)
        self.assertNotIn("hardware.json", r.stdout)

    def test_xlsx_uses_the_same_helpers(self):
        spec = importlib.util.spec_from_file_location("xlsx_hw", os.path.join(ROOT, "xlsx.py"))
        xlsx = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(xlsx)
        for name in ("hw_json", "hw_text", "hw_get", "flatten_hw", "_MISSING"):
            self.assertIs(getattr(xlsx, name), getattr(xlsx.report, name), name)


class DiskWarning(unittest.TestCase):
    """Where the fio test file was (info.txt fio_where / fio_fs / fio_dir, vmbench 0.2.5+) decides the disk warning.
    disk-old is a v0.2.4 folder without those keys."""

    def warn(self, *names, lang="en"):
        report.set_lang(lang)
        try:
            return report.disk_warning([fixture(n) for n in names])
        finally:
            report.set_lang("en")

    def test_keys_are_read_from_info_txt(self):
        info = fixture("disk-other").info
        self.assertEqual((info["fio_where"], info["fio_fs"], info["fio_dir"]),
                         ("other", "/dev/mapper/datavg-bench", "/bench/bench data"))
        self.assertEqual(info["raw_dev"], "none")
        self.assertNotIn("fio_where", fixture("disk-old").info)

    def test_os_disk(self):
        self.assertEqual(self.warn("disk-os"), [
            "Disk: measured on a file on the OS disk, so the numbers may include host cache and hypervisor settings. "
            "Check the cache mode before concluding which storage is better"])
        self.assertEqual(self.warn("disk-os", lang="th"), [
            "Disk: วัดจากไฟล์บน OS disk ตัวเลขอาจรวมผลของ host cache และการตั้งค่า hypervisor "
            "ควรตรวจ cache mode ก่อนสรุปว่า storage ฝั่งไหนดีกว่า"])

    def test_other_disk(self):
        self.assertEqual(self.warn("disk-other"), [
            "Disk: measured on a file in /bench/bench data on a separate disk (/dev/mapper/datavg-bench), not the OS disk. "
            "Host cache and hypervisor settings may still be in the numbers, so check that disk's cache mode"])
        self.assertEqual(self.warn("disk-other", lang="th"), [
            "Disk: วัดจากไฟล์ใน /bench/bench data บนดิสก์แยก (/dev/mapper/datavg-bench) ไม่ใช่ OS disk "
            "ตัวเลขยังอาจรวมผลของ host cache และการตั้งค่า hypervisor ควรตรวจ cache mode ของดิสก์นั้น"])

    def test_unknown(self):
        self.assertEqual(self.warn("disk-unknown"), [
            "Disk: measured on a file in /bench-data (overlay); which disk holds it could not be told, so the numbers "
            "may include host cache and hypervisor settings. Check the storage behind it and its cache mode "
            "before concluding which storage is better"])
        th = self.warn("disk-unknown", lang="th")
        self.assertEqual(len(th), 1)
        self.assertTrue(th[0].startswith("Disk: วัดจากไฟล์ใน /bench-data (overlay) ระบุไม่ได้ว่าอยู่บนดิสก์ไหน"), th)

    def test_memory_and_network_filesystems(self):
        self.assertEqual(self.warn("disk-tmpfs"), [
            "Disk: measured on a file in /dev/shm/bench on tmpfs, which is memory, not a disk: the disk values are "
            "not storage results"])
        self.assertIn("ซึ่งเป็นหน่วยความจำ ไม่ใช่ดิสก์", self.warn("disk-tmpfs", lang="th")[0])
        self.assertEqual(self.warn("disk-nfs"), [
            "Disk: measured on a file in /mnt/share/bench on a network or host-shared filesystem (nfs4), so the "
            "numbers include the network and the server's cache, not only a disk"])
        self.assertIn("filesystem ทางเครือข่ายหรือที่แชร์จาก host (nfs4)", self.warn("disk-nfs", lang="th")[0])

    def test_absent_key_is_neutral(self):
        for lang, neutral in (("en", "Disk: measured on a file in the data directory, not on a raw device; which disk "
                                     "holds it was not recorded (vmbench 0.2.4 or older)"),
                              ("th", "Disk: วัดจากไฟล์ใน data directory ไม่ใช่ raw device ไม่ได้บันทึกว่าอยู่บนดิสก์ไหน "
                                     "(vmbench 0.2.4 หรือเก่ากว่า)")):
            out = self.warn("disk-old", lang=lang)
            self.assertEqual(len(out), 1)
            self.assertTrue(out[0].startswith(neutral), out)
            self.assertNotIn("OS disk", out[0])
        self.assertTrue(self.warn("rounds-a")[0].startswith("Disk: measured on a file in the data directory"))

    def test_no_warning_without_disk_results_or_with_a_raw_device(self):
        cpu_only = fixture("disk-os")
        cpu_only.metrics = [m for m in cpu_only.metrics if not m.id.startswith("disk.")]
        self.assertEqual(report.disk_warning([cpu_only]), [])
        raw = fixture("disk-os")
        raw.info["raw_dev"] = "/dev/nvme1n1"
        self.assertEqual(report.disk_warning([raw]), [])

    def test_same_case_gives_one_warning(self):
        self.assertEqual(self.warn("disk-os", "disk-os"), self.warn("disk-os"))
        self.assertEqual(self.warn("disk-old", "rounds-a"), self.warn("disk-old"))

    def test_same_case_on_different_devices_gives_one_warning(self):
        # two machine types, each with a separate data disk under another name: one line, the devices per run
        a, b = fixture("disk-other"), fixture("disk-other")
        a.label, b.label = "x86", "arm"
        b.info["fio_fs"] = "/dev/vdb"
        self.assertEqual(report.disk_warning([a, b]), [
            "Disk: measured on a file in /bench/bench data on a separate disk (x86: /dev/mapper/datavg-bench, "
            "arm: /dev/vdb), not the OS disk. Host cache and hypervisor settings may still be in the numbers, so "
            "check that disk's cache mode"])

    def test_file_runs_are_named_next_to_a_raw_device_run(self):
        raw = fixture("disk-other")
        raw.label, raw.info["raw_dev"] = "raw", "/dev/nvme1n1"
        out = report.disk_warning([fixture("disk-os"), raw])
        self.assertEqual(len(out), 1)
        self.assertTrue(out[0].startswith("Disk (disk-os): measured on a file on the OS disk"), out)

    def test_different_cases_give_one_warning_each_with_labels(self):
        out = self.warn("disk-os", "disk-other", "disk-old")
        self.assertEqual(len(out), 3)
        self.assertTrue(out[0].startswith("Disk (disk-os): measured on a file on the OS disk"), out)
        self.assertTrue(out[1].startswith("Disk (disk-other): measured on a file in /bench/bench data on a separate disk"), out)
        self.assertTrue(out[2].startswith("Disk (disk-old): measured on a file in the data directory"), out)
        th = self.warn("disk-os", "disk-other", lang="th")
        self.assertTrue(th[0].startswith("Disk (disk-os): วัดจากไฟล์บน OS disk"), th)

    def test_environment_table_shows_where(self):
        table = report.env_table([fixture("disk-other"), fixture("disk-old")])
        row = next(r for r in table.rows if r[0] == "fio file / raw device")
        self.assertEqual(row[1:], ["8G (other: /dev/mapper/datavg-bench) / none", "8G / none"])

    def test_v024_folder_still_compares(self):
        for lang, neutral in (("en", "- Disk: measured on a file in the data directory"), ("th", "- Disk: วัดจากไฟล์ใน data directory")):
            r = cli("compare", os.path.join(FIX, "disk-old"), os.path.join(FIX, "rounds-a"), "--no-files", "--lang", lang)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn(neutral, r.stdout)
            self.assertNotIn("OS disk", r.stdout)
        r = cli("compare", os.path.join(FIX, "disk-old"), os.path.join(FIX, "disk-other"), "--no-files")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("- Disk (disk-old): measured on a file in the data directory", r.stdout)
        self.assertIn("- Disk (disk-other): measured on a file in /bench/bench data on a separate disk", r.stdout)


if __name__ == "__main__":
    unittest.main()
