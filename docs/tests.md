# Tests and metric IDs

Every value in `results.tsv` has a stable ID. The ID, not the text of the metric, is what identifies a test: the text can change (it carries the vCPU count or the test size), the ID does not.

This page defines the IDs. What each value means for real work, and how to read a report, is in [reading-results.md](reading-results.md) (Thai: [reading-results.th.md](reading-results.th.md)).

## Naming scheme

```text
<stage>.<tool>.<test>[.<variant>]
```

- lowercase letters, digits and `-`, parts separated by dots, the stage first (`cpu`, `mem`, `disk`, `nvme`, `pg`, `net`, `web`, `sustain`, `burnin`, and `info` for context values that are not scored)
- a last part of `1t` means one thread, `max` means all vCPUs of the machine (so an 8 vCPU and a 16 vCPU run still pair up)
- `mem.stream.*.max` and `mem.lmbench.lat-mem-rd.1t` follow the same rule: STREAM uses every vCPU, `lat_mem_rd` one process
- `.max` always means "all vCPUs", so IDs of other kinds of maximum never end in it (CPU steal and temperature use `.peak`)
- `.all-disks` is every disk of `NVME_DEVS` at once (the total), `.per-disk` is one disk at a time: one `results.tsv` row per disk, the `round` column being the disk's index, so a report shows the median over the disks and their CV
- IDs are never reused for something else. A changed test gets a new ID.

## Columns

