# Zswap Benchmark Results: 2026-04-29 (t=8/32/64)

## Test Environment
- **Platform**: Kunpeng 920, 128 cores, 62GB RAM
- **Kernel**: 7.0.0+ (6.10.0-520.el10.aarch64)
- **Hardware**: hisi-deflate-acomp 1 instances (HW accelerated deflate)
- **Dataset**: Silesia (15 files, 336MB, real compression data)
- **cgroup memory.high**: 48GB
- **swap**: 16GB

## Test Configuration
- Per-thread memory: 256MB
- Threads: 8, 32, 64
- Algorithms: lz4, deflate-sw, lzo, zstd, deflate (HW)
- Test duration: 15s per phase

## Key Findings

### Throughput (Total KB/s)

| Algorithm     | t=8      | t=32      | t=64      |
|---------------|----------|-----------|-----------|
| LZ4 (sw)      | 8,424    | 11,757    | 11,238    |
| Deflate (sw)  | 8,007    | 11,521    | 11,064    |
| LZO (sw)      | 8,232    | 12,083    | 11,131    |
| ZSTD (sw)     | 7,938    | 11,964    | 11,143    |
| Deflate (HW)  | 8,343    | 11,649    | 11,139    |

### CPU Time Breakdown

| Algorithm     | Threads | User(s) | Sys(s)  | Biz% | Comp% |
|---------------|---------|---------|---------|------|-------|
| LZ4 (sw)      | 8       | 0.81    | 1.76    | 32%  | 68%   |
| LZ4 (sw)      | 32      | 10.19   | 16.56   | 38%  | 62%   |
| LZ4 (sw)      | 64      | 32.33   | 67.73   | 32%  | 68%   |
| Deflate (HW)  | 8       | 0.81    | 1.76    | 32%  | 68%   |
| Deflate (HW)  | 32      | 10.18   | 16.58   | 38%  | 62%   |
| Deflate (HW)  | 64      | 32.32   | 67.73   | 32%  | 68%   |

### Observations

1. **All tests ran in "no-swap" phase**: Total memory (2-16GB) stayed well below cgroup high (48GB), so zswap was never triggered (swap=0 for all tests). These results primarily measure mmap/memset allocation overhead, not compression performance.

2. **Peak throughput at t=32**: All algorithms show best throughput at 32 threads, declining slightly at 64 threads. This is likely due to increased fork/mmap contention at higher thread counts.

3. **Algorithm similarity**: All algorithms show nearly identical throughput because the bottleneck is memory allocation (mmap page faults + zeroing), not the compression algorithm itself.

4. **Deflate HW vs SW**: No difference observed because zswap was never activated (data stayed in RAM). Hardware acceleration would only matter under swap pressure.

5. **CPU profile**: ~65-70% sys time (kernel memory operations) vs ~30-35% user time (memset/data handling) across all configurations.

## Files

- `analysis_report.txt` - Full text report from analyze_results.py
- `results.json` - Structured JSON with all metrics
- `summary.txt` - Test configuration summary
- `*.png` - Charts (memory_pressure, throughput, cpu_breakdown, etc.)
