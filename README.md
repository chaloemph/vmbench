# vmbench

One-command VM performance benchmark for CPU, memory, disk, PostgreSQL, network and web. Compare x86 and ARM runs side by side.

vmbench runs a fixed set of well-known tools (sysbench, 7-Zip, OpenSSL, STREAM, lmbench, fio, pgbench, iperf3, sockperf, stressapptest and [cpubench](https://github.com/chaloemph/cpubench)) inside a Linux VM, records every value, and turns the results into tables. It can also compare two or more runs and say which side is better, without calling a difference a win when it is smaller than the run-to-run noise.

> **Status: early version.** It has been run end to end for the `cpu`, `mem`, `disk` and `web` stages on Ubuntu 24.04 KVM guests (x86_64 and aarch64). The `pg`, `net` and `burnin` stages passed their pre-flight checks but have not yet been run to completion on real machines. Reports are in English; `--lang th` gives the Thai text of earlier versions. There is no release yet: until the first one is published the one-line installer below stops with a message, and a clone of this repository is the way to run it.

## What it measures

| Stage | Tests | Tools | Runs by default |
|---|---|---|:---:|
| `cpu` | integer, floating point, crypto, compression, 1 thread and all vCPUs, 3 rounds by default | sysbench, 7-Zip, OpenSSL, cpubench | yes |
| `mem` | memory bandwidth and latency, 3 rounds by default | STREAM, lmbench `lat_mem_rd` | yes |
| `disk` | random and sequential I/O, queue-depth sweep, WAL-style `fdatasync` latency; 1 round by default, see [Rounds](#rounds) | fio | yes |
| `pg` | PostgreSQL TPC-B-like throughput, stability and single-session latency | pgbench | |
| `net` | TCP throughput, UDP packet rate, round-trip latency to a peer | iperf3, sockperf | |
| `web` | maximum requests per second within a latency target (loopback), 3 rounds by default | cpubench | |
| `burnin` | memory and disk error check over a long period | stressapptest, fio | |

`info` always runs: it records the kernel, CPU model, flags, NUMA layout, disks, tool versions and CPU steal, because a result without them cannot be interpreted later.

Each value in `results.tsv` has a stable ID of the form `<stage>.<tool>.<test>[.<variant>]`, for example `cpu.sysbench.prime.1t` (one thread) or `mem.stream.triad.max` (all vCPUs). The full list, with what each one measures, its tool, unit and whether higher or lower is better, is in [docs/tests.md](docs/tests.md); `vmbench run --metrics` prints the same table. Result folders from older versions, which numbered the rows after a spreadsheet, still load: `report.py` maps those rows to the IDs.

## Requirements

Ubuntu 24.04 (other recent Linux distributions should work but are untested), `bash`, `python3` 3.8+, `curl`, `jq`, and the tools of the stages you run:

```bash
sudo apt-get install -y sysbench fio 7zip iperf3 sockperf stressapptest lmbench gcc numactl sysstat jq tmux postgresql postgresql-contrib
```

The `mem` stage compiles STREAM from a pinned source file, see [STREAM source](#stream-source). Running the benchmark itself needs no `sudo`. The test files are created under `~/bench-data` (8 GB for `disk`, so keep at least 15 GB free).

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/chaloemph/vmbench/main/get.sh | sh
```

This downloads the newest release tarball and its `SHA256SUMS`, checks the sha256 (a mismatch stops it before anything is extracted), and installs into your home folder: `~/.local/share/vmbench/<version>`, a `current` link to it, and `~/.local/bin/vmbench`. It never uses `sudo` and refuses to run as root; it does not install packages (it prints the `apt-get` line for the benchmark tools, see [Requirements](#requirements)). If no release exists yet it says so and installs nothing. It does not fall back to the moving `main` branch.

**Pin a version** (use the same one on every machine you compare):

```bash
curl -fsSL https://raw.githubusercontent.com/chaloemph/vmbench/main/get.sh | VMBENCH_VERSION=v0.1.0 sh
curl -fsSL https://raw.githubusercontent.com/chaloemph/vmbench/main/get.sh | sh -s -- --version v0.1.0
```

**Read the script first**, it is short, instead of piping it:

```bash
curl -fsSLO https://raw.githubusercontent.com/chaloemph/vmbench/main/get.sh
less get.sh
sh get.sh --dry-run          # prints every step, changes nothing
sh get.sh
```

**Verify a release by hand**, without get.sh:

```bash
v=v0.1.0
base=https://github.com/chaloemph/vmbench/releases/download/$v
curl -fsSLO "$base/vmbench-$v.tar.gz" -O "$base/SHA256SUMS"
sha256sum -c --ignore-missing SHA256SUMS      # must say: vmbench-v0.1.0.tar.gz: OK
tar -xzf "vmbench-$v.tar.gz" && ./vmbench-$v/vmbench version
```

**Options:** `--version V`, `--prefix DIR` (or `VMBENCH_HOME`), `--dir DIR`, `--bin-dir DIR`, `--dry-run`, `--uninstall`, `--allow-root`, `--help`; `sh get.sh --help` explains each. The release tarball holds the program and its docs, not `tests/` or `.github/`.

**Uninstall:**

```bash
sh get.sh --uninstall                       # removes ~/.local/share/vmbench and the ~/.local/bin/vmbench link
sh get.sh --uninstall --version v0.1.0      # only that version
```

(or `curl -fsSL .../get.sh | sh -s -- --uninstall`). Result folders under `~/bench-results` are never touched. If `~/.local/bin` is not in your `PATH`, get.sh tells you what to add. Maintainers: [docs/releasing.md](docs/releasing.md).

## Quick start (from a clone, for development)

```bash
git clone https://github.com/chaloemph/vmbench.git
cd vmbench
./vmbench setup cpubench        # downloads cpubench from its GitHub release and verifies the sha256
./vmbench list                  # shows every stage and whether this machine is ready for it
./vmbench run                   # cpu, mem, disk
```

`vmbench` finds its own folder, so it works from any directory and through a symlink (for example `ln -s "$PWD/vmbench" ~/.local/bin/vmbench`). The older commands still work and do the same: `bash run-benchmark.sh ...` is `vmbench run ...`, `bash setup-cpubench.sh` is `vmbench setup cpubench`, and `bash setup-postgres-bench.sh` is `vmbench setup postgres`.

Long runs belong in `tmux`, so a dropped SSH session does not stop them. `--detach` does that for you:

```bash
LABEL=my-vm ./vmbench run --with web --detach     # pre-flight in the foreground, then runs in tmux session vmbench-my-vm and returns
./vmbench status                                  # running or not, current stage, elapsed time (newest result folder; or: vmbench status DIR)
tmux attach -t vmbench-my-vm                      # watch it; leave with Ctrl-b d, the run keeps going
```

or start `tmux` yourself (`tmux new -s bench`, then `vmbench run ...`).

A full run of `cpu`, `mem` and `disk` took about 1.5 hours on 8 vCPU VMs with an 8 GB test file, most of it in `disk`.

## Options

```text
vmbench run [--with LIST | --only LIST] [--peer HOST] [--hours N] [--rounds N] [--disk-rounds N] [--detach [--session NAME]] [--list] [--metrics] [--help]
vmbench status [DIR]
```

`bash run-benchmark.sh` takes the same options as `vmbench run`.

| Option | Meaning |
|---|---|
| `--with LIST` | add stages to the default ones, for example `--with web,pg` |
| `--only LIST` | run only these stages (cannot be combined with `--with`) |
| `--peer HOST` | peer machine for `net`; it must run `iperf3 -s -D` and `sockperf server -i 0.0.0.0 &` |
| `--hours N` | length of the burn-in (default 48) |
| `--rounds N` | repeats of `cpu`, `mem` and `web` (default 3), see [Rounds](#rounds) |
| `--disk-rounds N` | repeats of the `disk` stage (default 1; each extra round is about 20 minutes) |
| `--detach` | after the pre-flight passes, run in a new tmux session and return at once. Pre-flight errors are still printed in the foreground (exit 2, nothing started). Refused when tmux is missing or the session already exists |
| `--session NAME` | name of that tmux session (default `vmbench-<label>`) |
| `--list` | show stages, typical duration (it follows the rounds) and readiness of this machine |
| `--metrics` | print the table of metric IDs and exit |

Before anything runs, every selected stage is checked (missing tools, missing cpubench, free space, database connection, peer reachability, raw-device safety). If something is missing, vmbench prints all of it and exits with code 2 without running anything.

Settings are environment variables: `LABEL` (name of the machine in the results), `OUT` (result folder, default `~/bench-results/<label>-<time>`), `ROUNDS` (repeats of cpu, mem and web, default 3), `MEM_ROUNDS`, `WEB_ROUNDS` (one of them), `DISK_ROUNDS` (default 1), `QUICK=1` (short smoke run, **not** for real numbers), `FIO_SIZE` (default `8G`), `DATA_DIR`, `DB_DIR`, `WAL_DIR`, `PGPORT`, `PGDATABASE`, `CB` (cpubench folder). `vmbench run --help` lists them all.

### Rounds

Every stage that repeats writes one row per value per round into `results.tsv` (the `round` column), so `report.py` shows the median and the coefficient of variation (CV) of all of them, and `compare` does not call a difference a win when it is inside that noise.

| Stage | Default | Set with | What one round is |
|---|---|---|---|
| `cpu` | 3 | `--rounds N`, `ROUNDS` | every cpu test (about 6 min) |
| `mem` | 3 | `--rounds N`, `MEM_ROUNDS` | STREAM and `lat_mem_rd` once (about 1 min; `stream.c` is compiled once) |
| `web` | 3 | `--rounds N`, `WEB_ROUNDS` | one loopback web test (about 6 min) |
| `disk` | 1 | `--disk-rounds N`, `DISK_ROUNDS` | round 1 is the whole sequence; rounds 2 to N repeat only the 4 KiB random-read latency (p99, p99.9), random read, 70/30 mix and the WAL `fdatasync` test (about 20 min each) |

`ROUNDS` is the default of `mem` and `web` as well; `MEM_ROUNDS` and `WEB_ROUNDS` override it for one stage, and `--rounds N` overrides all three. `QUICK=1` runs one round unless you ask for more. A value must be a whole number of 1 or more; anything else exits with code 2 before anything runs. `meta.json` records the count of each stage (`rounds_by_stage`).

Disk repeats stay short on purpose: the 8 GB fill, the steady-state random write (which depends on the state the previous test left), the sequential tests, the queue-depth sweep and the DB-style tests each take long and would turn 71 minutes into hours, so they run once. The repeated tests are the ones whose noise matters most for a decision (latency tail, random IOPS, mixed load, commit latency). Details in [docs/tests.md](docs/tests.md#rounds).

### STREAM source

The `mem` stage compiles `stream.c` from the official [jeffhammond/STREAM](https://github.com/jeffhammond/STREAM) repository. The file is pinned, so every run measures with the same source, and it is checked before it is compiled:

- commit `6703f7504a38a8da96b353cadafa64d3c2d7a2d3`
- URL `https://raw.githubusercontent.com/jeffhammond/STREAM/6703f7504a38a8da96b353cadafa64d3c2d7a2d3/stream.c`
- sha256 `c388924eb140fda95f534cdb808ae7f1f8ebb18da41d8aec1b512a3c8d303c9b`

A file with another hash (a changed download, a stale copy in `~/bench-cache/stream.c`, a wrong local file) is never compiled: the step is recorded as `FAIL` in `status.tsv` with the expected and the actual hash in `run.log`. The cached copy is checked too, and replaced when it does not match. The source that was used is written to `info.txt` (`stream: ...`).

| Variable | Meaning |
|---|---|
| `STREAM_C=/path/to/stream.c` | offline: use this file instead of downloading it. It must have the pinned sha256 as well |
| `STREAM_SKIP_CHECK=1` | do not check the hash (for a deliberately different STREAM). Warns loudly and `info.txt` says `UNVERIFIED`; do not compare such a run with others |
| `STREAM_URL=...` | download from somewhere else (a mirror); the hash is still checked |

`bash lib/stream.sh [DEST]` fetches and checks the file without running a stage. To move the pin, change `STREAM_COMMIT` and `STREAM_SHA256` in `lib/stream.sh` together and update this section and `docs/tests.md`.

### PostgreSQL stage

`vmbench setup postgres` (or `bash setup-postgres-bench.sh`) creates a separate PostgreSQL cluster named `bench` on port 5433, a role named after your OS user, and the database `bench`. It needs `sudo` and does not touch the default cluster.

### Raw disk

With `RAW_DEV=/dev/sdX CONFIRM_WIPE=yes` the `disk` and `burnin` stages write to the whole device and **erase it**. They refuse a device that has a filesystem, a mount point or partitions. Without `RAW_DEV` they use files on the normal filesystem.

## Reports

Every run also writes `meta.json` (vmbench and cpubench version, label, stages, `QUICK`, rounds of each stage, start and end time in UTC, architecture, vCPU count; no host name or address). `report.py` reads it, and falls back to `info.txt` for runs that have none. A `meta.json` whose `end_utc` is `null` belongs to a run that did not finish.

Every run ends by printing tables and writing `report.md` and `report.html` into the result folder. The text is English. `--lang th` (or `VMBENCH_LANG=th`) gives the Thai text of earlier versions: same numbers and verdicts, only the words differ. You can also run the report on its own:

```bash
./vmbench report show    ~/bench-results/vm-a
./vmbench report compare ~/bench-results/vm-a ~/bench-results/vm-b   # first folder is the baseline
./vmbench report show    ~/bench-results/vm-a --lang th               # Thai text
```

(`python3 report.py show|compare ...` does the same.) `compare` accepts two or more folders, prints to stdout, and writes `report.md` and `report.html` into `./compare-<a>-vs-<b>/`. Add `--no-files` for stdout only.

Marks and warnings you will see:

- `*` the value was measured once (one round), so its variation is unknown. With the default rounds only `disk` values (1 round) and the CPU steal context values still carry it; `--disk-rounds` removes it from disk
- `!` the coefficient of variation is 5% or more
- "not clearly different": the difference is within the larger CV of the two runs, or 1%
- warnings for different cpubench versions, `QUICK=1`, different test sizes or vCPU counts, high CPU steal, failed stages, and disk results taken from files rather than a raw device

## Reading the results correctly

[docs/reading-results.md](docs/reading-results.md) explains every value: what it measures, whether higher or lower is better, what it means for real work (web servers, databases, file servers and so on), and which values to look at first for a given workload. Before comparing two machines, keep these in mind:

- **A VM hides the hardware.** There is no view of the BIOS, DIMMs, firmware or power. Disk numbers include the hypervisor's cache and storage settings, so a large gap between two VMs can come from configuration rather than from the disk. Ask for the cache mode before drawing a conclusion.
- **Watch CPU steal.** `info` records the average and maximum steal during the run. A host that is busy with other VMs makes the result lower than the machine can really do.
- **Use the same version everywhere.** Compare runs only when they used the same vmbench and cpubench versions.
- **Pair the VMs fairly.** Same vCPU count and RAM, CPU type set to `host` (not `kvm64`), the same disk type, and memory pinned to one NUMA node.
- **`sysbench cpu` does not compare ISAs.** It counts prime numbers, so the score depends on the compiler. Use it only between machines of the same architecture.

## Privacy

The result folder contains `info.txt`, which lists the host name, IP addresses, disks and the busiest processes. `.gitignore` excludes result folders, but do not attach or publish raw result folders without reading them first. The generated reports contain no IP addresses, but they show the `LABEL` you gave the machine (the default is its short host name), so choose a neutral label before sharing a report. `meta.json` holds no host name or address, only the `LABEL`.

## Files

| File | Purpose |
|---|---|
| `vmbench` | entry script: `run`, `list`, `report`, `setup`, `version`, `help` |
| `run-benchmark.sh` | compatibility wrapper, the same as `vmbench run` |
| `lib/` | shared helpers: `common.sh` (logging, `die`), `metrics.sh` (the metric table and `rec`), `preflight.sh`, `rawdev.sh` (raw-device safety), `meta.sh` (`meta.json`), `stages.sh` (stage loader), `run.sh` (option parsing and the run), `run-usage.txt` (the `--help` text) |
| `stages/<stage>.sh` | one file per stage: `cpu`, `mem`, `disk`, `pg`, `net`, `web`, `burnin`, `info`. Adding a stage means adding one file, see [docs/tests.md](docs/tests.md) |
| `lib/stream.sh` | the pinned STREAM source: URL, sha256, download and check |
| `report.py` | tables and comparisons, English and Thai message catalogs (standard library only) |
| `docs/tests.md` | every metric ID: what it measures, tool, unit, direction, stage; how to add a stage |
| `docs/reading-results.md` | how to read a report, and what each value means for real work |
| `get.sh` | the installer behind the one-line `curl ... \| sh` (POSIX sh, sha256-verified release download, no sudo) |
| `scripts/build-release.sh` | builds the reproducible release tarball and `SHA256SUMS` (used by the release workflow) |
| `VERSION` | `0.0.0-dev` in the repository; the release build stamps the tag into it. A git checkout still reports `git describe` |
| `docs/releasing.md` | how to cut, verify and withdraw a release |
| `setup/cpubench.sh` | downloads a cpubench release (`VERSION=latest` by default, or a tag such as `VERSION=v0.1.0`) |
| `setup/postgres.sh` | creates the PostgreSQL cluster, role and database for the `pg` stage |
| `setup-cpubench.sh`, `setup-postgres-bench.sh` | wrappers for the two setup scripts at their old paths |

## Development

```bash
bash tests/run.sh
```

runs the Python tests for `report.py` (including that the English and Thai message catalogs have the same keys and placeholders, and that no Thai appears in English output) and the metric IDs (the table in `lib/metrics.sh`, `docs/tests.md` and the old-format mapping must agree), the command line tests for `vmbench` and `run-benchmark.sh`, a test that every file in `stages/` defines the required functions, tests of the STREAM pin with a synthetic `stream.c`, the `get.sh` installer against a fake release on `127.0.0.1` (checksum mismatch, unsafe tar paths, dry run, uninstall, a truncated script), and the release tarball build (reproducible bytes, contents, install with `get.sh`). They need no benchmark tools, no network and no `sudo`. The test data under `tests/fixtures/` is synthetic (made-up numbers), never a real measurement.

CI (GitHub Actions) runs the same tests on x86_64 and aarch64, plus `bash -n` and ShellCheck (`-x`, warnings and errors) on every shell file including `lib/` and `stages/`, `shellcheck -s sh` and `dash -n` on `get.sh`, a job that builds the release tarball and installs it with `get.sh` locally (nothing is published), and a gitleaks secret scan of the whole history. `main` is protected: change it through a pull request.

## License

Apache License 2.0, see [LICENSE](LICENSE).
