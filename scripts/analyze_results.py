#!/usr/bin/env python3
"""
analyze_results.py - Zswap 性能结果分析脚本
分析 stress-ng / llama-bench / zswap debug 统计，生成对比报告和图表
"""

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


class ZswapResult:
    """单次测试结果"""
    def __init__(self, algo: str, threads: int):
        self.algo = algo
        self.threads = threads
        # llama-bench 指标
        self.throughput = None      # tokens/s
        self.latency = None         # ms
        # stress-ng 指标
        self.stress_bogo = None     # bogo ops/s
        self.stress_time = None     # 实际运行时间
        # zswap 指标
        self.stored_pages = None
        self.compressed_pages = None
        self.compression_ratio = None
        self.pool_total_size = None
        self.pool_limit_hit = None
        self.reject_compress_poor = None
        self.reject_alloc_fail = None
        self.reject_kmemcache_fail = None
        # memory info
        self.mem_used = None        # 测试期间内存使用量


class ZswapAnalyzer:
    """Zswap 结果分析器"""

    def __init__(self, results_dir: str):
        self.results_dir = Path(results_dir)
        self.results: Dict[str, List[ZswapResult]] = {}

    # ---- 解析 stress-ng 输出 ----
    def parse_memtest_log(self, filepath: Path) -> Optional[ZswapResult]:
        if not filepath.exists():
            return None

        content = filepath.read_text()

        # 从文件名提取参数: memtest_algo_tN.log
        filename = filepath.stem
        parts = filename.split('_')
        if len(parts) < 3:
            return None
        algo = parts[1]
        threads = int(parts[2].replace('t', ''))

        result = ZswapResult(algo, threads)

        # stress-ng 输出格式:
        # stress-ng ... run completed in X.XX seconds
        # stress-ng ... XX.XX bogo ops/s
        match = re.search(r'(\d+\.\d+)\s+bogo ops/s', content)
        if match:
            result.stress_bogo = float(match.group(1))

        match = re.search(r'run completed in\s+(\d+\.\d+)\s+seconds', content)
        if match:
            result.stress_time = float(match.group(1))

        return result

    # ---- 解析 llama-bench 输出 ----
    def parse_bench_log(self, filepath: Path) -> Optional[ZswapResult]:
        if not filepath.exists():
            return None

        content = filepath.read_text()
        filename = filepath.stem
        parts = filename.split('_')
        if len(parts) < 3:
            return None
        algo = parts[1]
        threads = int(parts[2].replace('t', ''))

        result = ZswapResult(algo, threads)

        match = re.search(r'tokens per second:\s*([\d.]+)', content)
        if match:
            result.throughput = float(match.group(1))

        match = re.search(r'eval time:\s*([\d.]+)', content)
        if match:
            result.latency = float(match.group(1))

        return result

    # ---- 解析 zswap debug 统计 ----
    def parse_zswap_log(self, filepath: Path):
        if not filepath.exists():
            return

        content = filepath.read_text()
        filename = filepath.stem
        parts = filename.split('_')
        if len(parts) < 3:
            return
        algo = parts[1]
        threads = int(parts[2].replace('t', ''))

        # 查找或创建对应 result
        result = self._find_or_create(algo, threads)

        # stored_pages / compressed_pages -> 压缩比
        stored = self._extract_int(r'stored_pages\s+(\d+)', content)
        compressed = self._extract_int(r'compressed_pages\s+(\d+)', content)
        if stored is not None:
            result.stored_pages = stored
        if compressed is not None:
            result.compressed_pages = compressed
        if stored and compressed and compressed > 0:
            result.compression_ratio = stored / compressed

        # pool_total_size
        pool_size = self._extract_int(r'pool_total_size\s+(\d+)', content)
        if pool_size is not None:
            result.pool_total_size = pool_size

        # pool_limit_hit
        result.pool_limit_hit = self._extract_int(r'pool_limit_hit\s+(\d+)', content)

        # reject counters
        result.reject_compress_poor = self._extract_int(
            r'reject_compress_poor\s+(\d+)', content)
        result.reject_alloc_fail = self._extract_int(
            r'reject_alloc_fail\s+(\d+)', content)
        result.reject_kmemcache_fail = self._extract_int(
            r'reject_kmemcache_fail\s+(\d+)', content)

        # memory used
        mem_avail_before = self._extract_int(r'MemAvailable:\s+(\d+)', content)
        if mem_avail_before:
            # 从 MemTotal 估算使用量
            mem_total = self._extract_int(r'MemTotal:\s+(\d+)', content)
            if mem_total:
                result.mem_used = mem_total - mem_avail_before

    def _extract_int(self, pattern: str, text: str) -> Optional[int]:
        match = re.search(pattern, text)
        return int(match.group(1)) if match else None

    def _find_or_create(self, algo: str, threads: int) -> ZswapResult:
        if algo not in self.results:
            self.results[algo] = []
        for r in self.results[algo]:
            if r.threads == threads:
                return r
        r = ZswapResult(algo, threads)
        self.results[algo].append(r)
        return r

    # ---- 加载所有结果 ----
    def load_results(self):
        # memtest
        for f in sorted(self.results_dir.glob("memtest_*.log")):
            result = self.parse_memtest_log(f)
            if result:
                self._merge_result(result)

        # bench (llama-bench)
        for f in sorted(self.results_dir.glob("bench_*.log")):
            result = self.parse_bench_log(f)
            if result:
                self._merge_result(result)

        # zswap debug stats (补充到已有 result 上)
        for f in sorted(self.results_dir.glob("zswap_*.log")):
            self.parse_zswap_log(f)

    def _merge_result(self, result: ZswapResult):
        algo = result.algo
        if algo not in self.results:
            self.results[algo] = []
        # 查找已有同 algo+threads 的 result
        for r in self.results[algo]:
            if r.threads == result.threads:
                # 补充数据
                if result.throughput is not None:
                    r.throughput = result.throughput
                if result.latency is not None:
                    r.latency = result.latency
                if result.stress_bogo is not None:
                    r.stress_bogo = result.stress_bogo
                if result.stress_time is not None:
                    r.stress_time = result.stress_time
                return
        self.results[algo].append(result)

    # ---- 计算线性效率 ----
    def calculate_linearity(self, algo: str, metric: str = 'auto') -> Dict:
        if algo not in self.results:
            return {}

        results = sorted(self.results[algo], key=lambda x: x.threads)

        # 选择度量指标
        def get_metric(r):
            if metric == 'throughput' or (metric == 'auto' and r.throughput):
                return r.throughput
            if metric == 'bogo' or (metric == 'auto' and r.stress_bogo):
                return r.stress_bogo
            return None

        values = [(r.threads, get_metric(r)) for r in results]
        baseline_val = None
        for _, v in values:
            if v is not None:
                baseline_val = v
                break

        if baseline_val is None or baseline_val == 0:
            return {}

        linearity = {}
        for r in results:
            v = get_metric(r)
            if v is not None and r.threads > 0:
                actual_ratio = v / baseline_val
                efficiency = (actual_ratio / r.threads) * 100
                linearity[r.threads] = {
                    'value': v,
                    'expected': baseline_val * r.threads,
                    'actual_ratio': round(actual_ratio, 2),
                    'efficiency': round(efficiency, 1),
                }
        return linearity

    # ---- 文本报告 ----
    def generate_report(self) -> str:
        lines = []
        lines.append("=" * 70)
        lines.append("  Zswap Performance Analysis Report")
        lines.append("=" * 70)
        lines.append(f"Generated:    {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
        lines.append(f"Results Dir:  {self.results_dir}")
        lines.append(f"Algorithms:   {', '.join(sorted(self.results.keys()))}")
        lines.append("")

        # ---- 1. 压缩比对比 ----
        lines.append("=" * 70)
        lines.append("  1. 压缩比对比 (Compression Ratio)")
        lines.append("=" * 70)
        lines.append("")
        lines.append(f"{'Algorithm':<18} {'Threads':<10} {'Stored Pages':<15} "
                     f"{'Compressed Pages':<18} {'Ratio':<10}")
        lines.append("-" * 70)

        for algo in sorted(self.results.keys()):
            results = sorted(self.results[algo], key=lambda x: x.threads)
            label = ALGO_LABELS.get(algo, algo)
            for r in results:
                stored = f"{r.stored_pages}" if r.stored_pages else "N/A"
                compressed = f"{r.compressed_pages}" if r.compressed_pages else "N/A"
                ratio = f"{r.compression_ratio:.2f}x" if r.compression_ratio else "N/A"
                lines.append(f"{label:<18} {r.threads:<10} {stored:<15} "
                             f"{compressed:<18} {ratio:<10}")
            lines.append("")

        # ---- 2. Zswap Pool 统计 ----
        lines.append("=" * 70)
        lines.append("  2. Zswap Pool 统计")
        lines.append("=" * 70)
        lines.append("")
        lines.append(f"{'Algorithm':<18} {'Threads':<10} {'Pool Size':<15} "
                     f"{'Limit Hit':<12} {'Rej(Poor)':<12} {'Rej(Alloc)':<12}")
        lines.append("-" * 70)

        for algo in sorted(self.results.keys()):
            results = sorted(self.results[algo], key=lambda x: x.threads)
            label = ALGO_LABELS.get(algo, algo)
            for r in results:
                pool = f"{r.pool_total_size}" if r.pool_total_size else "N/A"
                limit_hit = f"{r.pool_limit_hit}" if r.pool_limit_hit is not None else "N/A"
                rej_poor = f"{r.reject_compress_poor}" if r.reject_compress_poor is not None else "N/A"
                rej_alloc = f"{r.reject_alloc_fail}" if r.reject_alloc_fail is not None else "N/A"
                lines.append(f"{label:<18} {r.threads:<10} {pool:<15} "
                             f"{limit_hit:<12} {rej_poor:<12} {rej_alloc:<12}")
            lines.append("")

        # ---- 3. 性能指标 (stress-ng / llama-bench) ----
        lines.append("=" * 70)
        lines.append("  3. 性能指标")
        lines.append("=" * 70)

        # 检测哪种测试数据可用
        has_bogo = any(r.stress_bogo for algo in self.results.values() for r in algo)
        has_tps = any(r.throughput for algo in self.results.values() for r in algo)

        if has_bogo:
            lines.append("")
            lines.append("  [stress-ng bogo ops/s]")
            lines.append(f"{'Algorithm':<18} {'Threads':<10} {'Bogo ops/s':<15} "
                         f"{'Efficiency':<12} {'Time(s)':<10}")
            lines.append("-" * 70)

            for algo in sorted(self.results.keys()):
                results = sorted(self.results[algo], key=lambda x: x.threads)
                label = ALGO_LABELS.get(algo, algo)
                linearity = self.calculate_linearity(algo, 'bogo')
                for r in results:
                    bogo = f"{r.stress_bogo:.2f}" if r.stress_bogo else "N/A"
                    eff = ""
                    if r.threads in linearity:
                        eff = f"{linearity[r.threads]['efficiency']:.1f}%"
                    t = f"{r.stress_time:.2f}" if r.stress_time else "N/A"
                    lines.append(f"{label:<18} {r.threads:<10} {bogo:<15} "
                                 f"{eff:<12} {t:<10}")
                lines.append("")

        if has_tps:
            lines.append("")
            lines.append("  [llama-bench tokens/s]")
            lines.append(f"{'Algorithm':<18} {'Threads':<10} {'Tokens/s':<15} "
                         f"{'Latency(ms)':<12} {'Efficiency':<12}")
            lines.append("-" * 70)

            for algo in sorted(self.results.keys()):
                results = sorted(self.results[algo], key=lambda x: x.threads)
                label = ALGO_LABELS.get(algo, algo)
                linearity = self.calculate_linearity(algo, 'throughput')
                for r in results:
                    tps = f"{r.throughput:.1f}" if r.throughput else "N/A"
                    lat = f"{r.latency:.1f}" if r.latency else "N/A"
                    eff = ""
                    if r.threads in linearity:
                        eff = f"{linearity[r.threads]['efficiency']:.1f}%"
                    lines.append(f"{label:<18} {r.threads:<10} {tps:<15} "
                                 f"{lat:<12} {eff:<12}")
                lines.append("")

        # ---- 4. 线性效率分析 ----
        lines.append("=" * 70)
        lines.append("  4. 线性效率分析")
        lines.append("=" * 70)
        lines.append("")

        metric = 'bogo' if has_bogo else ('throughput' if has_tps else None)
        if metric:
            metric_name = "bogo ops/s" if metric == 'bogo' else "tokens/s"
            lines.append(f"  度量指标: {metric_name}")
            lines.append(f"  理想效率: 线程翻倍 -> 性能翻倍 (100%)")
            lines.append("")

            for algo in sorted(self.results.keys()):
                label = ALGO_LABELS.get(algo, algo)
                linearity = self.calculate_linearity(algo, metric)
                if not linearity:
                    continue
                lines.append(f"  {label}:")
                for threads in sorted(linearity.keys()):
                    d = linearity[threads]
                    mark = "OK" if d['efficiency'] >= 80 else ("--" if d['efficiency'] >= 50 else "!!")
                    lines.append(f"    {threads:>3} threads: {d['value']:>10.2f}  "
                                 f"eff={d['efficiency']:>5.1f}%  {mark}")
                # 饱和点
                sorted_threads = sorted(linearity.keys())
                for i in range(len(sorted_threads) - 1):
                    t1, t2 = sorted_threads[i], sorted_threads[i + 1]
                    e1 = linearity[t1]['efficiency']
                    e2 = linearity[t2]['efficiency']
                    if e2 < e1 - 10:
                        lines.append(f"    >> 饱和点: ~{t2} threads (效率从 {e1:.1f}% 降至 {e2:.1f}%)")
                        break
                lines.append("")
        else:
            lines.append("  (无性能数据可用于线性分析)")

        lines.append("=" * 70)
        return "\n".join(lines)

    # ---- 图表生成 ----
    def plot_results(self, output_dir: Path):
        if not HAS_MATPLOTLIB or not self.results:
            return

        output_dir = Path(output_dir)

        # 检测可用指标
        has_bogo = any(r.stress_bogo for algo in self.results.values() for r in algo)
        has_tps = any(r.throughput for algo in self.results.values() for r in algo)
        has_ratio = any(r.compression_ratio for algo in self.results.values() for r in algo)

        algos = sorted(self.results.keys())

        # ---- 图1: 性能 vs 线程数 ----
        metric = None
        metric_label = ""
        if has_bogo:
            metric = 'stress_bogo'
            metric_label = 'Bogo ops/s (stress-ng)'
        elif has_tps:
            metric = 'throughput'
            metric_label = 'Tokens/s (llama-bench)'

        if metric:
            fig, ax = plt.subplots(figsize=(12, 7))
            for algo in algos:
                results = sorted(self.results[algo], key=lambda x: x.threads)
                threads = []
                values = []
                for r in results:
                    v = getattr(r, metric)
                    if v is not None:
                        threads.append(r.threads)
                        values.append(v)
                if threads:
                    color = ALGO_COLORS.get(algo, 'gray')
                    label = ALGO_LABELS.get(algo, algo)
                    ax.plot(threads, values, 'o-', label=label, color=color, linewidth=2)

            # 理想线性参考线 (取第一个算法的基线)
            first_algo = algos[0]
            first_results = sorted(self.results[first_algo], key=lambda x: x.threads)
            baseline_val = None
            for r in first_results:
                v = getattr(r, metric)
                if v is not None:
                    baseline_val = v
                    break
            if baseline_val:
                all_threads = sorted(set(
                    t for algo in self.results for r in self.results[algo] for t in [r.threads]
                ))
                ideal = [baseline_val * t for t in all_threads]
                ax.plot(all_threads, ideal, 'k--', alpha=0.3, label='Ideal (linear)', linewidth=1)

            ax.set_xlabel('Threads')
            ax.set_ylabel(metric_label)
            ax.set_title('Zswap Benchmark: Performance vs Threads')
            ax.legend(loc='upper left')
            ax.grid(True, alpha=0.3)
            fig.tight_layout()
            fig.savefig(output_dir / 'performance_vs_threads.png', dpi=150)
            plt.close(fig)

        # ---- 图2: 压缩比柱状图 ----
        if has_ratio:
            fig, ax = plt.subplots(figsize=(10, 6))
            labels = []
            ratios = []
            colors = []
            for algo in algos:
                results = sorted(self.results[algo], key=lambda x: x.threads)
                # 取中间线程数的压缩比
                mid = len(results) // 2
                if results and results[mid].compression_ratio:
                    labels.append(ALGO_LABELS.get(algo, algo))
                    ratios.append(results[mid].compression_ratio)
                    colors.append(ALGO_COLORS.get(algo, 'gray'))

            if ratios:
                bars = ax.bar(range(len(labels)), ratios, color=colors)
                ax.set_xticks(range(len(labels)))
                ax.set_xticklabels(labels, rotation=15)
                ax.set_ylabel('Compression Ratio (stored/compressed)')
                ax.set_title('Zswap Compression Ratio by Algorithm')
                for bar, ratio in zip(bars, ratios):
                    ax.text(bar.get_x() + bar.get_width() / 2, bar.get_height() + 0.02,
                            f'{ratio:.2f}x', ha='center', va='bottom', fontsize=10)
                ax.grid(True, alpha=0.3, axis='y')
                fig.tight_layout()
                fig.savefig(output_dir / 'compression_ratio.png', dpi=150)
                plt.close(fig)

        # ---- 图3: 线性效率 ----
        if metric:
            linearity_metric = 'bogo' if has_bogo else 'throughput'
            fig, ax = plt.subplots(figsize=(12, 7))
            for algo in algos:
                linearity = self.calculate_linearity(algo, linearity_metric)
                if linearity:
                    threads = sorted(linearity.keys())
                    effs = [linearity[t]['efficiency'] for t in threads]
                    color = ALGO_COLORS.get(algo, 'gray')
                    label = ALGO_LABELS.get(algo, algo)
                    ax.plot(threads, effs, 'o-', label=label, color=color, linewidth=2)

            ax.axhline(y=100, color='black', linestyle='--', alpha=0.4, label='Ideal (100%)')
            ax.axhline(y=80, color='green', linestyle=':', alpha=0.5, label='Good (80%)')
            ax.axhline(y=50, color='orange', linestyle=':', alpha=0.5, label='Fair (50%)')
            ax.set_xlabel('Threads')
            ax.set_ylabel('Scaling Efficiency (%)')
            ax.set_title('Zswap Benchmark: Linear Scaling Efficiency')
            ax.legend(loc='lower left')
            ax.grid(True, alpha=0.3)
            ax.set_ylim(0, 110)
            fig.tight_layout()
            fig.savefig(output_dir / 'scaling_efficiency.png', dpi=150)
            plt.close(fig)

        # ---- 图4: 硬件 vs 软件对比 (deflate) ----
        if 'deflate' in self.results and 'deflate-sw' in self.results:
            fig, axes = plt.subplots(1, 2, figsize=(16, 6))

            # 性能对比
            ax = axes[0]
            for algo, label, color in [('deflate-sw', 'Deflate (sw)', ALGO_COLORS['deflate-sw']),
                                        ('deflate', 'Deflate (HW)', ALGO_COLORS['deflate'])]:
                results = sorted(self.results[algo], key=lambda x: x.threads)
                if metric:
                    threads = []
                    values = []
                    for r in results:
                        v = getattr(r, metric)
                        if v is not None:
                            threads.append(r.threads)
                            values.append(v)
                    if threads:
                        ax.plot(threads, values, 'o-', label=label, color=color, linewidth=2)
            ax.set_xlabel('Threads')
            ax.set_ylabel(metric_label)
            ax.set_title('Deflate: Hardware vs Software (Performance)')
            ax.legend()
            ax.grid(True, alpha=0.3)

            # 压缩比对比
            ax = axes[1]
            for algo, label, color in [('deflate-sw', 'Deflate (sw)', ALGO_COLORS['deflate-sw']),
                                        ('deflate', 'Deflate (HW)', ALGO_COLORS['deflate'])]:
                results = sorted(self.results[algo], key=lambda x: x.threads)
                threads = []
                ratios = []
                for r in results:
                    if r.compression_ratio is not None:
                        threads.append(r.threads)
                        ratios.append(r.compression_ratio)
                if threads:
                    ax.plot(threads, ratios, 'o-', label=label, color=color, linewidth=2)
            ax.set_xlabel('Threads')
            ax.set_ylabel('Compression Ratio')
            ax.set_title('Deflate: Hardware vs Software (Compression Ratio)')
            ax.legend()
            ax.grid(True, alpha=0.3)

            fig.tight_layout()
            fig.savefig(output_dir / 'hw_vs_sw_deflate.png', dpi=150)
            plt.close(fig)

        print(f"[INFO] Charts saved to {output_dir}")

    # ---- JSON 导出 ----
    def save_json(self, output_path: Path):
        data = {
            'generated_at': datetime.now().isoformat(),
            'results_dir': str(self.results_dir),
            'algorithms': {}
        }

        for algo in sorted(self.results.keys()):
            results = sorted(self.results[algo], key=lambda x: x.threads)
            metric = 'bogo' if any(r.stress_bogo for r in results) else 'throughput'
            data['algorithms'][algo] = {
                'label': ALGO_LABELS.get(algo, algo),
                'linearity': self.calculate_linearity(algo, metric),
                'tests': []
            }

            for r in results:
                test_data = {
                    'threads': r.threads,
                    'throughput': r.throughput,
                    'latency': r.latency,
                    'stress_bogo_ops': r.stress_bogo,
                    'stress_time': r.stress_time,
                    'compression_ratio': r.compression_ratio,
                    'stored_pages': r.stored_pages,
                    'compressed_pages': r.compressed_pages,
                    'pool_total_size': r.pool_total_size,
                    'pool_limit_hit': r.pool_limit_hit,
                    'reject_compress_poor': r.reject_compress_poor,
                    'reject_alloc_fail': r.reject_alloc_fail,
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
