#!/usr/bin/env python3
"""
analyze_results.py - Zswap 性能结果分析脚本
解析 phase_*.log (逐秒采样)、zswap pre/post 快照，生成对比报告和图表
"""

import csv
import os
import re
import sys
import json
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Tuple

try:
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    import matplotlib.ticker as ticker
    HAS_MATPLOTLIB = True
except ImportError:
    HAS_MATPLOTLIB = False
    print("[WARN] matplotlib 未安装, 跳过图表生成")

# 算法显示名映射
ALGO_LABELS = {
    'lz4':        'LZ4 (sw)',
    'deflate-sw': 'Deflate (sw)',
    'lzo':        'LZO (sw)',
    'zstd':       'ZSTD (sw)',
    'deflate':    'Deflate (HW)',
}

ALGO_COLORS = {
    'lz4':        '#1f77b4',
    'deflate-sw': '#ff7f0e',
    'lzo':        '#2ca02c',
    'zstd':       '#d62728',
    'deflate':    '#9467bd',
}

# 内存阶段阈值 (需与 benchmark 脚本一致)
CGROUP_MEM_HIGH = 16 * 1024  # 16G in MB
SWAP_SIZE = 16 * 1024         # 16G in MB


class PhaseSample:
    """单个采样点"""
    __slots__ = ['timestamp', 'memory_current', 'swap_current',
                 'zswap_stored_pages', 'zswap_compressed_pages']

    def __init__(self, row: dict):
        self.timestamp = float(row['timestamp'])
        self.memory_current = int(row['memory_current'])
        self.swap_current = int(row['swap_current'])
        self.zswap_stored_pages = int(row.get('zswap_stored_pages', '0'))
        self.zswap_compressed_pages = int(row.get('zswap_compressed_pages', '0'))

    @property
    def memory_mb(self) -> int:
        return self.memory_current // (1024 * 1024)

    @property
    def swap_mb(self) -> int:
        return self.swap_current // (1024 * 1024)

    @property
    def compression_ratio(self) -> Optional[float]:
        if self.zswap_compressed_pages > 0:
            return self.zswap_stored_pages / self.zswap_compressed_pages
        return None


class LlamaPhaseSample:
    """llama-bench 多进程测试的采样点"""
    __slots__ = ['timestamp', 'memory_current', 'swap_current', 'running_instances']

    def __init__(self, row: dict):
        self.timestamp = float(row['timestamp'])
        self.memory_current = int(row['memory_current'])
        self.swap_current = int(row['swap_current'])
        self.running_instances = int(row.get('running_instances', '0'))

    @property
    def memory_mb(self) -> int:
        return self.memory_current // (1024 * 1024)

    @property
    def swap_mb(self) -> int:
        return self.swap_current // (1024 * 1024)


