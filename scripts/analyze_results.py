#!/usr/bin/env python3
"""
analyze_results.py - Zswap 性能结果分析脚本
分析测试结果，生成线性度报告和性能对比图表
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
    matplotlib.use('Agg')  # 无头模式
    import matplotlib.pyplot as plt
    HAS_MATPLOTLIB = True
except ImportError:
    HAS_MATPLOTLIB = False
    print("[WARN] matplotlib not installed, charts will not be generated")


class ZswapResult:
    """单次测试结果"""
    def __init__(self, algo: str, threads: int):
        self.algo = algo
        self.threads = threads
        self.throughput = None  # tokens/s
        self.latency = None  # ms
        self.compression_ratio = None
        self.stored_pages = None
        self.compressed_pages = None
        self.cache_misses = None
        self.cache_references = None


class ZswapAnalyzer:
    """Zswap 结果分析器"""
    
    def __init__(self, results_dir: str):
        self.results_dir = Path(results_dir)
        self.results: Dict[str, List[ZswapResult]] = {}
        
    def parse_bench_log(self, filepath: Path) -> Optional[ZswapResult]:
        """解析基准测试日志"""
        if not filepath.exists():
            return None
            
        content = filepath.read_text()
        
        # 从文件名提取参数
        filename = filepath.stem  # bench_algo_tN
        parts = filename.split('_')
        if len(parts) >= 3:
            algo = parts[1]
            threads = int(parts[2].replace('t', ''))
        else:
            return None
        
        result = ZswapResult(algo, threads)
        
        # 提取吞吐量
        match = re.search(r'tokens per second:\s*([\d.]+)', content)
        if match:
            result.throughput = float(match.group(1))
        
        # 提取延迟
        match = re.search(r'eval time:\s*([\d.]+)', content)
        if match:
            result.latency = float(match.group(1))
            
        return result
    
    def parse_zswap_log(self, filepath: Path) -> Optional[Tuple[int, int]]:
        """解析 zswap 日志"""
        if not filepath.exists():
            return None
            
        content = filepath.read_text()
        
        stored = None
        compressed = None
        
        match = re.search(r'stored_pages\s+(\d+)', content)
        if match:
            stored = int(match.group(1))
            
        match = re.search(r'compressed_pages\s+(\d+)', content)
        if match:
            compressed = int(match.group(1))
            
        return (stored, compressed)
    
    def load_results(self):
        """加载所有测试结果"""
        bench_files = sorted(self.results_dir.glob("bench_*.log"))
        zswap_files = sorted(self.results_dir.glob("zswap_*.log"))
        
        # 按算法分组
        for bench_file in bench_files:
            result = self.parse_bench_log(bench_file)
            if result:
                if result.algo not in self.results:
                    self.results[result.algo] = []
                self.results[result.algo].append(result)
        
        # 解析压缩比
        for zswap_file in zswap_files:
            stored, compressed = self.parse_zswap_log(zswap_file)
            if stored and compressed:
                filename = zswap_file.stem
                parts = filename.split('_')
                if len(parts) >= 3:
                    algo = parts[1]
                    threads = int(parts[2].replace('t', ''))
                    
                    # 找到对应的结果
                    for result in self.results.get(algo, []):
                        if result.threads == threads:
                            result.stored_pages = stored
                            result.compressed_pages = compressed
                            if compressed > 0:
                                result.compression_ratio = stored / compressed
    
    def calculate_linearity(self, algo: str) -> Dict[int, float]:
        """
        计算线性度
        理想情况: 线程翻倍 -> 吞吐量翻倍
        实际效率 = (throughput_N / throughput_1) / N * 100%
        """
        if algo not in self.results:
            return {}
            
        results = sorted(self.results[algo], key=lambda x: x.threads)
        if not results or results[0].throughput is None:
            return {}
            
        baseline = results[0].throughput
        linearity = {}
        
        for r in results:
            if r.throughput and baseline > 0:
                expected = baseline * r.threads
                actual_ratio = r.throughput / baseline
                efficiency = (actual_ratio / r.threads) * 100 if r.threads > 0 else 0
                linearity[r.threads] = {
                    'throughput': r.throughput,
                    'expected': expected,
                    'actual_ratio': actual_ratio,
                    'efficiency': efficiency
                }
        
        return linearity
    
    def generate_report(self) -> str:
        """生成文本报告"""
        lines = []
        lines.append("=" * 60)
        lines.append("  Zswap Performance Analysis Report")
        lines.append("=" * 60)
        lines.append(f"Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
        lines.append(f"Results Dir: {self.results_dir}")
        lines.append("")
        
        for algo in sorted(self.results.keys()):
            results = sorted(self.results[algo], key=lambda x: x.threads)
            
            lines.append("-" * 60)
            lines.append(f"Algorithm: {algo.upper()}")
            lines.append("-" * 60)
            lines.append("")
            lines.append(f"{'Threads':<10} {'Throughput':<15} {'Latency':<12} {'Compr.Ratio':<15} {'Efficiency':<12}")
            lines.append(f"{'':10} {'(tokens/s)':<15} {'(ms)':<12} {'(stored/comp)':<15} {'(%)':<12}")
            lines.append("-" * 60)
            
            baseline = results[0].throughput if results else None
            
            for r in results:
                efficiency = ""
                if r.throughput and baseline and baseline > 0:
                    actual_ratio = r.throughput / baseline
                    eff = (actual_ratio / r.threads) * 100 if r.threads > 0 else 0
                    efficiency = f"{eff:.1f}%"
                
                throughput = f"{r.throughput:.1f}" if r.throughput else "N/A"
                latency = f"{r.latency:.1f}" if r.latency else "N/A"
                ratio = f"{r.compression_ratio:.2f}x" if r.compression_ratio else "N/A"
                
                lines.append(f"{r.threads:<10} {throughput:<15} {latency:<12} {ratio:<15} {efficiency:<12}")
            
            lines.append("")
            
            # 线性度分析
            linearity = self.calculate_linearity(algo)
            if linearity:
                lines.append("Linear Scaling Analysis:")
                lines.append(f"  Baseline (1 thread): {baseline:.1f} tokens/s" if baseline else "")
                
                for threads, data in linearity.items():
                    if threads > 1:
                        status = "✓" if data['efficiency'] > 80 else "⚠" if data['efficiency'] > 50 else "✗"
                        lines.append(f"  {threads} threads: {data['throughput']:.1f} tok/s "
                                  f"(eff={data['efficiency']:.1f}%) {status}")
                
                # 找出饱和点
                for i in range(len(results) - 1):
                    curr_eff = linearity.get(results[i].threads, {}).get('efficiency', 100)
                    next_eff = linearity.get(results[i+1].threads, {}).get('efficiency', 100)
                    if next_eff < curr_eff - 10:  # 效率下降超过10%
                        lines.append(f"  ⚠ Saturation point detected around {results[i+1].threads} threads")
                        break
            
            lines.append("")
        
        return "\n".join(lines)
    
    def plot_results(self, output_dir: Path):
        """生成性能图表"""
        if not HAS_MATPLOTLIB:
            return
            
        if not self.results:
            print("[WARN] No results to plot")
            return
        
        algos = sorted(self.results.keys())
        colors = {'lz4': 'blue', 'lzo': 'green', 'zstd': 'red'}
        
        # 图1: 吞吐量 vs 线程数
        plt.figure(figsize=(10, 6))
        for algo in algos:
            results = sorted(self.results[algo], key=lambda x: x.threads)
            threads = [r.threads for r in results if r.throughput]
            throughputs = [r.throughput for r in results if r.throughput]
            color = colors.get(algo, 'gray')
            plt.plot(threads, throughputs, 'o-', label=algo, color=color, linewidth=2)
            
            # 理想线性线
            if results and results[0].throughput:
                baseline = results[0].throughput
                ideal = [baseline * t for t in threads]
                plt.plot(threads, ideal, '--', color=color, alpha=0.3, label=f'{algo} (ideal)')
        
        plt.xlabel('Number of Threads')
        plt.ylabel('Throughput (tokens/s)')
        plt.title('Zswap Performance: Throughput vs Threads')
        plt.legend()
        plt.grid(True, alpha=0.3)
        plt.savefig(output_dir / 'throughput_vs_threads.png', dpi=150)
        plt.close()
        
        # 图2: 压缩比对比
        plt.figure(figsize=(10, 6))
        x = range(len(algos))
        ratios = []
        for algo in algos:
            results = sorted(self.results[algo], key=lambda r: r.threads)
            ratio = results[0].compression_ratio if results else 0
            ratios.append(ratio)
        
        plt.bar(x, ratios, color=[colors.get(a, 'gray') for a in algos])
        plt.xticks(x, [a.upper() for a in algos])
        plt.ylabel('Compression Ratio')
        plt.title('Zswap Compression Ratio by Algorithm')
        plt.savefig(output_dir / 'compression_ratio.png', dpi=150)
        plt.close()
        
        # 图3: 线性效率
        plt.figure(figsize=(10, 6))
        for algo in algos:
            linearity = self.calculate_linearity(algo)
            if linearity:
                threads = sorted(linearity.keys())
                efficiencies = [linearity[t]['efficiency'] for t in threads]
                plt.plot(threads, efficiencies, 'o-', label=algo, 
                        color=colors.get(algo, 'gray'), linewidth=2)
        
        plt.axhline(y=100, color='black', linestyle='--', alpha=0.5, label='Ideal (100%)')
        plt.axhline(y=80, color='green', linestyle=':', alpha=0.5, label='Good (80%)')
        plt.xlabel('Number of Threads')
        plt.ylabel('Scaling Efficiency (%)')
        plt.title('Zswap Linear Scaling Efficiency')
        plt.legend()
        plt.grid(True, alpha=0.3)
        plt.savefig(output_dir / 'scaling_efficiency.png', dpi=150)
        plt.close()
        
        print(f"[INFO] Charts saved to {output_dir}")
    
    def save_json(self, output_path: Path):
        """保存 JSON 格式结果"""
        data = {
            'generated_at': datetime.now().isoformat(),
            'results_dir': str(self.results_dir),
            'algorithms': {}
        }
        
        for algo in sorted(self.results.keys()):
            data['algorithms'][algo] = {
                'linearity': self.calculate_linearity(algo),
                'tests': []
            }
            
            for r in sorted(self.results[algo], key=lambda x: x.threads):
                test_data = {
                    'threads': r.threads,
                    'throughput': r.throughput,
                    'latency': r.latency,
                    'compression_ratio': r.compression_ratio
                }
                data['algorithms'][algo]['tests'].append(test_data)
        
        with open(output_path, 'w') as f:
            json.dump(data, f, indent=2)
        
        print(f"[INFO] JSON results saved to {output_path}")


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 analyze_results.py <results_directory>")
        sys.exit(1)
    
    results_dir = Path(sys.argv[1])
    if not results_dir.exists():
        print(f"[ERROR] Directory not found: {results_dir}")
        sys.exit(1)
    
    analyzer = ZswapAnalyzer(results_dir)
    analyzer.load_results()
    
    # 生成报告
    report = analyzer.generate_report()
    print(report)
    
    # 保存报告
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
