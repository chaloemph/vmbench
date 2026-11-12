# Reading the results

**English** · [ภาษาไทย](reading-results.th.md)

This guide explains, for every value vmbench records, what it measures, which direction is better, and what it means for real work on the machine: why the value is worth measuring at all.

It does not give pass/fail thresholds. Whether a number is "enough" depends on your workload, so vmbench is built to **compare** machines (or the same machine before and after a change) run with the same version and settings. The exact definition of each ID (tool, unit, direction) is in [tests.md](tests.md); this page is about interpretation.

- [How to read a report](#how-to-read-a-report)
- [Ideas that apply to every stage](#ideas-that-apply-to-every-stage)
- [cpu](#cpu) · [mem](#mem) · [disk](#disk) · [pg](#pg) · [net](#net) · [web](#web) · [burnin](#burnin) · [info (context)](#info-context)
- [Which values matter for which workload](#which-values-matter-for-which-workload)

## How to read a report

Each row of a report shows one metric ID with its unit, value, number of rounds and CV.

| Column or mark | Meaning |
|---|---|
| Value | The **median** of the rounds. The median ignores one unusually slow or fast round. |
| Rounds | How many times the test ran. With 1 round the run-to-run variation is unknown. |
| CV | Coefficient of variation: the standard deviation as a percentage of the mean. A small CV means the machine gave the same answer every time. |
| `*` | Measured once. Treat a single value as a hint, not a fact. |
| `!` | CV of 5% or more. The machine was not steady during this test (noisy neighbours, throttling, background work). Find out why before comparing. |

In a comparison (`vmbench report compare A B`), the first folder is the baseline and every other folder is judged against it:

- **better / worse**: the difference is larger than the noise of both runs.
- **not clearly different**: the difference is within the larger CV of the two runs, or within 1%. Do not report this as a win for either side.
- Context values (direction `none`, such as CPU steal) are shown but never judged.

Always read the warnings at the top of a report first. Different vmbench or cpubench versions, `QUICK=1`, different test sizes or vCPU counts, high CPU steal and failed steps can each make a comparison meaningless.

## Ideas that apply to every stage

**Throughput and latency are different questions.** Throughput (IOPS, MB/s, TPS, RPS, Gbps) is how much work the machine finishes per second when it is kept busy. Latency (us, ms, ns) is how long one piece of work takes. A machine can have high throughput and poor latency at the same time, and users usually feel latency.

**Percentiles describe the slow requests.** p99 is the value that 99% of operations beat; p99.9 is the value that 99.9% beat. If a web page needs 50 disk reads, a 1-in-100 slow read hits a large share of page views, so p99 and p99.9 often matter more than the average.

**`1t` and `max` answer different questions.** `1t` (one thread) shows how fast a single task runs, which bounds the response time of anything that cannot be split, such as one database query or one request. `max` (all vCPUs) shows the total capacity when many tasks run at once. The ratio `max / 1t` shows how well the machine scales across its vCPUs: well below the vCPU count can point to shared physical cores, thermal or power limits, or memory bandwidth limits.

**Higher is better unless the unit is a time or a count of bad events.** `ns`, `us`, `ms`, `count` and packet loss are lower-is-better; everything else is higher-is-better. The report already applies this.

**A VM shows the hypervisor as much as the hardware.** Disk results include the host's cache and storage settings, CPU results depend on the CPU model exposed to the guest, and other VMs on the same host take time away from yours (CPU steal). A large gap between two VMs can come from configuration rather than from the hardware.

## cpu

Measures how fast the vCPUs run different kinds of code. CPU speed affects almost everything: request handling, compression, encryption, query execution, builds.

| ID | Better | What it means in practice |
|---|---|---|
| `cpu.sysbench.prime.1t`, `cpu.sysbench.prime.max` | higher | A simple integer loop. Good for a quick check between machines of the **same architecture** only: the score depends on the compiler and instruction set, so do not use it to compare x86 with ARM. |
| `cpu.7z.rating.max` | higher | 7-Zip's built-in compression and decompression benchmark. Represents general integer work with branches and memory access: compression, archiving, many server workloads. |
| `cpu.openssl.aes-256-gcm.1t`, `cpu.openssl.aes-256-gcm.max` | higher | Encryption speed with hardware AES. Matters for TLS (HTTPS), VPNs, encrypted disks and encrypted backups. A very low value can mean the guest does not see the CPU's AES instructions (check the CPU type the hypervisor exposes). |

The cpubench tests split CPU work into categories. Each one is recorded for one thread and for all vCPUs, so each name below stands for two IDs, for example `cpu.cpubench.int.json.1t` and `cpu.cpubench.int.json.max`. The unit comes from cpubench and differs per test; within one test, higher is always better.

| cpubench test | What it represents in real work |
|---|---|
| `cpu.cpubench.int.compress.{1t,max}`, `cpu.cpubench.int.decompress.{1t,max}` | Compression in web servers (gzip), log handling, backups, container image layers. |
| `cpu.cpubench.int.hashmap.{1t,max}` | Lookups in in-memory tables: caches, interpreters, application servers. Sensitive to cache and memory latency. |
| `cpu.cpubench.int.json.{1t,max}` | Encoding and decoding JSON: almost every web API and microservice. |
| `cpu.cpubench.int.regex.{1t,max}` | Pattern matching: log parsing, input validation, routing, search. |
| `cpu.cpubench.int.sort.{1t,max}` | Sorting: databases (ORDER BY, index builds), data processing. |
| `cpu.cpubench.float.fft.{1t,max}` | Signal processing, audio and image work. |
| `cpu.cpubench.float.matmul.{1t,max}` | Matrix math: numerical computing, simple machine-learning inference. Benefits from vector instructions. |
| `cpu.cpubench.float.nbody.{1t,max}` | Scientific simulation with floating point. |
| `cpu.cpubench.crypto.aes-gcm.{1t,max}` | Bulk encryption (TLS data, disk encryption). |
| `cpu.cpubench.crypto.sha256.{1t,max}` | Hashing: checksums, content addressing, signatures, deduplication. |
| `cpu.cpubench.crypto.ecdsa-p256.{1t,max}`, `cpu.cpubench.crypto.rsa2048-sign.{1t,max}` | Public-key operations: TLS handshakes and token signing. Matters for servers that accept many new HTTPS connections. |

How to read the cpu group:

- Look at the categories that match your workload rather than one overall number. Two CPUs can win in different categories.
- For latency-sensitive services, the `1t` values matter most. For batch jobs and many parallel users, the `max` values do.
- A high CV here usually means another VM was using the same physical cores: check CPU steal in the same run.

## mem

Measures how fast the vCPUs can move data to and from RAM, and how long one memory access takes. Programs whose data does not fit in the CPU caches (databases, caches, analytics, large application heaps) are often limited by memory rather than by the CPU.

| ID | Better | What it means in practice |
|---|---|---|
| `mem.stream.triad.max` | higher | Memory bandwidth with all vCPUs, doing a read-read-write pattern (`a = b + s * c`). The usual single number for "how much data per second can this machine stream through RAM". Matters for scans, analytics, compression of large data and in-memory databases. |
| `mem.stream.copy.max` | higher | Memory bandwidth for plain copying. Close to the cost of moving buffers around (network and storage stacks, large memory copies). |
| `mem.lmbench.lat-mem-rd.1t` | lower | Time for one memory load when the data is not in the CPU cache (largest working set, one process). Matters for workloads that follow pointers: hash tables, B-trees, linked structures, interpreters. Lower latency makes each such step faster even when bandwidth is not used up. |

How to read the mem group:

- Bandwidth divided by the vCPU count gives a rough per-vCPU share. When it is low, adding vCPUs will not speed up memory-heavy work much.
- A latency much higher than on a comparable machine can come from memory spread across NUMA nodes or from the host being under memory pressure.
- Compare bandwidth only between runs with the same vCPU count: STREAM uses every vCPU.

## disk

Measures the storage the VM writes to. Disk behaviour decides how fast databases commit, how quickly an application starts, and how long backups and restores take. In a VM these numbers include the hypervisor's caching and the storage backend, which is why they can be far above or below what the physical disk alone would give.

The random and sequential tests use direct I/O (they bypass the guest's page cache) on a test file of `FIO_SIZE` (8 GB by default), or on a raw device when `RAW_DEV` is set. The WAL tests are different on purpose: like a database's write-ahead log, they write normally to a file in `WAL_DIR` and then call `fdatasync` to force the data to stable storage.

**Random 4 KiB, many requests at once** (capacity under concurrent load):

| ID | Better | What it means in practice |
|---|---|---|
| `disk.fio.randread-4k.qd32x4` | higher | Random reads with 128 requests outstanding. The read capacity available to many concurrent users or a busy database. |
| `disk.fio.randwrite-4k.qd32x4` | higher | Random writes at the same concurrency, measured after the file has been filled so the storage is in its steady state rather than its fresh, faster state. |
| `disk.fio.mixed-70-30-4k.read`, `disk.fio.mixed-70-30-4k.write` | higher | A 70% read / 30% write mix: closer to a real application than pure reads or writes. Read the two values together. |

**Random reads, one request at a time** (what a single user waits for):

| ID | Better | What it means in practice |
|---|---|---|
| `disk.fio.randread-4k.qd1.p99` | lower | 99% of single reads finish faster than this. A request that needs one uncached disk read waits at least this long in the slow cases. |
| `disk.fio.randread-4k.qd1.p999` | lower | The slowest 0.1% of reads. Large values here show up as occasional slow pages or query timeouts even when averages look fine. |

**Queue-depth sweep** (how the storage scales with concurrency): `disk.fio.randread-4k.sweep-qd{1,4,16,32,64,128}`, higher is better.

- Read the six values as a curve, not one by one. IOPS should rise as the queue depth grows, then level off. The point where it levels off is the concurrency the storage can use.
- `qd1` IOPS is roughly `1 / latency`: it shows the speed of one request in a row.
- If IOPS stops growing at a small queue depth, more parallel workers will not get more disk throughput; they will only wait longer.

**Sequential 1 MiB** (big transfers):

| ID | Better | What it means in practice |
|---|---|---|
| `disk.fio.seq-read-1m` | higher | Reading large files: restores, scans of big tables, loading data sets, copying images. |
| `disk.fio.seq-write-1m` | higher | Writing large files: backups, bulk imports, log shipping, building images. |

**Database-shaped tests** in `DB_DIR` (8 KiB is the PostgreSQL page size, so these follow its I/O pattern):

| ID | Better | What it means in practice |
|---|---|---|
| `disk.fio.db-randread-8k` | higher | Random page reads that miss PostgreSQL's cache. |
| `disk.fio.db-randwrite-8k` | higher | Random page writes, as during checkpoints and background writing. |
| `disk.fio.db-randrw-8k.read`, `disk.fio.db-randrw-8k.write` | higher | A mixed OLTP-like page pattern. |
| `disk.fio.db-seqwrite-1m` | higher | Large sequential writes, as during bulk loads or index builds. |

**WAL tests** (commit speed): each operation writes 8 KiB and then waits until the storage confirms the data is durable (`fdatasync`), one at a time. This is what a database does on every commit with `synchronous_commit = on`.

| ID | Better | What it means in practice |
|---|---|---|
| `disk.wal.fdatasync.avg` | lower | Average time to make one commit durable. A single client cannot commit faster than this. |
| `disk.wal.fdatasync.p99` | lower | Slow commits. Shows up as latency spikes in write-heavy applications. |
| `disk.wal.commit-iops.qd1` | higher | Durable commits per second from one writer. Roughly an upper bound on single-connection write transactions per second. |

For any system that must not lose acknowledged writes (databases, queues, file servers), the WAL values are among the most important numbers vmbench records. A disk can have high IOPS and still be slow here.

How to read the disk group:

- A large gap between two VMs is often the hypervisor's cache mode or storage backend rather than the disk itself. Write caching in the host makes `fdatasync` look fast but can lose data if the host fails. Ask how the disk is configured before drawing a conclusion.
- `disk.fio.randwrite-4k.steadystate` is a flag, not a score: 1 means fio detected that random-write performance had settled. With 0, the random-write value may still have been changing.
- Disk values are measured once by default. Use `--disk-rounds N` before making a decision based on a small difference.

## pg

Runs PostgreSQL's own benchmark (pgbench, a TPC-B-like workload of small read-write transactions) on a dedicated cluster. It combines CPU, memory and especially commit latency into numbers that are close to a real OLTP application.

| ID | Better | What it means in practice |
|---|---|---|
| `pg.pgbench.tpcb.tps` | higher | Transactions per second with 2 × vCPU clients. The write-heavy capacity of the machine as a database server. |
| `pg.pgbench.tpcb.stability` | higher | How steady TPS stayed over 10 minutes: 100 means perfectly flat. Low values mean periodic stalls, typically from checkpoints or from the storage pausing, which users notice as slow periods. |
| `pg.pgbench.latency.single` | lower | Average transaction time with one client. Shows the cost of one transaction on its own, mostly CPU speed plus commit latency. Matters for applications that run their database work one step at a time. |

How to read the pg group:

- TPS is limited by whichever resource runs out first: often commit latency (compare with the WAL values in the disk group), sometimes CPU.
- Stability matters as much as TPS. A machine with slightly lower TPS but higher stability gives a more predictable service.
- These results depend on the data size (`PG_SCALE`) and on PostgreSQL settings. Only compare runs with the same scale and the same settings (`pg-settings.txt` in the result folder lists them).

## net

Measures the network path between this VM and a peer machine. It matters for anything that talks to other machines: databases on another host, replication, storage over the network, clients.

| ID | Better | What it means in practice |
|---|---|---|
| `net.iperf3.tcp.tx`, `net.iperf3.tcp.rx` | higher | TCP throughput in each direction with 8 streams. The test sends in both directions **at the same time**, so the two values share the link; neither is the maximum of one direction alone. |
| `net.iperf3.tcp.bidir` | higher | Both directions added: the closest of the three to the total capacity of the path. Matters for backups, replication and large transfers. |
| `net.sockperf.pingpong.avg` | lower | Average one-way latency for small messages. Every request to a database or service on another machine pays this at least twice (there and back). |
| `net.sockperf.pingpong.p99` | lower | Slow messages. Shows up as occasional slow requests between services. |
| `net.iperf3.udp.pps` | higher | Small (64-byte) UDP packets **sent** per second, as fast as possible. Shows how many small packets the VM's network stack can push: relevant to DNS, VoIP, games and other packet-rate-bound traffic. |
| `net.iperf3.udp.loss` | lower | Packet loss at that unlimited send rate. Because the sender is not throttled, some loss is expected and does not by itself mean the network is faulty. Use it to compare machines tested the same way. |

How to read the net group:

- The result describes the **path** to the chosen peer, including the peer itself. Compare machines only against the same peer.
- For chatty applications (many small requests), latency matters more than throughput.

## web

Runs a small HTTP server and a load generator from cpubench on the same machine (loopback), and increases the request rate step by step until latency stops meeting cpubench's target.

| ID | Better | What it means in practice |
|---|---|---|
| `web.cpubench.mix.max-rps` | higher | The highest request rate the machine handled before latency started to rise sharply (the "knee"). A practical measure of how much web or API traffic the CPU can serve while staying responsive. |

How to read the web group:

- Both the server and the load generator run on the same VM, so this measures the CPU's capacity for HTTP work, not the network.
- The rate rises in fixed steps, so values are rounded to a step and the CV is often 0%. A CV of 0% here does not prove the machine is perfectly steady.
- Because the load generator shares the vCPUs with the server, it can run out of CPU first. The run log reminds you to check this in the cpubench CPU logs saved in the result folder; if the load generator was the limit, the value is a lower bound for the server.

## burnin

Runs a long stress test (default 48 hours) on memory and disk to find hardware or configuration faults, not to measure speed.

| ID | Better | What it means in practice |
|---|---|---|
| `burnin.errors` | lower (0) | The number of problems found: stressapptest not passing, fio data verification failures, and new error lines in the kernel log. Anything other than 0 means the machine is not safe to trust with data until the cause is found. |

The details of each error are in `burnin.err`, `stressapptest.log` and `dmesg-errors.txt` in the result folder.

## info (context)

These values are recorded so the others can be interpreted. They are shown in reports but never judged.

| ID | What it tells you |
|---|---|
| `info.cpu.steal.avg`, `info.cpu.steal.peak` | Percentage of time the VM wanted to run but the host gave the CPU to someone else. When steal is high, every result in the run is lower than the machine can really do, and comparisons with a quieter run are unfair. Re-run at a quieter time, or ask for dedicated CPUs. |
| `info.fio.fill-write-1m` | Speed of writing the test file before the disk tests. A sanity check: if it is far from `disk.fio.seq-write-1m`, the storage behaved differently while the file was being created (for example while space was being allocated). |

## Which values matter for which workload

A starting point for choosing what to look at first. Every workload also depends on the values not listed.

| Workload | Look at first |
|---|---|
| Web or API servers | `web.cpubench.mix.max-rps`, the `1t` values of `cpu.cpubench.int.json`, `cpu.cpubench.int.regex` and `cpu.cpubench.int.compress`, the TLS-related crypto values, and net latency if the backend is on another machine |
| OLTP databases (PostgreSQL, MySQL) | the `disk.wal.*` values, `pg.pgbench.tpcb.tps` and `pg.pgbench.tpcb.stability`, `disk.fio.randread-4k.qd1.p99`, the `disk.fio.db-*` values, `mem.lmbench.lat-mem-rd.1t` |
| Analytics and batch processing | `mem.stream.triad.max`, the `max` cpu values, `disk.fio.seq-read-1m` |
| Caches and in-memory stores | `mem.lmbench.lat-mem-rd.1t`, `cpu.cpubench.int.hashmap.*`, net latency |
| File, backup and storage servers | `disk.fio.seq-read-1m`, `disk.fio.seq-write-1m`, `net.iperf3.tcp.bidir`, `disk.wal.fdatasync.avg` if clients wait for durable writes |
| Any machine that will hold important data | `burnin.errors` = 0 |