class TestResult:
    """单个 algo+threads 测试结果"""
    def __init__(self, algo: str, threads: int):
        self.algo = algo
        self.threads = threads
        self.samples: List[PhaseSample] = []
        # llama-bench 多进程采样
        self.llama_samples: List[LlamaPhaseSample] = []
        # 元数据 (从 memtest_*.log 头部解析)
        self.total_mem_mb: Optional[int] = None
        self.expected_phase: Optional[str] = None
        self.numa_policy: Optional[str] = None
        self.duration: Optional[int] = None
        # zswap pre/post 快照
        self.zswap_pre: Dict[str, int] = {}
        self.zswap_post: Dict[str, int] = {}
        # llama-bench (可选)
        self.throughput: Optional[float] = None
        self.latency: Optional[float] = None
        # 吞吐量/CPU 指标 (从 METRICS 行解析)
        self.total_throughput_kbps: Optional[float] = None
        self.avg_throughput_kbps: Optional[float] = None
        self.alloc_elapsed_sec: Optional[float] = None
        self.user_time_sec: Optional[float] = None
        self.sys_time_sec: Optional[float] = None
        self.wall_elapsed_sec: Optional[float] = None
        self.cpu_user_pct: Optional[float] = None
        self.cpu_sys_pct: Optional[float] = None
        self.cpu_idle_pct: Optional[float] = None
        self.child_user_sec: Optional[float] = None
        self.child_sys_sec: Optional[float] = None
        self.business_pct: Optional[float] = None
        self.compression_pct: Optional[float] = None
        # llama-bench 多进程指标
        self.llama_user_ms: Optional[int] = None
        self.llama_sys_ms: Optional[int] = None
        self.llama_instances: Optional[int] = None
        self.llama_total_model_mem_mb: Optional[int] = None
        self.llama_successful_instances: Optional[int] = None
        # llama 各实例 eval tokens/s
        self.llama_eval_rates: List[float] = []
        # llama 内存压力峰值
        self.llama_peak_memory_mb: Optional[int] = None
        self.llama_peak_swap_mb: Optional[int] = None

    @property
    def peak_memory_mb(self) -> Optional[int]:
        if not self.samples:
            return None
        return max(s.memory_mb for s in self.samples)

    @property
    def peak_swap_mb(self) -> Optional[int]:
        if not self.samples:
            return None
        return max(s.swap_mb for s in self.samples)

    @property
    def peak_stored_pages(self) -> Optional[int]:
        if not self.samples:
            return None
        return max(s.zswap_stored_pages for s in self.samples)

    @property
    def peak_compressed_pages(self) -> Optional[int]:
        if not self.samples:
            return None
        return max(s.zswap_compressed_pages for s in self.samples)

    @property
    def compression_ratio(self) -> Optional[float]:
        """稳态压缩比 (取最后 1/3 样本的中位数)"""
        if not self.samples:
            return None
        tail = self.samples[len(self.samples) // 3:]
        ratios = [s.compression_ratio for s in tail if s.compression_ratio is not None]
        if not ratios:
            return None
        ratios.sort()
        return ratios[len(ratios) // 2]

    @property
    def zswap_delta_pages(self) -> Optional[int]:
        """测试前后 zswap stored_pages 增量"""
        pre = self.zswap_pre.get('stored_pages')
        post = self.zswap_post.get('stored_pages')
        if pre is not None and post is not None:
            return post - pre
        return None

    @property
    def zswap_delta_mb(self) -> Optional[int]:
        delta = self.zswap_delta_pages
        if delta is not None:
            return delta * 4 // 1024  # 4KB per page
        return None


class ZswapAnalyzer:
    """Zswap 结果分析器"""

    def __init__(self, results_dir: str):
        self.results_dir = Path(results_dir)
        self.results: Dict[str, List[TestResult]] = {}

    # ---- 解析 phase_*.log (逐秒采样 CSV) ----
    def parse_phase_log(self, filepath: Path) -> Optional[TestResult]:
        if not filepath.exists():
            return None

        # 从文件名提取: phase_algo_tN.log 或 phase_llama_algo_tN.log
        filename = filepath.stem
        is_llama = filename.startswith('phase_llama_')

        if is_llama:
            # phase_llama_algo_tN.log
            rest = filename[len('phase_llama_'):]
            parts = rest.split('_')
            if len(parts) < 2:
                return None
            # 找到 't' 开头的部分作为 threads
            algo_parts = []
            threads = None
            for p in parts:
                if p.startswith('t') and p[1:].isdigit():
                    threads = int(p[1:])
                    break
                algo_parts.append(p)
            if threads is None:
                return None
            algo = '_'.join(algo_parts)
        else:
            # phase_algo_tN.log
            parts = filename.split('_')
            if len(parts) < 3:
                return None
            algo = parts[1]
            threads = int(parts[2].replace('t', ''))

        result = TestResult(algo, threads)

        with open(filepath) as f:
            reader = csv.DictReader(f)
            for row in reader:
                try:
                    if is_llama:
                        result.llama_samples.append(LlamaPhaseSample(row))
                    else:
                        result.samples.append(PhaseSample(row))
                except (ValueError, KeyError):
                    continue

        if not result.samples and not result.llama_samples:
            return None

        return result

    # ---- 解析 memtest_*.log 头部 + METRICS ----
    def parse_memtest_header(self, filepath: Path):
        if not filepath.exists():
            return

        content = filepath.read_text()
        filename = filepath.stem
        parts = filename.split('_')
        if len(parts) < 3:
            return
        algo = parts[1]
        threads = int(parts[2].replace('t', ''))

        result = self._find_or_create(algo, threads)

        # 提取元数据
        m = re.search(r'Total_Mem:\s+(\d+)MB', content)
        if m:
            result.total_mem_mb = int(m.group(1))
        m = re.search(r'Expected_Phase:\s+(.+)', content)
        if m:
            result.expected_phase = m.group(1).strip()
        m = re.search(r'NUMA_Policy:\s+(.*)', content)
        if m:
            policy = m.group(1).strip()
            result.numa_policy = policy if policy else None
        m = re.search(r'Duration:\s+(\d+)s', content)
        if m:
            result.duration = int(m.group(1))

        # 解析 METRICS: 行
        for line in content.splitlines():
            if not line.startswith('METRICS:'):
                continue
            m = re.match(r'METRICS:(\w+)=(.+)', line)
            if not m:
                continue
            key, val = m.group(1), m.group(2)
            try:
                if key == 'total_throughput_kbps':
                    result.total_throughput_kbps = float(val)
                elif key == 'avg_throughput_kbps':
                    result.avg_throughput_kbps = float(val)
                elif key == 'alloc_elapsed_sec':
                    result.alloc_elapsed_sec = float(val)
                elif key == 'user_time_sec':
                    result.user_time_sec = float(val)
                elif key == 'sys_time_sec':
                    result.sys_time_sec = float(val)
                elif key == 'wall_elapsed_sec':
                    result.wall_elapsed_sec = float(val)
                elif key == 'cpu_user_pct':
                    result.cpu_user_pct = float(val)
                elif key == 'cpu_sys_pct':
                    result.cpu_sys_pct = float(val)
                elif key == 'cpu_idle_pct':
                    result.cpu_idle_pct = float(val)
                elif key == 'child_user_sec':
                    result.child_user_sec = float(val)
                elif key == 'child_sys_sec':
                    result.child_sys_sec = float(val)
                elif key == 'business_pct':
                    result.business_pct = float(val)
                elif key == 'compression_pct':
                    result.compression_pct = float(val)
            except ValueError:
                pass

    # ---- 解析 llama-bench 多进程输出 ----
    def parse_bench_log(self, filepath: Path):
        if not filepath.exists():
            return

        content = filepath.read_text()
        filename = filepath.stem
        parts = filename.split('_')
        if len(parts) < 3:
            return
        algo = parts[1]
        threads = int(parts[2].replace('t', ''))

        result = self._find_or_create(algo, threads)

        # 多实例元数据
        m = re.search(r'Concurrent_Instances:\s+(\d+)', content)
        if m:
            result.llama_instances = int(m.group(1))
        m = re.search(r'Total_Model_Mem_MB:\s+(\d+)', content)
        if m:
            result.llama_total_model_mem_mb = int(m.group(1))
        m = re.search(r'Successful_Instances:\s+(\d+)\s*/\s*\d+', content)
        if m:
            result.llama_successful_instances = int(m.group(1))

        # CPU usage
        m = re.search(r'llama_user_ms:\s+(\d+)', content)
        if m:
            result.llama_user_ms = int(m.group(1))
        m = re.search(r'llama_sys_ms:\s+(\d+)', content)
        if m:
            result.llama_sys_ms = int(m.group(1))

        # 提取各实例的 eval tokens/s
        # llama-bench 输出格式: | model | size | params | backend | ngl | test | t/s |
        # 匹配每实例输出中最后一行数据行的 t/s 值
        eval_rates = []
        inst_blocks = re.split(r'---\s*Instance\s*\d+\s*---', content)
        for block in inst_blocks[1:]:  # skip text before first instance
            # llama-bench 输出的最后一行通常包含 eval rate
            # 匹配格式如: "qwen2 ...  123.45 ± 2.34" 或简单的数字行
            lines = block.strip().splitlines()
            for line in reversed(lines):
                # llama-bench table output: last numeric column
                nums = re.findall(r'(\d+\.\d+)', line)
                if nums:
                    try:
                        eval_rates.append(float(nums[-1]))
                        break
                    except ValueError:
                        pass

        if eval_rates:
            result.llama_eval_rates = eval_rates
            # 平均 eval rate 作为 throughput
            result.throughput = sum(eval_rates) / len(eval_rates)

        # 从 llama phase samples 计算峰值
        if result.llama_samples:
            result.llama_peak_memory_mb = max(s.memory_mb for s in result.llama_samples)
            result.llama_peak_swap_mb = max(s.swap_mb for s in result.llama_samples)

    # ---- 解析 zswap pre/post 快照 ----
    def parse_zswap_snapshot(self, filepath: Path):
        if not filepath.exists():
            return

        content = filepath.read_text()
        filename = filepath.stem
        # 文件名: zswap_algo_tN_pre.log 或 zswap_algo_tN_post.log
        parts = filename.split('_')
        if len(parts) < 4:
            return
        algo = parts[1]
        threads = int(parts[2].replace('t', ''))
        tag = parts[3]  # "pre" or "post"

        result = self._find_or_create(algo, threads)

        stats = {}
        for key in ['stored_pages', 'compressed_pages', 'pool_total_size',
                     'pool_limit_hit', 'reject_compress_poor', 'reject_alloc_fail']:
            m = re.search(rf'^{key}\s+(\d+)', content, re.MULTILINE)
            if m:
                stats[key] = int(m.group(1))

        if tag == 'pre':
            result.zswap_pre = stats
        else:
            result.zswap_post = stats

    def _find_or_create(self, algo: str, threads: int) -> TestResult:
        if algo not in self.results:
            self.results[algo] = []
        for r in self.results[algo]:
            if r.threads == threads:
                return r
        r = TestResult(algo, threads)
        self.results[algo].append(r)
        return r

    # ---- 加载所有结果 ----
    def load_results(self):
        # phase_*.log (逐秒采样)
        for f in sorted(self.results_dir.glob("phase_*.log")):
            result = self.parse_phase_log(f)
            if result:
                self._merge_result(result)

        # memtest_*.log (元数据)
        for f in sorted(self.results_dir.glob("memtest_*.log")):
            self.parse_memtest_header(f)

        # bench_*.log (llama-bench, 可选)
        for f in sorted(self.results_dir.glob("bench_*.log")):
            self.parse_bench_log(f)

        # zswap pre/post 快照
        for f in sorted(self.results_dir.glob("zswap_*_pre.log")):
            self.parse_zswap_snapshot(f)
        for f in sorted(self.results_dir.glob("zswap_*_post.log")):
            self.parse_zswap_snapshot(f)

    def _merge_result(self, result: TestResult):
        algo = result.algo
        if algo not in self.results:
            self.results[algo] = []
        for r in self.results[algo]:
            if r.threads == result.threads:
                # 合并采样数据
                r.samples.extend(result.samples)
                return
        self.results[algo].append(result)

    # ---- 计算内存压力阶段 ----
    @staticmethod
    def classify_phase(total_mem_mb: int) -> str:
        if total_mem_mb < CGROUP_MEM_HIGH:
            return "无 swap"
        elif total_mem_mb < CGROUP_MEM_HIGH + SWAP_SIZE:
            return "zswap 压缩"
        else:
            return "swap 满载"

    # ---- 文本报告 ----
    def generate_report(self) -> str:
        lines = []
        lines.append("=" * 80)
        lines.append("  Zswap Performance Analysis Report")
        lines.append("=" * 80)
        lines.append(f"Generated:    {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
        lines.append(f"Results Dir:  {self.results_dir}")
        lines.append(f"Algorithms:   {', '.join(sorted(self.results.keys()))}")
        lines.append(f"Phase Thresholds: 无 swap < {CGROUP_MEM_HIGH}MB, "
                     f"zswap < {CGROUP_MEM_HIGH + SWAP_SIZE}MB, swap 满载 >= {CGROUP_MEM_HIGH + SWAP_SIZE}MB")
        lines.append("")

        # ---- 1. 内存压力阶段总览 ----
        lines.append("=" * 80)
        lines.append("  1. 内存压力阶段总览")
        lines.append("=" * 80)
        lines.append("")
        lines.append(f"{'Algorithm':<18} {'Threads':<10} {'Total Load':<14} "
                     f"{'Phase':<16} {'Peak Mem':<12} {'Peak Swap':<12}")
        lines.append("-" * 80)

        for algo in sorted(self.results.keys()):
            results = sorted(self.results[algo], key=lambda x: x.threads)
            label = ALGO_LABELS.get(algo, algo)
            for r in results:
                load = f"{r.total_mem_mb}MB" if r.total_mem_mb else "N/A"
                phase = r.expected_phase or self.classify_phase(r.total_mem_mb or 0)
                peak_mem = f"{r.peak_memory_mb}MB" if r.peak_memory_mb is not None else "N/A"
                peak_swap = f"{r.peak_swap_mb}MB" if r.peak_swap_mb is not None else "N/A"
                lines.append(f"{label:<18} {r.threads:<10} {load:<14} "
                             f"{phase:<16} {peak_mem:<12} {peak_swap:<12}")
            lines.append("")

        # ---- 2. 压缩比对比 ----
        lines.append("=" * 80)
        lines.append("  2. 压缩比对比 (稳态)")
        lines.append("=" * 80)
        lines.append("")
        lines.append(f"{'Algorithm':<18} {'Threads':<10} {'Total Load':<14} "
                     f"{'Phase':<16} {'Ratio':<10} {'Zswap Delta':<14}")
        lines.append("-" * 80)

        for algo in sorted(self.results.keys()):
            results = sorted(self.results[algo], key=lambda x: x.threads)
            label = ALGO_LABELS.get(algo, algo)
            for r in results:
                load = f"{r.total_mem_mb}MB" if r.total_mem_mb else "N/A"
                phase = r.expected_phase or self.classify_phase(r.total_mem_mb or 0)
                ratio = f"{r.compression_ratio:.2f}x" if r.compression_ratio else "N/A"
                delta = f"{r.zswap_delta_mb}MB" if r.zswap_delta_mb is not None else "N/A"
                lines.append(f"{label:<18} {r.threads:<10} {load:<14} "
                             f"{phase:<16} {ratio:<10} {delta:<14}")
            lines.append("")

        # ---- 3. 吞吐量/性能指标 ----
        has_tp = any(r.total_throughput_kbps for algo in self.results.values() for r in algo)
        if has_tp:
            lines.append("=" * 80)
            lines.append("  3. 吞吐量 / 性能指标")
            lines.append("=" * 80)
            lines.append("")
            lines.append(f"{'Algorithm':<18} {'Threads':<10} {'Total KB/s':<14} "
                         f"{'Avg KB/s':<14} {'Alloc(s)':<12} {'Wall(s)':<10}")
            lines.append("-" * 80)
            for algo in sorted(self.results.keys()):
                results = sorted(self.results[algo], key=lambda x: x.threads)
                label = ALGO_LABELS.get(algo, algo)
                for r in results:
                    tp = f"{r.total_throughput_kbps:.0f}" if r.total_throughput_kbps else "N/A"
                    avg = f"{r.avg_throughput_kbps:.0f}" if r.avg_throughput_kbps else "N/A"
                    at = f"{r.alloc_elapsed_sec:.3f}" if r.alloc_elapsed_sec else "N/A"
                    wt = f"{r.wall_elapsed_sec:.2f}" if r.wall_elapsed_sec else "N/A"
                    lines.append(f"{label:<18} {r.threads:<10} {tp:<14} "
                                 f"{avg:<14} {at:<12} {wt:<10}")
                lines.append("")

        # ---- 4. 时间/CPU 开销 ----
        has_cpu = any(r.sys_time_sec is not None for algo in self.results.values() for r in algo)
        if has_cpu:
            lines.append("=" * 80)
            lines.append("  4. 时间与 CPU 开销")
            lines.append("=" * 80)
            lines.append("")
            lines.append(f"{'Algorithm':<18} {'Threads':<10} {'User(s)':<12} "
                         f"{'Sys(s)':<12} {'Biz%':<10} {'Comp%':<10} {'CPU User%':<12} {'CPU Sys%':<12} {'CPU Idle%':<12}")
            lines.append("-" * 100)
            for algo in sorted(self.results.keys()):
                results = sorted(self.results[algo], key=lambda x: x.threads)
                label = ALGO_LABELS.get(algo, algo)
                for r in results:
                    cu = f"{r.child_user_sec:.3f}" if r.child_user_sec is not None else "N/A"
                    cs = f"{r.child_sys_sec:.3f}" if r.child_sys_sec is not None else "N/A"
                    biz = f"{r.business_pct:.1f}" if r.business_pct is not None else "N/A"
                    comp = f"{r.compression_pct:.1f}" if r.compression_pct is not None else "N/A"
                    sysu = f"{r.cpu_user_pct:.1f}" if r.cpu_user_pct is not None else "N/A"
                    syss = f"{r.cpu_sys_pct:.1f}" if r.cpu_sys_pct is not None else "N/A"
                    sysi = f"{r.cpu_idle_pct:.1f}" if r.cpu_idle_pct is not None else "N/A"
                    lines.append(f"{label:<18} {r.threads:<10} {cu:<12} "
                                 f"{cs:<12} {biz:<10} {comp:<10} {sysu:<12} {syss:<12} {sysi:<12}")
                lines.append("")

        # ---- 5. Zswap Pool 统计 ----
        lines.append("=" * 80)
        lines.append("  5. Zswap Pool 统计 (post-test)")
        lines.append("=" * 80)
        lines.append("")
        lines.append(f"{'Algorithm':<18} {'Threads':<10} {'Pool Size':<14} "
                     f"{'Limit Hit':<12} {'Rej(Poor)':<12} {'Rej(Alloc)':<12}")
        lines.append("-" * 80)

        for algo in sorted(self.results.keys()):
            results = sorted(self.results[algo], key=lambda x: x.threads)
            label = ALGO_LABELS.get(algo, algo)
            for r in results:
                post = r.zswap_post
                pool = f"{post.get('pool_total_size', 0)}" if post.get('pool_total_size') else "N/A"
                limit = f"{post.get('pool_limit_hit', 0)}" if 'pool_limit_hit' in post else "N/A"
                rej_poor = f"{post.get('reject_compress_poor', 0)}" if 'reject_compress_poor' in post else "N/A"
                rej_alloc = f"{post.get('reject_alloc_fail', 0)}" if 'reject_alloc_fail' in post else "N/A"
                lines.append(f"{label:<18} {r.threads:<10} {pool:<14} "
                             f"{limit:<12} {rej_poor:<12} {rej_alloc:<12}")
            lines.append("")

        # ---- 6. llama-bench 多进程结果 ----
        has_llama = any(r.llama_instances for algo in self.results.values() for r in algo)
        if has_llama:
            lines.append("=" * 80)
            lines.append("  6. llama-bench 多进程内存压力测试")
            lines.append("=" * 80)
            lines.append("")
            lines.append(f"{'Algorithm':<18} {'Threads':<10} {'Instances':<12} "
                         f"{'Total Mem':<14} {'Phase':<16} {'Avg t/s':<12} {'Success':<10}")
            lines.append("-" * 92)
            for algo in sorted(self.results.keys()):
                results = sorted(self.results[algo], key=lambda x: x.threads)
                label = ALGO_LABELS.get(algo, algo)
                for r in results:
                    if r.llama_instances:
                        inst = f"{r.llama_instances}"
                        total = f"{r.llama_total_model_mem_mb}MB" if r.llama_total_model_mem_mb else "N/A"
                        phase = r.expected_phase or self.classify_phase(r.llama_total_model_mem_mb or 0)
                        avg_ts = f"{r.throughput:.1f}" if r.throughput else "N/A"
                        succ = f"{r.llama_successful_instances}/{r.llama_instances}" if r.llama_successful_instances else "N/A"
                        lines.append(f"{label:<18} {r.threads:<10} {inst:<12} "
                                     f"{total:<14} {phase:<16} {avg_ts:<12} {succ:<10}")
                lines.append("")

            # llama-bench 内存压力峰值
            lines.append(f"{'Algorithm':<18} {'Threads':<10} {'Instances':<12} "
                         f"{'Peak Mem':<14} {'Peak Swap':<14} {'User(ms)':<12} {'Sys(ms)':<12}")
            lines.append("-" * 92)
            for algo in sorted(self.results.keys()):
                results = sorted(self.results[algo], key=lambda x: x.threads)
                label = ALGO_LABELS.get(algo, algo)
                for r in results:
                    if r.llama_instances:
                        pm = f"{r.llama_peak_memory_mb}MB" if r.llama_peak_memory_mb else "N/A"
                        ps = f"{r.llama_peak_swap_mb}MB" if r.llama_peak_swap_mb else "N/A"
                        lu = f"{r.llama_user_ms}" if r.llama_user_ms else "N/A"
                        ls = f"{r.llama_sys_ms}" if r.llama_sys_ms else "N/A"
                        lines.append(f"{label:<18} {r.threads:<10} {r.llama_instances:<12} "
                                     f"{pm:<14} {ps:<14} {lu:<12} {ls:<12}")
                lines.append("")

        lines.append("=" * 80)
        return "\n".join(lines)

    # ---- 图表生成 ----
    def plot_results(self, output_dir: Path):
        if not HAS_MATPLOTLIB or not self.results:
            return

        output_dir = Path(output_dir)
        algos = sorted(self.results.keys())

        # ---- 图1: 内存压力阶段图 (堆叠面积图) ----
        fig, ax = plt.subplots(figsize=(14, 8))
        for algo in algos:
            results = sorted(self.results[algo], key=lambda x: x.threads)
            threads_list = []
            mem_peak = []
            swap_peak = []
            for r in results:
                if r.peak_memory_mb is not None:
                    threads_list.append(r.threads)
                    mem_peak.append(r.peak_memory_mb)
                    swap_peak.append(r.peak_swap_mb or 0)

            if threads_list:
                color = ALGO_COLORS.get(algo, 'gray')
                label = ALGO_LABELS.get(algo, algo)
                ax.plot(threads_list, mem_peak, 'o-', label=f'{label} memory', color=color, linewidth=2)
                if any(s > 0 for s in swap_peak):
                    ax.plot(threads_list, swap_peak, 's--', label=f'{label} swap',
                            color=color, linewidth=1.5, alpha=0.7)

        # 标注阶段区域
        ax.axhline(y=CGROUP_MEM_HIGH, color='red', linestyle=':', alpha=0.5, label=f'cgroup high ({CGROUP_MEM_HIGH}MB)')
        ax.set_xlabel('Threads')
        ax.set_ylabel('Memory Usage (MB)')
        ax.set_title('Zswap Benchmark: Memory Pressure by Threads')
        ax.legend(loc='upper left', fontsize=8)
        ax.grid(True, alpha=0.3)
        fig.tight_layout()
        fig.savefig(output_dir / 'memory_pressure.png', dpi=150)
        plt.close(fig)

        # ---- 图2: 三阶段性能折线 (memory + swap 随时间) ----
        # 选取高线程数 (接近或超过 cgroup high) 的测试绘制时间序列
        for algo in algos:
            results = sorted(self.results[algo], key=lambda x: x.threads)
            # 选取有 swap 使用的最高线程数测试
            best_r = None
            for r in reversed(results):
                if r.samples and r.peak_swap_mb and r.peak_swap_mb > 0:
                    best_r = r
                    break
            if best_r is None:
                # fallback: 取最高线程数
                best_r = results[-1] if results else None
            if best_r is None or not best_r.samples:
                continue

            fig, ax1 = plt.subplots(figsize=(14, 8))
            times = [s.timestamp - best_r.samples[0].timestamp for s in best_r.samples]
            mem_vals = [s.memory_mb for s in best_r.samples]
            swap_vals = [s.swap_mb for s in best_r.samples]

            ax1.fill_between(times, mem_vals, alpha=0.3, color='#1f77b4', label='memory.current')
            ax1.plot(times, mem_vals, color='#1f77b4', linewidth=1.5)
            ax1.fill_between(times, swap_vals, alpha=0.3, color='#ff7f0e', label='swap.current')
            ax1.plot(times, swap_vals, color='#ff7f0e', linewidth=1.5)

            ax1.axhline(y=CGROUP_MEM_HIGH, color='red', linestyle=':', alpha=0.5)
            ax1.set_xlabel('Time (s)')
            ax1.set_ylabel('Memory (MB)')
            label = ALGO_LABELS.get(algo, algo)
            ax1.set_title(f'{label} @ {best_r.threads} threads: Memory/Swap Over Time')
            ax1.legend(loc='upper left')
            ax1.grid(True, alpha=0.3)
            fig.tight_layout()
            safe_algo = algo.replace('-', '_')
            fig.savefig(output_dir / f'timeseries_{safe_algo}_t{best_r.threads}.png', dpi=150)
            plt.close(fig)

        # ---- 图3: 各算法 swap 使用对比 ----
        fig, ax = plt.subplots(figsize=(14, 8))
        for algo in algos:
            results = sorted(self.results[algo], key=lambda x: x.threads)
            threads_list = [r.threads for r in results if r.peak_swap_mb is not None]
            swap_vals = [r.peak_swap_mb for r in results if r.peak_swap_mb is not None]
            if threads_list:
                color = ALGO_COLORS.get(algo, 'gray')
                label = ALGO_LABELS.get(algo, algo)
                ax.plot(threads_list, swap_vals, 'o-', label=label, color=color, linewidth=2)

        ax.axhline(y=SWAP_SIZE, color='red', linestyle=':', alpha=0.5, label=f'swap limit ({SWAP_SIZE}MB)')
        ax.set_xlabel('Threads')
        ax.set_ylabel('Peak Swap Usage (MB)')
        ax.set_title('Zswap Benchmark: Swap Usage by Algorithm')
        ax.legend(loc='upper left')
        ax.grid(True, alpha=0.3)
        fig.tight_layout()
        fig.savefig(output_dir / 'swap_usage.png', dpi=150)
        plt.close(fig)

        # ---- 图4: Total Throughput vs Threads ----
        has_tp = any(r.total_throughput_kbps for algo in algos for r in self.results[algo])
        if has_tp:
            fig, ax = plt.subplots(figsize=(14, 8))
            for algo in algos:
                results = sorted(self.results[algo], key=lambda x: x.threads)
                ts = [r.threads for r in results if r.total_throughput_kbps]
                vals = [r.total_throughput_kbps for r in results if r.total_throughput_kbps]
                if ts:
                    color = ALGO_COLORS.get(algo, 'gray')
                    label = ALGO_LABELS.get(algo, algo)
                    ax.plot(ts, vals, 'o-', label=label, color=color, linewidth=2)
            ax.set_xlabel('Threads')
            ax.set_ylabel('Total Throughput (KB/s)')
            ax.set_title('Zswap Benchmark: Total Throughput vs Threads')
            ax.legend(loc='upper left')
            ax.grid(True, alpha=0.3)
            fig.tight_layout()
            fig.savefig(output_dir / 'throughput_vs_threads.png', dpi=150)
            plt.close(fig)

        # ---- 图5: Elapsed / Sys Time vs Threads ----
        has_time = any(r.alloc_elapsed_sec is not None for algo in algos for r in self.results[algo])
        if has_time:
            fig, axes = plt.subplots(1, 2, figsize=(16, 7))

            ax = axes[0]
            for algo in algos:
                results = sorted(self.results[algo], key=lambda x: x.threads)
                ts = [r.threads for r in results if r.alloc_elapsed_sec is not None]
                vals = [r.alloc_elapsed_sec for r in results if r.alloc_elapsed_sec is not None]
                if ts:
                    color = ALGO_COLORS.get(algo, 'gray')
                    label = ALGO_LABELS.get(algo, algo)
                    ax.plot(ts, vals, 'o-', label=label, color=color, linewidth=2)
            ax.set_xlabel('Threads')
            ax.set_ylabel('Alloc Elapsed Time (sec)')
            ax.set_title('Memory Allocation Time vs Threads')
            ax.legend(loc='upper left', fontsize=8)
            ax.grid(True, alpha=0.3)

            ax = axes[1]
            for algo in algos:
                results = sorted(self.results[algo], key=lambda x: x.threads)
                ts = [r.threads for r in results if r.sys_time_sec is not None]
                vals = [r.sys_time_sec for r in results if r.sys_time_sec is not None]
                if ts:
                    color = ALGO_COLORS.get(algo, 'gray')
                    label = ALGO_LABELS.get(algo, algo)
                    ax.plot(ts, vals, 'o-', label=label, color=color, linewidth=2)
            ax.set_xlabel('Threads')
            ax.set_ylabel('System Time (sec)')
            ax.set_title('Kernel/Compression Time vs Threads')
            ax.legend(loc='upper left', fontsize=8)
            ax.grid(True, alpha=0.3)

            fig.tight_layout()
            fig.savefig(output_dir / 'time_vs_threads.png', dpi=150)
            plt.close(fig)

        # ---- 图6: CPU Usage Breakdown: Business vs Compression ----
        has_biz = any(r.business_pct is not None for algo in algos for r in self.results[algo])
        if has_biz:
            for algo in algos:
                results = sorted(self.results[algo], key=lambda x: x.threads)
                ts = [r.threads for r in results if r.business_pct is not None]
                if not ts:
                    continue
                biz_vals = [r.business_pct for r in results if r.business_pct is not None]
                comp_vals = [r.compression_pct for r in results if r.compression_pct is not None]

                fig, ax = plt.subplots(figsize=(12, 7))
                bar_w = 0.8
                x_pos = range(len(ts))
                bars_biz = ax.bar(x_pos, biz_vals, bar_w, label='Business (user)', color='#2196F3')
                bars_comp = ax.bar(x_pos, comp_vals, bar_w, bottom=biz_vals,
                                   label='Compression/Kernel (sys)', color='#FF9800')
                ax.set_xticks(x_pos)
                ax.set_xticklabels([str(t) for t in ts])
                ax.set_xlabel('Threads')
                ax.set_ylabel('CPU Usage within cgroup (%)')
                ax.set_ylim(0, 105)
                label = ALGO_LABELS.get(algo, algo)
                ax.set_title(f'{label}: Business vs Compression CPU')
                ax.legend(loc='upper right')
                ax.grid(True, alpha=0.3, axis='y')
                # Add value labels
                for i, (b, c) in enumerate(zip(biz_vals, comp_vals)):
                    ax.text(i, b / 2, f'{b:.0f}%', ha='center', va='center', fontsize=8, color='white')
                    if c > 5:
                        ax.text(i, b + c / 2, f'{c:.0f}%', ha='center', va='center', fontsize=8, color='white')
                fig.tight_layout()
                safe_algo = algo.replace('-', '_')
                fig.savefig(output_dir / f'cpu_breakdown_{safe_algo}.png', dpi=150)
                plt.close(fig)

        # ---- 图7: 压缩比对比 (柱状图) ----
        fig, ax = plt.subplots(figsize=(12, 7))
        labels = []
        ratios = []
        colors = []
        for algo in algos:
            results = sorted(self.results[algo], key=lambda x: x.threads)
            # 取高线程数 (有 zswap 活动) 的结果
            for r in reversed(results):
                if r.compression_ratio is not None:
                    labels.append(f"{ALGO_LABELS.get(algo, algo)}\n({r.threads}T)")
                    ratios.append(r.compression_ratio)
                    colors.append(ALGO_COLORS.get(algo, 'gray'))
                    break

        if ratios:
            bars = ax.bar(range(len(labels)), ratios, color=colors)
            ax.set_xticks(range(len(labels)))
            ax.set_xticklabels(labels, fontsize=9)
            ax.set_ylabel('Compression Ratio (stored/compressed)')
            ax.set_title('Zswap Compression Ratio by Algorithm')
            for bar, ratio in zip(bars, ratios):
                ax.text(bar.get_x() + bar.get_width() / 2, bar.get_height() + 0.02,
                        f'{ratio:.2f}x', ha='center', va='bottom', fontsize=10)
            ax.grid(True, alpha=0.3, axis='y')
            fig.tight_layout()
            fig.savefig(output_dir / 'compression_ratio.png', dpi=150)
            plt.close(fig)

        # ---- 图8: 硬件 vs 软件对比 (deflate) ----
        if 'deflate' in self.results and 'deflate-sw' in self.results:
            fig, axes = plt.subplots(1, 3, figsize=(20, 6))

            # 5a: memory 使用对比
            ax = axes[0]
            for algo, label, color in [('deflate-sw', 'Deflate (sw)', ALGO_COLORS['deflate-sw']),
                                        ('deflate', 'Deflate (HW)', ALGO_COLORS['deflate'])]:
                results = sorted(self.results[algo], key=lambda x: x.threads)
                threads_list = [r.threads for r in results if r.peak_memory_mb is not None]
                mem_vals = [r.peak_memory_mb for r in results if r.peak_memory_mb is not None]
                if threads_list:
                    ax.plot(threads_list, mem_vals, 'o-', label=label, color=color, linewidth=2)
            ax.axhline(y=CGROUP_MEM_HIGH, color='red', linestyle=':', alpha=0.5)
            ax.set_xlabel('Threads')
            ax.set_ylabel('Peak Memory (MB)')
            ax.set_title('Deflate: HW vs SW (Memory)')
            ax.legend()
            ax.grid(True, alpha=0.3)

            # 5b: swap 使用对比
            ax = axes[1]
            for algo, label, color in [('deflate-sw', 'Deflate (sw)', ALGO_COLORS['deflate-sw']),
                                        ('deflate', 'Deflate (HW)', ALGO_COLORS['deflate'])]:
                results = sorted(self.results[algo], key=lambda x: x.threads)
                threads_list = [r.threads for r in results if r.peak_swap_mb is not None]
                swap_vals = [r.peak_swap_mb for r in results if r.peak_swap_mb is not None]
                if threads_list:
                    ax.plot(threads_list, swap_vals, 'o-', label=label, color=color, linewidth=2)
            ax.set_xlabel('Threads')
            ax.set_ylabel('Peak Swap (MB)')
            ax.set_title('Deflate: HW vs SW (Swap)')
            ax.legend()
            ax.grid(True, alpha=0.3)

            # 5c: 压缩比对比
            ax = axes[2]
            for algo, label, color in [('deflate-sw', 'Deflate (sw)', ALGO_COLORS['deflate-sw']),
                                        ('deflate', 'Deflate (HW)', ALGO_COLORS['deflate'])]:
                results = sorted(self.results[algo], key=lambda x: x.threads)
                threads_list = []
                ratio_vals = []
                for r in results:
                    # 取每个线程数最终采样点的压缩比
                    if r.samples:
                        last = r.samples[-1]
                        if last.compression_ratio is not None and last.zswap_compressed_pages > 0:
                            threads_list.append(r.threads)
                            ratio_vals.append(last.compression_ratio)
                if threads_list:
                    ax.plot(threads_list, ratio_vals, 'o-', label=label, color=color, linewidth=2)
            ax.set_xlabel('Threads')
            ax.set_ylabel('Compression Ratio')
            ax.set_title('Deflate: HW vs SW (Compression)')
            ax.legend()
            ax.grid(True, alpha=0.3)

            fig.tight_layout()
            fig.savefig(output_dir / 'hw_vs_sw_deflate.png', dpi=150)
            plt.close(fig)

        # ---- 图9: 各算法逐秒内存时间线对比 (最高线程数) ----
        max_threads = 0
        for algo in algos:
            results = sorted(self.results[algo], key=lambda x: x.threads)
            if results:
                max_threads = max(max_threads, results[-1].threads)

        if max_threads > 0:
            fig, axes = plt.subplots(2, 1, figsize=(16, 12), sharex=True)

            # 上图: memory.current
            ax = axes[0]
            for algo in algos:
                results = sorted(self.results[algo], key=lambda x: x.threads)
                r = next((x for x in reversed(results) if x.threads == max_threads and x.samples), None)
                if r:
                    times = [s.timestamp - r.samples[0].timestamp for s in r.samples]
                    vals = [s.memory_mb for s in r.samples]
                    color = ALGO_COLORS.get(algo, 'gray')
                    label = ALGO_LABELS.get(algo, algo)
                    ax.plot(times, vals, '-', label=label, color=color, linewidth=1.5)
            ax.axhline(y=CGROUP_MEM_HIGH, color='red', linestyle=':', alpha=0.5)
            ax.set_ylabel('memory.current (MB)')
            ax.set_title(f'All Algorithms @ {max_threads} threads: Memory Over Time')
            ax.legend(loc='lower right', fontsize=8)
            ax.grid(True, alpha=0.3)

            # 下图: swap.current
            ax = axes[1]
            for algo in algos:
                results = sorted(self.results[algo], key=lambda x: x.threads)
                r = next((x for x in reversed(results) if x.threads == max_threads and x.samples), None)
                if r:
                    times = [s.timestamp - r.samples[0].timestamp for s in r.samples]
                    vals = [s.swap_mb for s in r.samples]
                    color = ALGO_COLORS.get(algo, 'gray')
                    label = ALGO_LABELS.get(algo, algo)
                    ax.plot(times, vals, '-', label=label, color=color, linewidth=1.5)
            ax.axhline(y=SWAP_SIZE, color='red', linestyle=':', alpha=0.5)
            ax.set_xlabel('Time (s)')
            ax.set_ylabel('swap.current (MB)')
            ax.set_title(f'All Algorithms @ {max_threads} threads: Swap Over Time')
            ax.legend(loc='lower right', fontsize=8)
            ax.grid(True, alpha=0.3)

            fig.tight_layout()
            fig.savefig(output_dir / f'all_algos_t{max_threads}_timeline.png', dpi=150)
            plt.close(fig)

        # ---- 图10: llama-bench 多进程内存压力时间线 ----
        has_llama_phase = any(
            r.llama_samples for algo in algos for r in self.results[algo]
        )
        if has_llama_phase:
            fig, axes = plt.subplots(2, 1, figsize=(16, 12), sharex=True)

            ax = axes[0]
            for algo in algos:
                results = sorted(self.results[algo], key=lambda x: x.threads)
                for r in results:
                    if r.llama_samples:
                        times = [s.timestamp - r.llama_samples[0].timestamp
                                 for s in r.llama_samples]
                        mem_vals = [s.memory_mb for s in r.llama_samples]
                        color = ALGO_COLORS.get(algo, 'gray')
                        label = f"{ALGO_LABELS.get(algo, algo)} ({r.threads}T, {r.llama_instances}inst)"
                        ax.plot(times, mem_vals, '-', label=label, color=color, linewidth=1.5)
            ax.axhline(y=CGROUP_MEM_HIGH, color='red', linestyle=':', alpha=0.5,
                       label=f'cgroup high ({CGROUP_MEM_HIGH}MB)')
            ax.set_ylabel('memory.current (MB)')
            ax.set_title('llama-bench Multi-Instance: Memory Over Time')
            ax.legend(loc='lower right', fontsize=7)
            ax.grid(True, alpha=0.3)

            ax = axes[1]
            for algo in algos:
                results = sorted(self.results[algo], key=lambda x: x.threads)
                for r in results:
                    if r.llama_samples:
                        times = [s.timestamp - r.llama_samples[0].timestamp
                                 for s in r.llama_samples]
                        swap_vals = [s.swap_mb for s in r.llama_samples]
                        color = ALGO_COLORS.get(algo, 'gray')
                        label = f"{ALGO_LABELS.get(algo, algo)} ({r.threads}T, {r.llama_instances}inst)"
                        ax.plot(times, swap_vals, '-', label=label, color=color, linewidth=1.5)
            ax.axhline(y=SWAP_SIZE, color='red', linestyle=':', alpha=0.5,
                       label=f'swap limit ({SWAP_SIZE}MB)')
            ax.set_xlabel('Time (s)')
            ax.set_ylabel('swap.current (MB)')
            ax.set_title('llama-bench Multi-Instance: Swap Over Time')
            ax.legend(loc='lower right', fontsize=7)
            ax.grid(True, alpha=0.3)

            fig.tight_layout()
            fig.savefig(output_dir / 'llama_memory_pressure_timeline.png', dpi=150)
            plt.close(fig)

        # ---- 图11: llama-bench eval rate vs instances ----
        has_eval = any(
            r.llama_eval_rates for algo in algos for r in self.results[algo]
        )
        if has_eval:
            fig, ax = plt.subplots(figsize=(14, 8))
            for algo in algos:
                results = sorted(self.results[algo], key=lambda x: x.threads)
                ts = [r.threads for r in results if r.llama_eval_rates]
                rates = [sum(r.llama_eval_rates) / len(r.llama_eval_rates)
                         for r in results if r.llama_eval_rates]
                if ts:
                    color = ALGO_COLORS.get(algo, 'gray')
                    label = ALGO_LABELS.get(algo, algo)
                    ax.plot(ts, rates, 'o-', label=label, color=color, linewidth=2)
            ax.set_xlabel('Threads (total)')
            ax.set_ylabel('Avg Eval Rate (tokens/s per instance)')
            ax.set_title('llama-bench: Inference Throughput vs Memory Pressure')
            ax.legend(loc='upper right')
            ax.grid(True, alpha=0.3)
            fig.tight_layout()
            fig.savefig(output_dir / 'llama_eval_vs_threads.png', dpi=150)
            plt.close(fig)

        print(f"[INFO] Charts saved to {output_dir}")

    # ---- JSON 导出 ----
    def save_json(self, output_path: Path):
        data = {
            'generated_at': datetime.now().isoformat(),
            'results_dir': str(self.results_dir),
            'phase_thresholds': {
                'cgroup_high_mb': CGROUP_MEM_HIGH,
                'swap_size_mb': SWAP_SIZE,
            },
            'algorithms': {}
        }

        for algo in sorted(self.results.keys()):
            results = sorted(self.results[algo], key=lambda x: x.threads)
            data['algorithms'][algo] = {
                'label': ALGO_LABELS.get(algo, algo),
                'tests': []
            }

            for r in results:
                test_data = {
                    'threads': r.threads,
                    'total_mem_mb': r.total_mem_mb,
                    'expected_phase': r.expected_phase,
                    'numa_policy': r.numa_policy,
                    'peak_memory_mb': r.peak_memory_mb,
                    'peak_swap_mb': r.peak_swap_mb,
                    'compression_ratio': r.compression_ratio,
                    'zswap_delta_mb': r.zswap_delta_mb,
                    'total_throughput_kbps': r.total_throughput_kbps,
                    'avg_throughput_kbps': r.avg_throughput_kbps,
                    'alloc_elapsed_sec': r.alloc_elapsed_sec,
                    'user_time_sec': r.user_time_sec,
                    'sys_time_sec': r.sys_time_sec,
                    'wall_elapsed_sec': r.wall_elapsed_sec,
                    'cpu_user_pct': r.cpu_user_pct,
                    'cpu_sys_pct': r.cpu_sys_pct,
                    'cpu_idle_pct': r.cpu_idle_pct,
                    'child_user_sec': r.child_user_sec,
                    'child_sys_sec': r.child_sys_sec,
                    'business_pct': r.business_pct,
                    'compression_pct': r.compression_pct,
                    'llama_user_ms': r.llama_user_ms,
                    'llama_sys_ms': r.llama_sys_ms,
                    'llama_instances': r.llama_instances,
                    'llama_total_model_mem_mb': r.llama_total_model_mem_mb,
                    'llama_successful_instances': r.llama_successful_instances,
                    'llama_eval_rates': r.llama_eval_rates,
                    'llama_peak_memory_mb': r.llama_peak_memory_mb,
                    'llama_peak_swap_mb': r.llama_peak_swap_mb,
                    'throughput': r.throughput,
                    'latency': r.latency,
                    'num_samples': len(r.samples),
                    'num_llama_samples': len(r.llama_samples),
                    'zswap_post': r.zswap_post,
                }
                data['algorithms'][algo]['tests'].append(test_data)

        with open(output_path, 'w') as f:
            json.dump(data, f, indent=2, ensure_ascii=False)

        print(f"[INFO] JSON saved to {output_path}")


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 analyze_results.py <results_directory>")
        print("")
        print("Example:")
        print("  python3 analyze_results.py ../results/results_20260414_120000/")
        sys.exit(1)

    results_dir = Path(sys.argv[1])
    if not results_dir.exists():
        print(f"[ERROR] Directory not found: {results_dir}")
        sys.exit(1)

    print(f"[INFO] Analyzing: {results_dir}")

    analyzer = ZswapAnalyzer(results_dir)
    analyzer.load_results()

    if not analyzer.results:
        print("[ERROR] No results found")
        sys.exit(1)

    # 生成文本报告
    report = analyzer.generate_report()
    print(report)

    report_file = results_dir / 'analysis_report.txt'
    report_file.write_text(report)
    print(f"\n[INFO] Report saved to {report_file}")

    # 生成图表
    if HAS_MATPLOTLIB:
        analyzer.plot_results(results_dir)

    # 保存 JSON
    analyzer.save_json(results_dir / 'results.json')


if __name__ == '__main__':
    main()