- **Direction**: `higher` or `lower` is better. `none` is a context value that `report.py compare` shows but never calls a win. The direction is derived from the unit by `report.py` (`ns`, `us`, `ms`, `count` and `W` are lower, as is packet loss; `flag`, `RPM`, CPU steal, the fill speed and the package temperature are context; the rest are higher), and the tests check that this table agrees.
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
| `mem.stream.triad.cross-numa` | Memory bandwidth, triad kernel, CPUs of NUMA node 0 reading memory of node 1 (two or more nodes only) | STREAM | MB/s | higher | mem |
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
| `nvme.fio.randread-4k.qd32x4.all-disks` | 4 KiB random read on every NVME_DEVS disk at once, queue depth 32 x 4 jobs per disk, total | fio | IOPS | higher | nvme |
| `nvme.fio.seq-read-1m.all-disks` | 1 MiB sequential read on every NVME_DEVS disk at once, queue depth 16, total | fio | GB/s | higher | nvme |
| `nvme.fio.randwrite-4k.qd32x4.per-disk` | 4 KiB random write, queue depth 32 x 4 jobs, 10 min on one disk (one row per disk) | fio | IOPS | higher | nvme |
| `nvme.fio.randread-4k.qd1.p99.per-disk` | 4 KiB random read latency, queue depth 1, 99th percentile, one disk (one row per disk) | fio | us | lower | nvme |
| `nvme.fio.randread-4k.qd1.p999.per-disk` | 4 KiB random read latency, queue depth 1, 99.9th percentile, one disk (one row per disk) | fio | us | lower | nvme |
| `nvme.fio.randread-4k.qd32x4.per-disk` | 4 KiB random read, queue depth 32 x 4 jobs, one disk (one row per disk) | fio | IOPS | higher | nvme |
| `nvme.fio.mixed-70-30-4k.read.per-disk` | 4 KiB random 70% read / 30% write mix on one disk, read side (one row per disk) | fio | IOPS | higher | nvme |
| `nvme.fio.mixed-70-30-4k.write.per-disk` | 4 KiB random 70% read / 30% write mix on one disk, write side (one row per disk) | fio | IOPS | higher | nvme |
| `nvme.fio.seq-read-1m.per-disk` | 1 MiB sequential read, queue depth 16, one disk (one row per disk) | fio | MB/s | higher | nvme |
| `nvme.fio.seq-write-1m.per-disk` | 1 MiB sequential write, queue depth 16, one disk (one row per disk) | fio | MB/s | higher | nvme |
| `nvme.fio.randread-4k.sweep-qd1.per-disk` | 4 KiB random read at queue depth 1 x 4 jobs, one disk (queue-depth sweep, one row per disk) | fio | IOPS | higher | nvme |
| `nvme.fio.randread-4k.sweep-qd4.per-disk` | 4 KiB random read at queue depth 4 x 4 jobs, one disk (queue-depth sweep, one row per disk) | fio | IOPS | higher | nvme |
| `nvme.fio.randread-4k.sweep-qd16.per-disk` | 4 KiB random read at queue depth 16 x 4 jobs, one disk (queue-depth sweep, one row per disk) | fio | IOPS | higher | nvme |
| `nvme.fio.randread-4k.sweep-qd32.per-disk` | 4 KiB random read at queue depth 32 x 4 jobs, one disk (queue-depth sweep, one row per disk) | fio | IOPS | higher | nvme |
| `nvme.fio.randread-4k.sweep-qd64.per-disk` | 4 KiB random read at queue depth 64 x 4 jobs, one disk (queue-depth sweep, one row per disk) | fio | IOPS | higher | nvme |
| `nvme.fio.randread-4k.sweep-qd128.per-disk` | 4 KiB random read at queue depth 128 x 4 jobs, one disk (queue-depth sweep, one row per disk) | fio | IOPS | higher | nvme |
| `pg.pgbench.tpcb.tps` | TPC-B-like transactions per second with 2 x vCPU clients | pgbench | TPS | higher | pg |
| `pg.pgbench.tpcb.stability` | Steadiness of TPS over the run, 100 x (1 - coefficient of variation) | pgbench | % | higher | pg |
| `pg.pgbench.latency.single` | Average transaction latency with one client | pgbench | ms | lower | pg |
| `pg.pgbench.tpcb.tps-per-watt` | TPC-B-like TPS divided by the average system power from the BMC during that run (performance per watt) | pgbench, ipmitool | TPS/W | higher | pg |
| `net.iperf3.tcp.tx` | TCP throughput to the peer, 8 streams | iperf3 | Gbps | higher | net |
| `net.iperf3.tcp.rx` | TCP throughput from the peer, 8 streams | iperf3 | Gbps | higher | net |
| `net.iperf3.tcp.bidir` | TCP throughput, both directions added | iperf3 | Gbps | higher | net |
| `net.sockperf.pingpong.avg` | Average one-way latency (ping-pong) | sockperf | us | lower | net |
| `net.sockperf.pingpong.p99` | 99th percentile latency (ping-pong) | sockperf | us | lower | net |
| `net.iperf3.udp.pps` | UDP packets sent per second, 64-byte payload | iperf3 | Mpps | higher | net |
| `net.iperf3.udp.loss` | UDP packet loss at the maximum send rate | iperf3 | % | lower | net |
| `web.cpubench.mix.max-rps` | Highest requests per second within the latency target (loopback) | cpubench | RPS | higher | web |
| `sustain.stress-ng.all-core-mhz.max` | Average all-core clock over the last 5 minutes of a 30 minute stress-ng matrixprod load on all vCPUs | stress-ng, turbostat | MHz | higher | sustain |
| `sustain.turbostat.pkg-temp.peak` | Highest CPU package temperature during the full load (context, not scored) | turbostat | C | none | sustain |
| `sustain.turbostat.thermal-headroom` | Tjmax minus the peak package temperature under full load (TJMAX overrides the detected Tjmax) | turbostat | C | higher | sustain |
| `sustain.turbostat.pkg-watt.full` | Average CPU package power (RAPL) over the last 5 minutes of the full load | turbostat | W | lower | sustain |
| `sustain.ipmi.power.idle` | Average system power from the BMC while the machine is idle | ipmitool | W | lower | sustain |
| `sustain.ipmi.power.load-50` | Average system power from the BMC at 50% CPU load (stress-ng --cpu-load 50), last 10 of 15 minutes | ipmitool | W | lower | sustain |
| `sustain.ipmi.power.full` | Average system power from the BMC over the last 5 minutes of the full load | ipmitool | W | lower | sustain |
| `sustain.ipmi.fan.peak` | Highest fan speed reported by the BMC at the end of the full load (context, not scored) | ipmitool | RPM | none | sustain |
| `burnin.errors` | Errors found by the burn-in (memory, disk verify, kernel log) | stressapptest, fio | count | lower | burnin |
| `info.cpu.steal.avg` | Average CPU steal during the whole run (context, not scored) | mpstat | % | none | info |
| `info.cpu.steal.peak` | Highest CPU steal sample during the run (context, not scored) | mpstat | % | none | info |
| `info.fio.fill-write-1m` | Speed of the 1 MiB sequential fill before the disk tests (context, not scored) | fio | MB/s | none | info |

## Rounds

A stage that repeats writes one `results.tsv` row per value per round (the `round` column, 1 to N). `report.py` takes the median and the CV over the rounds; a value with one round is marked `*` (CV unknown), a value with two or more is not, and `!` marks a CV of 5% or more. Nothing else in the verdict logic depends on the rounds. `meta.json` has `rounds_by_stage` (for example `{"cpu": 3, "mem": 3, "disk": 1, "web": 3}`), and `report.py` shows it as "cpu 3, mem 3, ...".

