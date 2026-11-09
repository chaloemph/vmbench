# Tests and metric IDs

Every value in `results.tsv` has a stable ID. The ID, not the text of the metric, is what identifies a test: the text can change (it carries the vCPU count or the test size), the ID does not.

## Naming scheme

```text
<stage>.<tool>.<test>[.<variant>]
```

- lowercase letters, digits and `-`, parts separated by dots, the stage first (`cpu`, `mem`, `disk`, `pg`, `net`, `web`, `burnin`, and `info` for context values that are not scored)
- a last part of `1t` means one thread, `max` means all vCPUs of the machine (so an 8 vCPU and a 16 vCPU run still pair up)
- `mem.stream.*.max` and `mem.lmbench.lat-mem-rd.1t` follow the same rule: STREAM uses every vCPU, `lat_mem_rd` one process
- `.max` always means "all vCPUs", so IDs of other kinds of maximum never end in it (CPU steal uses `.peak`)
- IDs are never reused for something else. A changed test gets a new ID.

## Columns

- **Direction**: `higher` or `lower` is better. `none` is a context value that `report.py compare` shows but never calls a win. The direction is derived from the unit by `report.py` (`ns`, `us`, `ms` and `count` are lower, as is packet loss; the rest are higher), and the tests check that this table agrees.
- **Unit**: `varies` means the unit comes from cpubench for each benchmark (for example `ops/s` or `MB/s`).
- A metric is only recorded when its tool succeeded, so a result folder can hold a subset of these IDs. `status.tsv` says which steps failed or were skipped.

The table below is the same data as `vmbench run --metrics` (or `bash run-benchmark.sh --metrics`), which is the source of truth: it is defined in `lib/metrics.sh`. `tests/test_ids.py` fails when this file and that table disagree.

## Metrics

