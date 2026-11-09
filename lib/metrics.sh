#!/usr/bin/env bash
# lib/metrics.sh - the metric table (the one place where result ids are defined) and rec, which writes a result.
# Sourced, never executed.
#
#   metric_table                      print the table, one line per id (this is what --metrics shows)
#   rec ID VALUE [X [UNIT]]           append one value to $RES (needs RES, ROUND, NPROC from `vmbench run`)
#   M_UNIT[id] M_LABEL[id]            unit and label template of every id, filled from the table
#
# Adding a metric: add one line to the table here and one line to docs/tests.md (tests/test_ids.py checks both).

# ---------------------------------------------------------------- metric ids
# The one place where result ids are defined. Columns: id|unit|direction|tool|label|what it measures
#   id         <stage>.<tool>.<test>[.<variant>], lowercase, dots between parts; a .1t or .max suffix means one thread or all vCPUs
#   direction  higher or lower is better; none = context value that is never judged
#   label      the text written to the metric column of results.tsv: {t} is the thread count, {x} a per-run value (see rec)
# docs/tests.md repeats this table, and tests/test_ids.py fails if the two differ.
metric_table() {
  cat <<'METRICS'
cpu.sysbench.prime.1t|events/s|higher|sysbench|sysbench cpu {t}t|Prime-number counting (--cpu-max-prime=20000), 1 thread
cpu.sysbench.prime.max|events/s|higher|sysbench|sysbench cpu {t}t|Prime-number counting (--cpu-max-prime=20000), all vCPUs
cpu.7z.rating.max|MIPS|higher|7-Zip|7z rating {t}t|7-Zip built-in benchmark total rating, all vCPUs
cpu.openssl.aes-256-gcm.1t|MB/s|higher|OpenSSL|openssl aes-256-gcm {t}t|AES-256-GCM throughput (openssl speed -evp), 1 thread
cpu.openssl.aes-256-gcm.max|MB/s|higher|OpenSSL|openssl aes-256-gcm {t}t|AES-256-GCM throughput (openssl speed -evp), all vCPUs
cpu.cpubench.crypto.aes-gcm.1t|varies|higher|cpubench|cpubench crypto/aes-gcm {t}t|AES-GCM (median of cpubench iterations), 1 thread
cpu.cpubench.crypto.aes-gcm.max|varies|higher|cpubench|cpubench crypto/aes-gcm {t}t|AES-GCM (median of cpubench iterations), all vCPUs
cpu.cpubench.crypto.ecdsa-p256.1t|varies|higher|cpubench|cpubench crypto/ecdsa-p256 {t}t|ECDSA P-256 signing (median of cpubench iterations), 1 thread
cpu.cpubench.crypto.ecdsa-p256.max|varies|higher|cpubench|cpubench crypto/ecdsa-p256 {t}t|ECDSA P-256 signing (median of cpubench iterations), all vCPUs
cpu.cpubench.crypto.rsa2048-sign.1t|varies|higher|cpubench|cpubench crypto/rsa2048-sign {t}t|RSA-2048 signing (median of cpubench iterations), 1 thread
cpu.cpubench.crypto.rsa2048-sign.max|varies|higher|cpubench|cpubench crypto/rsa2048-sign {t}t|RSA-2048 signing (median of cpubench iterations), all vCPUs
cpu.cpubench.crypto.sha256.1t|varies|higher|cpubench|cpubench crypto/sha256 {t}t|SHA-256 (median of cpubench iterations), 1 thread
cpu.cpubench.crypto.sha256.max|varies|higher|cpubench|cpubench crypto/sha256 {t}t|SHA-256 (median of cpubench iterations), all vCPUs
cpu.cpubench.float.fft.1t|varies|higher|cpubench|cpubench float/fft {t}t|FFT (median of cpubench iterations), 1 thread
cpu.cpubench.float.fft.max|varies|higher|cpubench|cpubench float/fft {t}t|FFT (median of cpubench iterations), all vCPUs
cpu.cpubench.float.matmul.1t|varies|higher|cpubench|cpubench float/matmul {t}t|Matrix multiplication (median of cpubench iterations), 1 thread
cpu.cpubench.float.matmul.max|varies|higher|cpubench|cpubench float/matmul {t}t|Matrix multiplication (median of cpubench iterations), all vCPUs
cpu.cpubench.float.nbody.1t|varies|higher|cpubench|cpubench float/nbody {t}t|N-body simulation (median of cpubench iterations), 1 thread
cpu.cpubench.float.nbody.max|varies|higher|cpubench|cpubench float/nbody {t}t|N-body simulation (median of cpubench iterations), all vCPUs
cpu.cpubench.int.compress.1t|varies|higher|cpubench|cpubench int/compress {t}t|Compression (median of cpubench iterations), 1 thread
cpu.cpubench.int.compress.max|varies|higher|cpubench|cpubench int/compress {t}t|Compression (median of cpubench iterations), all vCPUs
cpu.cpubench.int.decompress.1t|varies|higher|cpubench|cpubench int/decompress {t}t|Decompression (median of cpubench iterations), 1 thread
cpu.cpubench.int.decompress.max|varies|higher|cpubench|cpubench int/decompress {t}t|Decompression (median of cpubench iterations), all vCPUs
cpu.cpubench.int.hashmap.1t|varies|higher|cpubench|cpubench int/hashmap {t}t|Hash map operations (median of cpubench iterations), 1 thread
cpu.cpubench.int.hashmap.max|varies|higher|cpubench|cpubench int/hashmap {t}t|Hash map operations (median of cpubench iterations), all vCPUs
cpu.cpubench.int.json.1t|varies|higher|cpubench|cpubench int/json {t}t|JSON encode/decode (median of cpubench iterations), 1 thread
cpu.cpubench.int.json.max|varies|higher|cpubench|cpubench int/json {t}t|JSON encode/decode (median of cpubench iterations), all vCPUs
cpu.cpubench.int.regex.1t|varies|higher|cpubench|cpubench int/regex {t}t|Regular expressions (median of cpubench iterations), 1 thread
cpu.cpubench.int.regex.max|varies|higher|cpubench|cpubench int/regex {t}t|Regular expressions (median of cpubench iterations), all vCPUs
cpu.cpubench.int.sort.1t|varies|higher|cpubench|cpubench int/sort {t}t|Sorting (median of cpubench iterations), 1 thread
cpu.cpubench.int.sort.max|varies|higher|cpubench|cpubench int/sort {t}t|Sorting (median of cpubench iterations), all vCPUs
mem.stream.triad.max|MB/s|higher|STREAM|stream triad (N={x})|Memory bandwidth, triad kernel, all vCPUs
mem.stream.copy.max|MB/s|higher|STREAM|stream copy (N={x})|Memory bandwidth, copy kernel, all vCPUs
mem.lmbench.lat-mem-rd.1t|ns|lower|lmbench|lat_mem_rd -t {x}MB|Memory load latency at the largest working set (-t, 1 process)
disk.fio.randwrite-4k.qd32x4|IOPS|higher|fio|fio randwrite 4k qd32x4|4 KiB random write, queue depth 32 x 4 jobs, after fill to steady state
disk.fio.randwrite-4k.steadystate|flag|none|fio|steadystate attained (1=yes)|1 if the random-write run reached fio steady state (context, not scored)
disk.fio.randread-4k.qd1.p99|us|lower|fio|fio randread 4k qd1 p99|4 KiB random read latency, queue depth 1, 99th percentile
disk.fio.randread-4k.qd1.p999|us|lower|fio|fio randread 4k qd1 p99.9|4 KiB random read latency, queue depth 1, 99.9th percentile
disk.fio.randread-4k.qd32x4|IOPS|higher|fio|fio randread 4k qd32x4|4 KiB random read, queue depth 32 x 4 jobs
disk.fio.mixed-70-30-4k.read|IOPS|higher|fio|fio mixed 70/30 read|4 KiB random 70% read / 30% write mix, read side
disk.fio.mixed-70-30-4k.write|IOPS|higher|fio|fio mixed 70/30 write|4 KiB random 70% read / 30% write mix, write side
disk.fio.seq-write-1m|MB/s|higher|fio|fio seq write 1M|1 MiB sequential write, queue depth 16
disk.fio.seq-read-1m|MB/s|higher|fio|fio seq read 1M|1 MiB sequential read, queue depth 16
disk.fio.randread-4k.sweep-qd1|IOPS|higher|fio|fio randread 4k qd1|4 KiB random read at queue depth 1 (queue-depth sweep)
disk.fio.randread-4k.sweep-qd4|IOPS|higher|fio|fio randread 4k qd4|4 KiB random read at queue depth 4 (queue-depth sweep)
disk.fio.randread-4k.sweep-qd16|IOPS|higher|fio|fio randread 4k qd16|4 KiB random read at queue depth 16 (queue-depth sweep)
disk.fio.randread-4k.sweep-qd32|IOPS|higher|fio|fio randread 4k qd32|4 KiB random read at queue depth 32 (queue-depth sweep)
disk.fio.randread-4k.sweep-qd64|IOPS|higher|fio|fio randread 4k qd64|4 KiB random read at queue depth 64 (queue-depth sweep)
disk.fio.randread-4k.sweep-qd128|IOPS|higher|fio|fio randread 4k qd128|4 KiB random read at queue depth 128 (queue-depth sweep)
disk.fio.db-randwrite-8k|IOPS|higher|fio|fio randwrite 8k|8 KiB random write on files in DB_DIR (database data pattern)
disk.fio.db-randrw-8k.read|IOPS|higher|fio|fio randrw 70/30 8k read|8 KiB random 70/30 mix on DB_DIR, read side
disk.fio.db-randrw-8k.write|IOPS|higher|fio|fio randrw 70/30 8k write|8 KiB random 70/30 mix on DB_DIR, write side
disk.fio.db-seqwrite-1m|MB/s|higher|fio|fio seqwrite 1M|1 MiB sequential write on files in DB_DIR
disk.fio.db-randread-8k|IOPS|higher|fio|fio randread 8k|8 KiB random read on files in DB_DIR
disk.wal.fdatasync.avg|ms|lower|fio|wal fdatasync avg|WAL-style 8 KiB write + fdatasync, queue depth 1, mean latency
disk.wal.fdatasync.p99|ms|lower|fio|wal fdatasync p99|WAL-style 8 KiB write + fdatasync, 99th percentile latency
disk.wal.commit-iops.qd1|IOPS|higher|fio|wal commit iops qd1|WAL-style commits per second at queue depth 1
pg.pgbench.tpcb.tps|TPS|higher|pgbench|pgbench tpcb-like tps (-c {x})|TPC-B-like transactions per second with 2 x vCPU clients
pg.pgbench.tpcb.stability|%|higher|pgbench|tps stability 100*(1-cv)|Steadiness of TPS over the run, 100 x (1 - coefficient of variation)
pg.pgbench.latency.single|ms|lower|pgbench|pgbench single-session latency|Average transaction latency with one client
net.iperf3.tcp.tx|Gbps|higher|iperf3|iperf3 tcp tx->peer|TCP throughput to the peer, 8 streams
net.iperf3.tcp.rx|Gbps|higher|iperf3|iperf3 tcp peer->rx|TCP throughput from the peer, 8 streams
net.iperf3.tcp.bidir|Gbps|higher|iperf3|iperf3 tcp bidir total|TCP throughput, both directions added
net.sockperf.pingpong.avg|us|lower|sockperf|sockperf ping-pong avg (one-way)|Average one-way latency (ping-pong)
net.sockperf.pingpong.p99|us|lower|sockperf|sockperf ping-pong p99|99th percentile latency (ping-pong)
net.iperf3.udp.pps|Mpps|higher|iperf3|iperf3 udp 64B packets sent|UDP packets sent per second, 64-byte payload
net.iperf3.udp.loss|%|lower|iperf3|iperf3 udp lost packets %|UDP packet loss at the maximum send rate
web.cpubench.mix.max-rps|RPS|higher|cpubench|cpubench web mix max RPS @ SLO (loopback)|Highest requests per second within the latency target (loopback)
burnin.errors|count|lower|stressapptest, fio|burn-in errors ({x}s)|Errors found by the burn-in (memory, disk verify, kernel log)
info.cpu.steal.avg|%|none|mpstat|cpu steal avg|Average CPU steal during the whole run (context, not scored)
info.cpu.steal.peak|%|none|mpstat|cpu steal max|Highest CPU steal sample during the run (context, not scored)
info.fio.fill-write-1m|MB/s|none|fio|fio fill write 1M|Speed of the 1 MiB sequential fill before the disk tests (context, not scored)
METRICS
}
declare -A M_UNIT M_LABEL
while IFS='|' read -r _id _unit _dir _tool _label _desc; do
  [ -n "$_id" ] || continue
  M_UNIT[$_id]=$_unit; M_LABEL[$_id]=$_label
done < <(metric_table)

ROUND=1
# rec ID VALUE [X [UNIT]]: append one value. The label and unit come from the metric table; X fills {x}
# in the label (array size, test size, ...), UNIT overrides the table unit (cpubench reports its own).
rec() {
  local id=$1 label t
  if [ -z "${M_LABEL[$id]:-}" ]; then log "[BUG] unknown metric id '$id', value not recorded"; return 1; fi
  case $id in *.1t) t=1 ;; *) t=$NPROC ;; esac
  label=${M_LABEL[$id]//\{t\}/$t}; label=${label//\{x\}/${3:-}}
  printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$label" "$2" "${4:-${M_UNIT[$id]}}" "$ROUND" >> "$RES"
}