| Stage | Default | Option | One round |
|---|---|---|---|
| cpu | 3 | `--rounds N`, `ROUNDS` | all cpu metrics |
| mem | 3 | `--rounds N`, `MEM_ROUNDS` | `mem.stream.triad.max`, `mem.stream.copy.max`, `mem.lmbench.lat-mem-rd.1t` (STREAM is compiled once) |
| web | 3 | `--rounds N`, `WEB_ROUNDS` | `web.cpubench.mix.max-rps` (the whole loopback test, a new label per round) |
| disk | 1 | `--disk-rounds N`, `DISK_ROUNDS` | round 1: every `disk.*` metric. Rounds 2 to N: only the ones below |
| pg | 1 | `PG_ROUNDS` | `pg.pgbench.tpcb.tps`, `pg.pgbench.tpcb.stability`, `pg.pgbench.latency.single`, `pg.pgbench.tpcb.tps-per-watt` (CHECKPOINT, warm-up, TPC-B run, CHECKPOINT, single-session run; the data load is not repeated) |
| nvme | disks | `NVME_DEVS` | not a repeat: the `nvme.*.per-disk` values have one row per disk and the round column is the disk's index (1 = the first disk of `NVME_DEVS`); `nvme-per-disk.tsv` names the device of every row |

`--rounds` and the variables take a whole number of 1 or more (exit 2 otherwise). `ROUNDS` is the default of cpu, mem and web; `MEM_ROUNDS` and `WEB_ROUNDS` override it for one stage; `--rounds` overrides all three; `QUICK=1` means one round unless rounds are given. `DISK_ROUNDS` and `PG_ROUNDS` are independent of `ROUNDS`.

**Disk rounds.** One disk round of the full sequence takes about 70 minutes and writes 8 GB, so `disk` defaults to one round and `DISK_ROUNDS=N` repeats only the tests that are cheap (about 20 minutes per extra round) and whose run-to-run noise matters for a decision, on the file that is already filled:

- `disk.fio.randread-4k.qd1.p99`, `disk.fio.randread-4k.qd1.p999` (tail latency)
- `disk.fio.randread-4k.qd32x4`
- `disk.fio.mixed-70-30-4k.read`, `disk.fio.mixed-70-30-4k.write`
- `disk.wal.fdatasync.avg`, `disk.wal.fdatasync.p99`, `disk.wal.commit-iops.qd1`

Not repeated, they run once whatever `DISK_ROUNDS` is: the fill (`info.fio.fill-write-1m`), the steady-state random write (it needs the fill and depends on the history of the device, so a second run is not a repeat of the first), the sequential tests, the queue-depth sweep and the `disk.fio.db-*` tests. Raw files of round 1 keep their old names (`fio-34-lat.json`); later rounds add `-r2`, `-r3`.

**mem.** `mem.stream.triad.cross-numa` is only written on a machine with two or more NUMA nodes (and `numactl`): the CPUs of node 0 read the memory of node 1, once per round, with the same binary and N as the other STREAM values. A VM or a one-socket machine skips it (`SKIP` in `status.tsv`).

**pg rounds.** `pgbench -i` loads the data once (1.5 × RAM, so tens of GB on a real machine). Each round then takes about 16 minutes and starts with `CHECKPOINT`, so the dirty pages of the load or of the previous round are written out before the measurement and every round sees the same starting state. `pg-checkpoints.txt` in the result folder counts the checkpoints that still happened inside each measured run (timed, or requested because `max_wal_size` was reached). Raw files of round 1 keep their names (`pgbench-tpcb.log`); later rounds add `-r2`, `-r3`.

## nvme (several raw disks)

`NVME_DEVS="nvme1n1 nvme2n1" CONFIRM_WIPE=yes vmbench run --only nvme` runs fio on the listed disks, which are **erased**. A disk with a filesystem, a mount point or partitions is refused, so the OS disk cannot be listed by mistake. The all-disk tests put one fio job per disk into one fio run (`--direct=1 --ioengine=libaio --group_reporting`) and record the total: 4 KiB random read at queue depth 32 × 4 jobs per disk, 5 minutes after a 1 minute ramp (`nvme.fio.randread-4k.qd32x4.all-disks`), and 1 MiB sequential read at queue depth 16, 3 minutes (`nvme.fio.seq-read-1m.all-disks`, GB/s). The per-disk tests then run on each disk alone, in the order of `NVME_DEVS`: 10 minutes of 4 KiB random write at queue depth 32 × 4 jobs (steady state), 4 KiB random read latency at queue depth 1 (p99, p99.9), 4 KiB random read and 70/30 mix at queue depth 32 × 4, 1 MiB sequential read and write at queue depth 16, and a queue-depth sweep (1, 4, 16, 32, 64, 128 at 4 jobs, 2 minutes each). Raw fio output is `nvme-<device>-<test>.json`, `nvme-per-disk.tsv` has every per-disk value by device, `nvme-devices.txt` the model and firmware of each disk.