| ID | What it measures | Tool | Unit | Direction | Stage |
|---|---|---|---|---|---|
| `cpu.sysbench.prime.1t` | Prime-number counting (--cpu-max-prime=20000), 1 thread | sysbench | events/s | higher | cpu |
| `cpu.sysbench.prime.max` | Prime-number counting (--cpu-max-prime=20000), all vCPUs | sysbench | events/s | higher | cpu |
| `cpu.7z.rating.max` | 7-Zip built-in benchmark total rating, all vCPUs | 7-Zip | MIPS | higher | cpu |
| `cpu.openssl.aes-256-gcm.1t` | AES-256-GCM throughput (openssl speed -evp), 1 thread | OpenSSL | MB/s | higher | cpu |
| `cpu.openssl.aes-256-gcm.max` | AES-256-GCM throughput (openssl speed -evp), all vCPUs | OpenSSL | MB/s | higher | cpu |
| `cpu.cpubench.crypto.aes-gcm.1t` | AES-GCM (median of cpubench iterations), 1 thread | cpubench | varies | higher | cpu |
| `cpu.cpubench.crypto.aes-gcm.max` | AES-GCM (median of cpubench iterations), all vCPUs | cpubench | varies | higher | cpu |
| `cpu.cpubench.crypto.ecdsa-p256.1t` | ECDSA P-256 signing (median of cpubench iterations), 1 thread | cpubench | varies | higher | cpu |
| `cpu.cpubench.crypto.ecdsa-p256.max` | ECDSA P-256 signing (median of cpubench iterations), all vCPUs | cpubench | varies | higher | cpu |
| `cpu.cpubench.crypto.rsa2048-sign.1t` | RSA-2048 signing (median of cpubench iterations), 1 thread | cpubench | varies | higher | cpu |
| `cpu.cpubench.crypto.rsa2048-sign.max` | RSA-2048 signing (median of cpubench iterations), all vCPUs | cpubench | varies | higher | cpu |
| `cpu.cpubench.crypto.sha256.1t` | SHA-256 (median of cpubench iterations), 1 thread | cpubench | varies | higher | cpu |
| `cpu.cpubench.crypto.sha256.max` | SHA-256 (median of cpubench iterations), all vCPUs | cpubench | varies | higher | cpu |
| `cpu.cpubench.float.fft.1t` | FFT (median of cpubench iterations), 1 thread | cpubench | varies | higher | cpu |
| `cpu.cpubench.float.fft.max` | FFT (median of cpubench iterations), all vCPUs | cpubench | varies | higher | cpu |
| `cpu.cpubench.float.matmul.1t` | Matrix multiplication (median of cpubench iterations), 1 thread | cpubench | varies | higher | cpu |
| `cpu.cpubench.float.matmul.max` | Matrix multiplication (median of cpubench iterations), all vCPUs | cpubench | varies | higher | cpu |
| `cpu.cpubench.float.nbody.1t` | N-body simulation (median of cpubench iterations), 1 thread | cpubench | varies | higher | cpu |
| `cpu.cpubench.float.nbody.max` | N-body simulation (median of cpubench iterations), all vCPUs | cpubench | varies | higher | cpu |
| `cpu.cpubench.int.compress.1t` | Compression (median of cpubench iterations), 1 thread | cpubench | varies | higher | cpu |
| `cpu.cpubench.int.compress.max` | Compression (median of cpubench iterations), all vCPUs | cpubench | varies | higher | cpu |
| `cpu.cpubench.int.decompress.1t` | Decompression (median of cpubench iterations), 1 thread | cpubench | varies | higher | cpu |
| `cpu.cpubench.int.decompress.max` | Decompression (median of cpubench iterations), all vCPUs | cpubench | varies | higher | cpu |
| `cpu.cpubench.int.hashmap.1t` | Hash map operations (median of cpubench iterations), 1 thread | cpubench | varies | higher | cpu |
| `cpu.cpubench.int.hashmap.max` | Hash map operations (median of cpubench iterations), all vCPUs | cpubench | varies | higher | cpu |
| `cpu.cpubench.int.json.1t` | JSON encode/decode (median of cpubench iterations), 1 thread | cpubench | varies | higher | cpu |
| `cpu.cpubench.int.json.max` | JSON encode/decode (median of cpubench iterations), all vCPUs | cpubench | varies | higher | cpu |
| `cpu.cpubench.int.regex.1t` | Regular expressions (median of cpubench iterations), 1 thread | cpubench | varies | higher | cpu |
| `cpu.cpubench.int.regex.max` | Regular expressions (median of cpubench iterations), all vCPUs | cpubench | varies | higher | cpu |
| `cpu.cpubench.int.sort.1t` | Sorting (median of cpubench iterations), 1 thread | cpubench | varies | higher | cpu |
| `cpu.cpubench.int.sort.max` | Sorting (median of cpubench iterations), all vCPUs | cpubench | varies | higher | cpu |
| `mem.stream.triad.max` | Memory bandwidth, triad kernel, all vCPUs | STREAM | MB/s | higher | mem |
| `mem.stream.copy.max` | Memory bandwidth, copy kernel, all vCPUs | STREAM | MB/s | higher | mem |
| `mem.lmbench.lat-mem-rd.1t` | Memory load latency at the largest working set (-t, 1 process) | lmbench | ns | lower | mem |
| `disk.fio.randwrite-4k.qd32x4` | 4 KiB random write, queue depth 32 x 4 jobs, after fill to steady state | fio | IOPS | higher | disk |
| `disk.fio.randwrite-4k.steadystate` | 1 if the random-write run reached fio steady state (context, not scored) | fio | flag | none | disk |
| `disk.fio.randread-4k.qd1.p99` | 4 KiB random read latency, queue depth 1, 99th percentile | fio | us | lower | disk |
| `disk.fio.randread-4k.qd1.p999` | 4 KiB random read latency, queue depth 1, 99.9th percentile | fio | us | lower | disk |
| `disk.fio.randread-4k.qd32x4` | 4 KiB random read, queue depth 32 x 4 jobs | fio | IOPS | higher | disk |
| `disk.fio.mixed-70-30-4k.read` | 4 KiB random 70% read / 30% write mix, read side | fio | IOPS | higher | disk |
| `disk.fio.mixed-70-30-4k.write` | 4 KiB random 70% read / 30% write mix, write side | fio | IOPS | higher | disk |
| `disk.fio.seq-write-1m` | 1 MiB sequential write, queue depth 16 | fio | MB/s | higher | disk |
| `disk.fio.seq-read-1m` | 1 MiB sequential read, queue depth 16 | fio | MB/s | higher | disk |
| `disk.fio.randread-4k.sweep-qd1` | 4 KiB random read at queue depth 1 (queue-depth sweep) | fio | IOPS | higher | disk |
| `disk.fio.randread-4k.sweep-qd4` | 4 KiB random read at queue depth 4 (queue-depth sweep) | fio | IOPS | higher | disk |
| `disk.fio.randread-4k.sweep-qd16` | 4 KiB random read at queue depth 16 (queue-depth sweep) | fio | IOPS | higher | disk |
| `disk.fio.randread-4k.sweep-qd32` | 4 KiB random read at queue depth 32 (queue-depth sweep) | fio | IOPS | higher | disk |
| `disk.fio.randread-4k.sweep-qd64` | 4 KiB random read at queue depth 64 (queue-depth sweep) | fio | IOPS | higher | disk |
| `disk.fio.randread-4k.sweep-qd128` | 4 KiB random read at queue depth 128 (queue-depth sweep) | fio | IOPS | higher | disk |
| `disk.fio.db-randwrite-8k` | 8 KiB random write on files in DB_DIR (database data pattern) | fio | IOPS | higher | disk |
| `disk.fio.db-randrw-8k.read` | 8 KiB random 70/30 mix on DB_DIR, read side | fio | IOPS | higher | disk |
| `disk.fio.db-randrw-8k.write` | 8 KiB random 70/30 mix on DB_DIR, write side | fio | IOPS | higher | disk |
| `disk.fio.db-seqwrite-1m` | 1 MiB sequential write on files in DB_DIR | fio | MB/s | higher | disk |
| `disk.fio.db-randread-8k` | 8 KiB random read on files in DB_DIR | fio | IOPS | higher | disk |
| `disk.wal.fdatasync.avg` | WAL-style 8 KiB write + fdatasync, queue depth 1, mean latency | fio | ms | lower | disk |
| `disk.wal.fdatasync.p99` | WAL-style 8 KiB write + fdatasync, 99th percentile latency | fio | ms | lower | disk |
| `disk.wal.commit-iops.qd1` | WAL-style commits per second at queue depth 1 | fio | IOPS | higher | disk |
| `pg.pgbench.tpcb.tps` | TPC-B-like transactions per second with 2 x vCPU clients | pgbench | TPS | higher | pg |
| `pg.pgbench.tpcb.stability` | Steadiness of TPS over the run, 100 x (1 - coefficient of variation) | pgbench | % | higher | pg |
| `pg.pgbench.latency.single` | Average transaction latency with one client | pgbench | ms | lower | pg |
| `net.iperf3.tcp.tx` | TCP throughput to the peer, 8 streams | iperf3 | Gbps | higher | net |
| `net.iperf3.tcp.rx` | TCP throughput from the peer, 8 streams | iperf3 | Gbps | higher | net |
| `net.iperf3.tcp.bidir` | TCP throughput, both directions added | iperf3 | Gbps | higher | net |
| `net.sockperf.pingpong.avg` | Average one-way latency (ping-pong) | sockperf | us | lower | net |
| `net.sockperf.pingpong.p99` | 99th percentile latency (ping-pong) | sockperf | us | lower | net |
| `net.iperf3.udp.pps` | UDP packets sent per second, 64-byte payload | iperf3 | Mpps | higher | net |
| `net.iperf3.udp.loss` | UDP packet loss at the maximum send rate | iperf3 | % | lower | net |
| `web.cpubench.mix.max-rps` | Highest requests per second within the latency target (loopback) | cpubench | RPS | higher | web |
| `burnin.errors` | Errors found by the burn-in (memory, disk verify, kernel log) | stressapptest, fio | count | lower | burnin |
| `info.cpu.steal.avg` | Average CPU steal during the whole run (context, not scored) | mpstat | % | none | info |
| `info.cpu.steal.peak` | Highest CPU steal sample during the run (context, not scored) | mpstat | % | none | info |
| `info.fio.fill-write-1m` | Speed of the 1 MiB sequential fill before the disk tests (context, not scored) | fio | MB/s | none | info |

