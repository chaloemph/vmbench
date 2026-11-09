# vmbench

One-command VM performance benchmark for CPU, memory, disk, PostgreSQL, network and web. Compare x86 and ARM runs side by side.

vmbench runs a fixed set of well-known tools (sysbench, 7-Zip, OpenSSL, STREAM, lmbench, fio, pgbench, iperf3, sockperf, stressapptest and [cpubench](https://github.com/chaloemph/cpubench)) inside a Linux VM, records every value, and turns the results into tables. It can also compare two or more runs and say which side is better, without calling a difference a win when it is smaller than the run-to-run noise.

> **Status: early version.** It has been run end to end for the `cpu`, `mem`, `disk` and `web` stages on Ubuntu 24.04 KVM guests (x86_64 and aarch64). The `pg`, `net` and `burnin` stages passed their pre-flight checks but have not yet been run to completion on real machines. The report text is currently in Thai (English is planned). There is no release yet, so use a clone of this repository.

## What it measures

| Stage | Tests | Tools | Runs by default |
|---|---|---|:---:|
| `cpu` | integer, floating point, crypto, compression, 1 thread and all vCPUs, 3 rounds | sysbench, 7-Zip, OpenSSL, cpubench | yes |
| `mem` | memory bandwidth and latency | STREAM, lmbench `lat_mem_rd` | yes |
| `disk` | random and sequential I/O, queue-depth sweep, WAL-style `fdatasync` latency | fio | yes |
| `pg` | PostgreSQL TPC-B-like throughput, stability and single-session latency | pgbench | |
| `net` | TCP throughput, UDP packet rate, round-trip latency to a peer | iperf3, sockperf | |
| `web` | maximum requests per second within a latency target (loopback) | cpubench | |
| `burnin` | memory and disk error check over a long period | stressapptest, fio | |

`info` always runs: it records the kernel, CPU model, flags, NUMA layout, disks, tool versions and CPU steal, because a result without them cannot be interpreted later.

Each value in `results.tsv` has a stable ID of the form `<stage>.<tool>.<test>[.<variant>]`, for example `cpu.sysbench.prime.1t` (one thread) or `mem.stream.triad.max` (all vCPUs). The full list, with what each one measures, its tool, unit and whether higher or lower is better, is in [docs/tests.md](docs/tests.md); `vmbench run --metrics` prints the same table. Result folders from older versions, which numbered the rows after a spreadsheet, still load: `report.py` maps those rows to the IDs.

## Requirements

Ubuntu 24.04 (other recent Linux distributions should work but are untested), `bash`, `python3` 3.8+, `curl`, `jq`, and the tools of the stages you run:

```bash
sudo apt-get install -y sysbench fio 7zip iperf3 sockperf stressapptest lmbench gcc numactl sysstat jq tmux postgresql postgresql-contrib
```

Running the benchmark itself needs no `sudo`. The test files are created under `~/bench-data` (8 GB for `disk`, so keep at least 15 GB free).

## Quick start

```bash
git clone https://github.com/chaloemph/vmbench.git
cd vmbench
./vmbench setup cpubench        # downloads cpubench from its GitHub release and verifies the sha256
./vmbench list                  # shows every stage and whether this machine is ready for it
./vmbench run                   # cpu, mem, disk
```

`vmbench` finds its own folder, so it works from any directory and through a symlink (for example `ln -s "$PWD/vmbench" ~/.local/bin/vmbench`). The older commands still work and do the same: `bash run-benchmark.sh ...` is `vmbench run ...`, `bash setup-cpubench.sh` is `vmbench setup cpubench`, and `bash setup-postgres-bench.sh` is `vmbench setup postgres`.

Long runs belong in `tmux`, so a dropped SSH session does not stop them:

```bash
tmux new -s bench
LABEL=my-vm ./vmbench run --with web
```

A full run of `cpu`, `mem` and `disk` took about 1.5 hours on 8 vCPU VMs with an 8 GB test file, most of it in `disk`.

## Options

```text
vmbench run [--with LIST | --only LIST] [--peer HOST] [--hours N] [--list] [--metrics] [--help]
```

`bash run-benchmark.sh` takes the same options.

| Option | Meaning |
|---|---|
| `--with LIST` | add stages to the default ones, for example `--with web,pg` |
| `--only LIST` | run only these stages (cannot be combined with `--with`) |
| `--peer HOST` | peer machine for `net`; it must run `iperf3 -s -D` and `sockperf server -i 0.0.0.0 &` |
| `--hours N` | length of the burn-in (default 48) |
| `--list` | show stages, typical duration and readiness of this machine |
| `--metrics` | print the table of metric IDs and exit |

Before anything runs, every selected stage is checked (missing tools, missing cpubench, free space, database connection, peer reachability, raw-device safety). If something is missing, vmbench prints all of it and exits with code 2 without running anything.

Settings are environment variables: `LABEL` (name of the machine in the results), `OUT` (result folder, default `~/bench-results/<label>-<time>`), `ROUNDS` (cpu repeats, default 3), `QUICK=1` (short smoke run, **not** for real numbers), `FIO_SIZE` (default `8G`), `DATA_DIR`, `DB_DIR`, `WAL_DIR`, `PGPORT`, `PGDATABASE`, `CB` (cpubench folder). `vmbench run --help` lists them all.

### PostgreSQL stage

`vmbench setup postgres` (or `bash setup-postgres-bench.sh`) creates a separate PostgreSQL cluster named `bench` on port 5433, a role named after your OS user, and the database `bench`. It needs `sudo` and does not touch the default cluster.

### Raw disk

With `RAW_DEV=/dev/sdX CONFIRM_WIPE=yes` the `disk` and `burnin` stages write to the whole device and **erase it**. They refuse a device that has a filesystem, a mount point or partitions. Without `RAW_DEV` they use files on the normal filesystem.

## Reports

Every run also writes `meta.json` (vmbench and cpubench version, label, stages, `QUICK`, start and end time in UTC, architecture, vCPU count; no host name or address). `report.py` reads it, and falls back to `info.txt` for runs that have none. A `meta.json` whose `end_utc` is `null` belongs to a run that did not finish.

Every run ends by printing tables and writing `report.md` and `report.html` into the result folder. You can also run the report on its own:

```bash
./vmbench report show    ~/bench-results/vm-a
./vmbench report compare ~/bench-results/vm-a ~/bench-results/vm-b   # first folder is the baseline
```

(`python3 report.py show|compare ...` does the same.) `compare` accepts two or more folders, prints to stdout, and writes `report.md` and `report.html` into `./compare-<a>-vs-<b>/`. Add `--no-files` for stdout only.

Marks and warnings you will see:

- `*` the value was measured once, so its variation is unknown (currently `mem`, `disk` and `web`)
- `!` the coefficient of variation is 5% or more
- "not clearly different": the difference is within the larger CV of the two runs, or 1%
- warnings for different cpubench versions, `QUICK=1`, different test sizes or vCPU counts, high CPU steal, failed stages, and disk results taken from files rather than a raw device

## Reading the results correctly

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
| `report.py` | tables and comparisons (standard library only) |
| `docs/tests.md` | every metric ID: what it measures, tool, unit, direction, stage; how to add a stage |
| `setup/cpubench.sh` | downloads a cpubench release (`VERSION=latest` by default, or a tag such as `VERSION=v0.1.0`) |
| `setup/postgres.sh` | creates the PostgreSQL cluster, role and database for the `pg` stage |
| `setup-cpubench.sh`, `setup-postgres-bench.sh` | wrappers for the two setup scripts at their old paths |

## Development

```bash
bash tests/run.sh
```

runs the Python tests for `report.py` and the metric IDs (the table in `lib/metrics.sh`, `docs/tests.md` and the old-format mapping must agree), the command line tests for `vmbench` and `run-benchmark.sh`, and a test that every file in `stages/` defines the required functions. They need no benchmark tools and no network. The test data under `tests/fixtures/` is synthetic (made-up numbers), never a real measurement.

CI (GitHub Actions) runs the same tests on x86_64 and aarch64, plus `bash -n` and ShellCheck (`-x`, warnings and errors) on every shell file including `lib/` and `stages/`, and a gitleaks secret scan of the whole history. `main` is protected: change it through a pull request.

## License

Apache License 2.0, see [LICENSE](LICENSE).