## sustain (clock, temperature and power under a long load)

`vmbench run --only sustain` runs `stress-ng --cpu 0 --cpu-method matrixprod` on every CPU for `SUSTAIN_MINUTES` (30) and samples every 10 s. `sustain.stress-ng.all-core-mhz.max` is the mean clock over the last 5 minutes: `Bzy_MHz` from `turbostat --Summary` when turbostat can run as root (x86 with MSR access, so not in most VMs), else the kernel's `/proc/cpuinfo` or cpufreq view, which a VM may report as a fixed nominal value (`sustain.txt` says which). turbostat also gives the peak package temperature (`sustain.turbostat.pkg-temp.peak`, context), the thermal headroom `Tjmax − peak` (`sustain.turbostat.thermal-headroom`; Tjmax from turbostat's `MSR_IA32_TEMPERATURE_TARGET` line, or `TJMAX=<C>`) and the package power (`sustain.turbostat.pkg-watt.full`). With a BMC (`ipmitool dcmi power reading` as root), the system power is sampled while idle for 2 minutes (`sustain.ipmi.power.idle`), over the last 5 minutes of the full load (`sustain.ipmi.power.full`) and over the last 10 of `SUSTAIN_50_MINUTES` (15) minutes of `stress-ng --cpu 0 --cpu-load 50` (`sustain.ipmi.power.load-50`); the fan speeds and temperatures at the end of the full load are in `sustain-sensors.txt` and the highest fan speed in `sustain.ipmi.fan.peak`. Without a BMC the power phases are skipped. The same reading gives `pg.pgbench.tpcb.tps-per-watt` in the pg stage (TPS of the TPC-B run divided by the mean power during it).

## burnin counters

Besides fio verification failures, stressapptest not passing and new error lines in the kernel log, `burnin.errors` counts every error counter that grew during the run: EDAC correctable and uncorrectable memory errors (`/sys/devices/system/edac`), the BMC event log (`ipmitool sel list` as root) and the NVMe `media_errors` and `num_err_log_entries` of the tested disks (`nvme smart-log` as root). `burnin-checks.txt` has the counters before and after, the ones that grew, and the `ipmitool sel list`, `ras-mc-ctl --summary` and `edac-util -v` output when those tools exist. `NVME_DEVS` runs the fio verification on every listed disk at once (one job per disk); `RAW_DEV` on one disk; otherwise on a file.

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

`bash tests/run.sh` runs these groups, none of which needs a benchmark tool or the network:

- `tests/test_report.py`: `report.py`: reading folders, tables, comparisons, warnings
- `tests/test_lang.py`: the English and Thai message catalogs, `--lang`, `VMBENCH_LANG`, no Thai in English output
- `tests/test_ids.py`: the metric table (`lib/metrics.sh`), this file, the legacy mapping, the `rec` calls in `lib/` and `stages/`, and that `docs/reading-results.md` and `docs/reading-results.th.md` each name every metric ID, no ID that does not exist, and the same IDs as each other
- `tests/test_cli.sh`: `run-benchmark.sh` options, error messages, exit codes, pre-flight, `--list`, the `info` stage, `meta.json`
- `tests/test_vmbench.sh`: `vmbench` subcommands (`run`, `list`, `report`, `setup`, `version`, `help`), error messages and exit codes, wrapper equivalence, running from another directory and through symlinks
- `tests/test_detach.sh`: `vmbench run --detach` and `vmbench status`, with a fake `tmux` on PATH (no real tmux needed), and with the real one when it is installed
- `tests/test_rounds.sh`: `--rounds`, `--disk-rounds` and their variables (validation, defaults, QUICK), the times of `--list`, and the mem, web and disk stages repeating with stub tools
- `tests/test_stages.sh`: every file in `stages/` is sourced and defines the required functions; a new stage file is picked up with no other change
- `tests/test_stream.sh`: the STREAM pin: right and wrong sha256 for `STREAM_C`, a downloaded file and the cache (file:// URLs, a synthetic `stream.c`), `STREAM_SKIP_CHECK`, the mem stage with a stub
- `tests/test_hw.sh`: the bare-metal additions with stub tools (fio, stress-ng, turbostat, ipmitool, nvme, sudo): `NVME_DEVS` parsing and pre-flight refusals, the nvme stage (one row per disk, totals over the disks), the sustain stage with and without turbostat and a BMC, the burn-in counters, `hardware.txt`, and `report.py` with the new sections

CI also runs `bash -n` and `shellcheck -x -S warning` on `vmbench`, the wrappers, `lib/`, `stages/`, `setup/` and `tests/`.