## STREAM source

`mem.stream.*` is measured with a pinned copy of the official `stream.c` (jeffhammond/STREAM), defined in `lib/stream.sh`:

- commit `6703f7504a38a8da96b353cadafa64d3c2d7a2d3`
- sha256 `c388924eb140fda95f534cdb808ae7f1f8ebb18da41d8aec1b512a3c8d303c9b`
- `https://raw.githubusercontent.com/jeffhammond/STREAM/6703f7504a38a8da96b353cadafa64d3c2d7a2d3/stream.c`

The stage compiles the file only when its sha256 matches (`STREAM_C` for an offline copy is checked too; `STREAM_SKIP_CHECK=1` turns the check off and the run records `UNVERIFIED` in `info.txt`). Results measured with another STREAM source are not comparable, so a change of the pin is a change of the test: treat it like a new ID if the numbers move.

## Report language

`report.py` writes English by default; `--lang th` or `VMBENCH_LANG=th` selects Thai. The text lives in the `MESSAGES` catalog in `report.py` (one dict per language, same keys and same `{placeholders}`; `tests/test_lang.py` checks both and that no Thai appears in English output). Metric names, IDs and units are not translated. To add a sentence, add the key to both dicts and use `t("key", name=value)`.

## Old result folders

Result folders written before the IDs existed have a `results.tsv` with the header `row`, `metric`, `value`, `unit`, `round`, where `row` is a number from the original spreadsheet test plan. `report.py` still reads them and maps each row to the ID above through the `LEGACY` table in `report.py`. Rows it does not know are shown under `<stage>.row<N>.<text>`.

