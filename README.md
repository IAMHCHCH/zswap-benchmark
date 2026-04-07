# Zswap Performance Benchmark

Linux kernel zswap 压缩算法性能对比测试工具，对比 **lz4 / lzo / zstd** 在不同线程数下的性能线性变化。

## 功能特性

- 支持 lz4、lzo、zstd 三种压缩算法对比
- 可配置内存限制（cgroup）
- 线程数 1-16 线性扩展测试
- LLM 推理场景模拟（基于 llama.cpp）
- 自动生成性能报告和线性度分析

## 目录结构

```
zswap-benchmark/
├── scripts/
│   ├── zswap_benchmark.sh      # 主测试脚本
│   ├── analyze_results.py       # Python 分析脚本
│   └── setup_env.sh            # 环境初始化
├── docs/
│   └── test_plan.md            # 测试计划文档
├── results/                    # 测试结果输出目录
├── .gitignore
├── LICENSE
└── README.md
```

## 快速开始

### 1. 环境准备

```bash
# 克隆项目
git clone https://github.com/IAMHCHCH/zswap-benchmark.git
cd zswap-benchmark

# 安装依赖
chmod +x scripts/setup_env.sh
sudo ./scripts/setup_env.sh

# 编译 llama.cpp
git clone --depth 1 https://github.com/ggml-org/llama.cpp.git /tmp/llama.cpp
cd /tmp/llama.cpp && make llama-bench
sudo cp llama-bench /usr/local/bin/
```

### 2. 配置测试参数

编辑 `scripts/zswap_benchmark.sh` 中的配置：

```bash
MEM_LIMIT="4G"          # 内存限制: 2G, 4G, 8G, 16G
THREADS="1 2 4 8 12 16" # 线程数
ALGOS="lz4 lzo zstd"   # 压缩算法
MODEL="models/qwen-7b.gguf"  # 测试模型路径
PROMPT_LEN=512
GEN_LEN=128
ITERATIONS=3
```

### 3. 运行测试

```bash
cd scripts
chmod +x zswap_benchmark.sh analyze_results.py
sudo ./zswap_benchmark.sh
```

### 4. 分析结果

```bash
# 查看汇总报告
cat ../results/summary_*.txt

# Python 分析（生成图表）
python3 analyze_results.py ../results/
```

## 测试矩阵

| 参数 | 选项 |
|------|------|
| 压缩算法 | lz4, lzo, zstd |
| 内存限制 | 2GB, 4GB, 8GB, 16GB |
| 线程数 | 1, 2, 4, 8, 12, 16, 32 |
| 测试模型 | Qwen-7B, Llama-7B, Mistral-7B 等 GGUF 格式 |

## 输出指标

- **吞吐量**: tokens/s
- **延迟**: P50, P95, P99 (ms)
- **压缩比**: stored_pages / compressed_pages
- **CPU 开销**: 压缩/解压缩 CPU 占用率
- **内存带宽**: cache-misses, cache-references

## 线性度分析

```
理想情况: 线程翻倍 → 吞吐量翻倍
实际效率 = (throughput_N / throughput_1) / N × 100%

效率下降拐点 → 内存带宽饱和点
```

## 预期结果

| 算法 | 压缩比 | 压缩速度 | 适用场景 |
|------|--------|----------|----------|
| lz4 | ~1.8x | 最快 | 高吞吐、低延迟优先 |
| lzo | ~2.0x | 中等 | 平衡场景 |
| zstd | ~2.8x | 较慢 | 内存紧张、压缩比优先 |

## 注意事项

1. 测试会修改系统 zswap 参数，需要 root 权限
2. 建议在测试前备份重要数据
3. 使用 cgroup 隔离测试进程
4. 首次测试建议从较高内存限制开始

## License

MIT