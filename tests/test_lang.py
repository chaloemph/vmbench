"""Tests for the report language: the message catalogs and the --lang / VMBENCH_LANG switch.

Run:  python3 -I -B -m unittest discover -s tests -v     (or: bash tests/run.sh)
"""
import importlib.util
import itertools
import os
import string
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
FIX = os.path.join(HERE, "fixtures")
REPORT = os.path.join(os.path.dirname(HERE), "report.py")
FIXTURES = ("new-a", "new-b", "vm-a", "vm-b", "vm-c")

spec = importlib.util.spec_from_file_location("report_lang", REPORT)
report = importlib.util.module_from_spec(spec)
sys.modules["report_lang"] = report
spec.loader.exec_module(report)


def thai(text):
    return [c for c in text if "฀" <= c <= "๿"]


def placeholders(message):
    return sorted(name for _, name, _, _ in string.Formatter().parse(message) if name is not None)


def run_cli(*args, env=None):
    e = {k: v for k, v in os.environ.items() if k != "VMBENCH_LANG"}
    e.update(env or {})
    return subprocess.run([sys.executable, "-I", "-B", REPORT, *args], capture_output=True, text=True,
                          encoding="utf-8", env=e)


def folders():
    """Every command line the language tests run: show for each fixture, compare for each pair and a three-way."""
    cases = [("show", FIX + "/" + n) for n in FIXTURES]
    cases += [("compare", f"{FIX}/{a}", f"{FIX}/{b}") for a, b in itertools.permutations(FIXTURES, 2)]
    cases.append(("compare", f"{FIX}/vm-a", f"{FIX}/vm-b", f"{FIX}/new-a"))
    return cases


class Catalog(unittest.TestCase):
    def test_languages_are_en_and_th(self):
        self.assertEqual(sorted(report.MESSAGES), ["en", "th"])

    def test_both_catalogs_have_exactly_the_same_keys(self):
        en, th = set(report.MESSAGES["en"]), set(report.MESSAGES["th"])
        self.assertEqual(en - th, set(), "missing in th")
        self.assertEqual(th - en, set(), "missing in en")

    def test_both_catalogs_use_the_same_placeholders(self):
        for key, message in report.MESSAGES["en"].items():
            self.assertEqual(placeholders(message), placeholders(report.MESSAGES["th"][key]), key)

    def test_no_thai_in_the_english_catalog(self):
        for key, message in report.MESSAGES["en"].items():
            self.assertEqual(thai(message), [], key)

    def test_html_language_codes(self):
        self.assertEqual(report.MESSAGES["th"]["lang.html"], "th")
        self.assertEqual(report.MESSAGES["en"]["lang.html"], "en")
        self.assertTrue(thai(report.MESSAGES["th"]["warn.quick"]))

    def test_t_formats_and_rejects_a_missing_argument(self):
        report.set_lang("en")
        self.assertEqual(report.t("warn.vmbench", values="a=1"), "vmbench versions differ: a=1")
        with self.assertRaises(KeyError):
            report.t("warn.vmbench")

    def test_unknown_language_is_an_input_error(self):
        with self.assertRaises(report.InputError):
            report.set_lang("xx")
        self.assertIn(report.LANG, ("en", "th"))


class EnglishOutput(unittest.TestCase):
    def test_no_thai_in_stdout_markdown_or_html_for_any_fixture(self):
        with tempfile.TemporaryDirectory() as d:
            for i, case in enumerate(folders()):
                out = os.path.join(d, str(i))
                r = run_cli(*case, "--out", out)
                self.assertEqual(r.returncode, 0, (case, r.stderr))
                texts = {"stdout": r.stdout, "stderr": r.stderr}
                for name in ("report.md", "report.html"):
                    with open(os.path.join(out, name), encoding="utf-8") as f:
                        texts[name] = f.read()
                for name, text in texts.items():
                    self.assertEqual(thai(text), [], (case, name))
                self.assertIn('<html lang="en">', texts["report.html"])

    def test_english_is_the_default_and_matches_lang_en(self):
        case = ("compare", FIX + "/vm-a", FIX + "/vm-b", "--no-files")
        self.assertEqual(run_cli(*case).stdout, run_cli(*case, "--lang", "en").stdout)

    def test_verdicts_and_headings_are_english(self):
        r = run_cli("compare", FIX + "/vm-a", FIX + "/vm-b", "--no-files")
        for word in ("== Environment ==", "Verdict", "vm-b better", "== Warnings =="):
            self.assertIn(word, r.stdout)


class ThaiOutput(unittest.TestCase):
    def test_lang_th_prints_thai(self):
        r = run_cli("compare", FIX + "/vm-a", FIX + "/vm-b", "--no-files", "--lang", "th")
        self.assertEqual(r.returncode, 0, r.stderr)
        for word in ("== สภาพแวดล้อม ==", "vm-b ดีกว่า", "== ข้อควรระวัง =="):
            self.assertIn(word, r.stdout)

    def test_env_var_selects_thai_and_the_flag_wins(self):
        case = ("show", FIX + "/vm-a", "--no-files")
        self.assertIn("สภาพแวดล้อม", run_cli(*case, env={"VMBENCH_LANG": "th"}).stdout)
        self.assertIn("Environment", run_cli(*case, "--lang", "en", env={"VMBENCH_LANG": "th"}).stdout)

    def test_thai_html_declares_thai(self):
        with tempfile.TemporaryDirectory() as d:
            run_cli("show", FIX + "/vm-a", "--lang", "th", "--out", d)
            with open(os.path.join(d, "report.html"), encoding="utf-8") as f:
                self.assertIn('<html lang="th">', f.read())

    def test_thai_columns_stay_aligned(self):
        """Combining marks take no width, so the cells of a Thai table line up with its header."""
        report.set_lang("th")
        try:
            table = report.env_table([report.Run(FIX + "/vm-a"), report.Run(FIX + "/vm-b")])
            lines = report.text_table(table).splitlines()[3:]   # after the title, header and rule
            self.assertEqual(report.width("ไม่"), 2)
            first = max(report.width(r[0]) for r in table.rows) + 2   # where the second column starts
            for line, row in zip(lines, table.rows):
                self.assertTrue(line.startswith(row[0]))
                rest = line[len(row[0]):]
                self.assertEqual(report.width(row[0]) + len(rest) - len(rest.lstrip()), first, row[0])
        finally:
            report.set_lang("en")


class Errors(unittest.TestCase):
    def test_unknown_language_in_the_environment_exits_2(self):
        r = run_cli("show", FIX + "/vm-a", "--no-files", env={"VMBENCH_LANG": "xx"})
        self.assertEqual(r.returncode, 2)
        self.assertIn("unknown language", r.stderr)

    def test_unknown_language_flag_is_rejected(self):
        r = run_cli("show", FIX + "/vm-a", "--no-files", "--lang", "xx")
        self.assertEqual(r.returncode, 2)


if __name__ == "__main__":
    unittest.main()