## Adding a stage or a metric

- **A metric**: add one line to the table in `lib/metrics.sh`, one row here (same order), and the `rec` call in the stage file. `tests/test_ids.py` checks all three agree, and that `report.py` has a legacy mapping for it.
- **A stage**: add one file, `stages/<name>.sh`. Nothing else has to change: `vmbench` finds it, lists it in `--list` and `--help`, pre-flight checks it and runs it. The file defines these functions, documented in `lib/stages.sh`:

  - `stage_<name>_order`: a number that sorts the stages (`info` is 0, the others 10, 20, ...)
  - `stage_<name>_default`: `yes` (runs without `--with`), `no` (only when asked) or `always`
  - `stage_<name>_time`: typical duration shown by `--list`
  - `stage_<name>_note`: what the stage needs, shown in `--help` (may print nothing)
  - `stage_<name>_check`: add to `PROBLEMS` for everything that stops the stage (pre-flight)
  - `stage_<name>_run`: run it; `rec` for values, `ok`, `bad` and `skip` for steps

## What the tests cover

`bash tests/run.sh` runs six groups, none of which needs a benchmark tool or the network:

- `tests/test_report.py`: `report.py`: reading folders, tables, comparisons, warnings
- `tests/test_lang.py`: the English and Thai message catalogs, `--lang`, `VMBENCH_LANG`, no Thai in English output
- `tests/test_ids.py`: the metric table (`lib/metrics.sh`), this file, the legacy mapping, the `rec` calls in `lib/` and `stages/`
- `tests/test_cli.sh`: `run-benchmark.sh` options, error messages, exit codes, pre-flight, `--list`, the `info` stage, `meta.json`
- `tests/test_vmbench.sh`: `vmbench` subcommands (`run`, `list`, `report`, `setup`, `version`, `help`), error messages and exit codes, wrapper equivalence, running from another directory and through symlinks
- `tests/test_stages.sh`: every file in `stages/` is sourced and defines the required functions; a new stage file is picked up with no other change
- `tests/test_stream.sh`: the STREAM pin: right and wrong sha256 for `STREAM_C`, a downloaded file and the cache (file:// URLs, a synthetic `stream.c`), `STREAM_SKIP_CHECK`, the mem stage with a stub

CI also runs `bash -n` and `shellcheck -x -S warning` on `vmbench`, the wrappers, `lib/`, `stages/`, `setup/` and `tests/`.
