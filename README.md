# Zswap Performance Benchmark

Linux kernel zswap 压缩算法性能对比测试工具，对比 **lz4 / deflate(sw) / lzo / zstd / deflate(hw)** 在不同线程数下的性能表现。

## 功能特性

- 支持 5 种压缩配置对比：lz4、deflate(软件)、lzo、zstd、deflate(硬件 HiSilicon ZIP)
- 每线程固定 256MB 内存分配，随线程增长自然触发三阶段内存压力
- 三阶段观测：**无 swap → zswap 压缩 → swap 满载**
- cgroup v2 隔离测试进程，精确控制内存上限
- 独立 swapfile 管理，可配置大小和优先级
- 逐秒采样 memory/swap/zswap 指标，生成完整时间线数据
- 硬件加速器 NUMA 亲和绑定（deflate 绑定到 ZIP 设备所在 NUMA node）
- 自动生成性能报告和多维度对比图表
- 适配 openEuler 24.03 (LTS-SP2) aarch64 + 鲲鹏920 环境

## 测试模型

### 内存压力三阶段

| 参数 | 值 |
|------|-----|
| 每线程分配 | 256MB |
| cgroup memory.high | 16G（软节流） |
| cgroup memory.max | 24G（硬限制） |
| swapfile | 16G（priority=100） |
| 线程梯度 | 8, 32, 64, 80, 96, 112, 128, 144, 160 |
| 阶段分布 | 无swap(2点) + zswap(4点) + swap满(3点) |

随线程增长，内存压力自然经历三个阶段：

| 线程数 | 总负载 | 阶段 | 行为 |
|--------|--------|------|------|
| 8, 32 | 2G-8G | **无 swap** | 内存充裕，无压缩开销 |
| 64, 80, 96, 112 | 16G-28G | **zswap 压缩** | 超 memory.high，触发 zswap 压缩+swap |
| 128, 144, 160 | 32G-40G | **swap 满载** | swap 耗尽，分配阻塞/swapin，压力最大 |

### 算法对比矩阵

| 算法 | 实现方式 | 说明 |
|------|----------|------|
| lz4 | 软件 | 最快压缩速度，低延迟 |
| deflate-sw | 软件 (卸载 hisi_zip) | 纯软件 deflate 基准 |
| lzo | 软件 | 平衡型压缩算法 |
| zstd | 软件 | 高压缩比，适合内存紧张场景 |
| deflate | 硬件 (hisi-deflate-acomp) | HiSilicon ZIP 加速，自动绑定 NUMA |

## 目录结构

```
zswap-benchmark/
├── scripts/
│   ├── zswap_benchmark.sh          # 主测试脚本 (支持 --mode 参数)
│   ├── zswap_memtest_benchmark.sh  # 内存压力测试专用脚本
│   ├── zswap_llama_benchmark.sh    # llama-bench 推理测试专用脚本
│   ├── analyze_results.py          # Python 分析脚本
│   └── setup_env.sh                # 环境初始化（适配 openEuler）
├── docs/
│   └── environment_a_guide.md  # 环境A操作指导
├── results/                    # 测试结果输出目录
├── .gitignore
├── LICENSE
└── README.md
```

## 环境要求

- **操作系统**: openEuler 24.03 (LTS-SP2) 或其他 Linux 发行版
- **内核**: 需启用 zswap 支持 (CONFIG_ZSWAP=y)
- **cgroup**: 需启用 cgroup v2 (内核启动参数 `systemd.unified_cgroup_hierarchy=1 cgroup_no_v1=all`)
- **架构**: aarch64 / x86_64
- **内存**: 至少 16GB（推荐 64GB+）
- **权限**: 需要 root 权限运行测试
- **依赖**: python3, numactl, bc, awk

## 快速开始

### 1. 环境准备

```bash
# 克隆项目
git clone https://github.com/IAMHCHCH/zswap-benchmark.git
cd zswap-benchmark

# 安装依赖并初始化环境
chmod +x scripts/setup_env.sh
sudo ./scripts/setup_env.sh
```

脚本会自动执行：
1. 检查内核 zswap 支持
2. 检查压缩算法支持
3. 安装系统依赖（gcc, cmake, python3, numactl 等）
4. 配置 cgroup v2（含快速验证）
5. 加载压缩算法模块（含 HiSilicon ZIP 硬件加速器）
6. 编译 llama.cpp（可选）

### 2. 配置测试参数

编辑 `scripts/zswap_benchmark.sh` 中的配置：

```bash
PER_THREAD_MEM="256M"                # 每线程分配内存
CGROUP_MEM_HIGH="16G"                # cgroup 软节流阈值
CGROUP_MEM_MAX="max"                 # cgroup 硬限制 (max=不触发 OOM)
SWAPFILE_SIZE="16G"                  # swap 文件大小 (与 high 匹配)
SWAPFILE="/home/swapfile_zswap"      # swap 文件路径
SWAP_PRIORITY=100                    # swap 优先级
# 三阶段线程梯度: 无swap(8,32) + zswap(64,80,96,112) + swap满(128,144,160)
THREADS="8 32 64 80 96 112 128 144 160"
ALGOS="lz4 deflate-sw lzo zstd deflate"  # 压缩算法
TEST_DURATION=30                     # 每组测试持续时间(秒)
MODEL="/root/test_zswap/llama.cpp/models/qwen2-7b-instruct-q5_0.gguf"  # llama-bench 模型
DATA_SOURCE="/root/hch/silesia"      # memtest 使用 silesia 真实数据集
```

> **详细操作指导**: 如果您使用的是 openEuler 或类似环境，请参考 [环境A操作指导](docs/environment_a_guide.md)，包含内核切换、cgroup v2 配置等详细步骤。

### 3. 下载 llama-bench 模型（可选）

llama-bench 默认启用，需下载 GGUF 格式模型。若测试服务器无法连外网，可在本地电脑下载后传输。

#### 在本地电脑下载模型

```bash
# wget (Linux/macOS/Git Bash)
wget -O qwen2.5-7b-q4_0.gguf \
    https://huggingface.co/second-state/Qwen2.5-7B-Instruct-GGUF/resolve/main/Qwen2.5-7B-Instruct-Q4_0.gguf
```

> Windows 用户也可直接在浏览器中打开上述 URL 下载，文件约 4.4GB。

#### 传输到测试服务器

```bash
# 方法1: scp 传输 (推荐)
scp qwen2.5-7b-q4_0.gguf root@<服务器IP>:/tmp/llama.cpp/models/7b-q4_0.gguf

# 方法2: Windows 下使用 WinSCP / FileZilla 图形化传输
#   主机: <服务器IP>, 用户: root, 协议: SFTP
#   上传到: /tmp/llama.cpp/models/7b-q4_0.gguf

# 方法3: U盘 / 移动硬盘拷贝 (适合隔离网络)
#   1. 将模型文件拷贝到U盘
#   2. 在服务器上挂载U盘: mount /dev/sdb1 /mnt/usb
#   3. 复制: mkdir -p /tmp/llama.cpp/models && cp /mnt/usb/qwen2.5-7b-q4_0.gguf /tmp/llama.cpp/models/7b-q4_0.gguf
```

> 若不下载模型，llama-bench 自动跳过，仅运行内存压力测试。

### 4. 运行测试

支持三种测试模式，可以灵活选择：

#### 方式一：使用主脚本（推荐）

```bash
cd zswap-benchmark/scripts
chmod +x zswap_benchmark.sh zswap_memtest_benchmark.sh zswap_llama_benchmark.sh

# 默认运行 llama-bench 测试 (多进程内存压力 + 推理性能)
sudo ./zswap_benchmark.sh

# 仅运行内存压力测试 (使用 silesia 真实数据)
sudo ./zswap_benchmark.sh --mode=memtest

# 仅运行 llama-bench 测试
sudo ./zswap_benchmark.sh --mode=llama
```

#### 方式二：使用独立脚本

```bash
# 仅运行内存压力测试
sudo ./zswap_memtest_benchmark.sh

# 仅运行 llama-bench 测试
sudo ./zswap_llama_benchmark.sh
```

测试流程（每组 algo x threads）：
1. 配置 zswap 算法，加载/卸载硬件加速器
2. 创建 cgroup，设置内存限制
3. 准备 swapfile
4. 启动 N 个子进程，每个 mmap 分配 256MB，测量写入吞吐量
5. 逐秒采样 memory/swap/zswap/CPU 指标（30 秒）
6. 终止子进程，采集 user/sys 时间和 CPU 占比
7. 可选: 运行 llama-bench 测量 LLM 推理性能

### 5. 分析结果

```bash
# 查看汇总报告
cat ../results/results_*/summary.txt

# Python 分析（生成图表）
python3 analyze_results.py ../results/results_*/
```

## 输出指标

### 数据处理带宽

每组测试自动采集以下指标：

| 指标 | 说明 |
|------|------|
| Total Throughput (KB/s) | 总写入吞吐量 = 总字节数 / 分配耗时 |
| Average Throughput (KB/s) | 每线程平均吞吐量 |
| Alloc Elapsed (sec) | 内存分配总耗时（含 zswap 压缩开销） |
| Wall Elapsed (sec) | 测试总耗时（含分配 + 采样） |
| User Time (sec) | 用户态 CPU 时间（业务处理） |
| Sys Time (sec) | 内核态 CPU 时间（含 zswap 压缩开销） |

### CPU 使用率

通过 cgroup `cpu.stat` 和 `/proc/pid/stat` 采集，分离业务与压缩开销：

| 指标 | 说明 | 来源 |
|------|------|------|
| Business% | 业务处理占比 (用户态) | cgroup cpu.stat user_usec delta |
| Compression% | 压缩/内核开销占比 (内核态) | cgroup cpu.stat system_usec delta |
| Child User (sec) | 子进程用户态 CPU 时间 (内存写入) | /proc/pid/stat utime |
| Child Sys (sec) | 子进程内核态 CPU 时间 (含 zswap 压缩) | /proc/pid/stat stime |
| Llama User (ms) | llama-bench 推理 CPU 时间 | cgroup cpu.stat delta |
| Llama Sys (ms) | llama-bench 内核开销 | cgroup cpu.stat delta |

## 输出文件

### 数据文件

| 文件 | 格式 | 内容 |
|------|------|------|
| `phase_algo_tN.log` | CSV | 逐秒采样：timestamp, memory_current, swap_current, zswap_pages, cpu_user/system/idle |
| `phase_llama_algo_tN.log` | CSV | llama-bench 逐秒采样（可选） |
| `zswap_algo_tN_pre/post.log` | 文本 | 测试前/后 zswap 快照 |
| `memtest_algo_tN.log` | 文本 | memtest 测试日志（元数据 + METRICS） |
| `bench_algo_tN.log` | 文本 | llama-bench 输出（可选） |
| `test_config.txt` | 文本 | 测试配置信息 |
| `summary.txt` | 文本 | 汇总报告 |

### 分析图表

| 图表 | 说明 |
|------|------|
| `throughput_vs_threads.png` | **各算法总吞吐量随线程数变化** |
| `time_vs_threads.png` | **分配耗时 + sys_time 随线程数变化（双面板）** |
| `cpu_breakdown_algo.png` | **Business vs Compression CPU 堆叠柱状图** |
| `memory_pressure.png` | 各算法 memory/swap 峰值随线程数变化 |
| `timeseries_algo_tN.png` | 单算法 memory+swap 时间线 |
| `swap_usage.png` | 各算法 swap 使用量对比 |
| `compression_ratio.png` | 各算法压缩比柱状图 |
| `hw_vs_sw_deflate.png` | 硬件 vs 软件 deflate 三面板对比 |
| `all_algos_tN_timeline.png` | 所有算法最高线程数 memory+swap 时间线 |

## 预期结果

| 算法 | 压缩比 | 压缩速度 | 适用场景 |
|------|--------|----------|----------|
| lz4 | ~1.8x | 最快 | 高吞吐、低延迟优先 |
| lzo | ~2.0x | 中等 | 平衡场景 |
| zstd | ~2.8x | 较慢 | 内存紧张、压缩比优先 |
| deflate (sw) | ~2.2x | 中等 | 软件基准 |
| deflate (hw) | ~2.2x | 快（硬件） | 鲲鹏920 硬件加速场景 |

## 注意事项

1. 测试会修改系统 zswap 参数并创建 swapfile，需要 root 权限
2. 测试结束后自动清理 swapfile 和 cgroup
3. 测试期间系统内存压力较大，建议在专用测试环境运行
4. 首次测试建议从较高内存限制开始（默认 16G cgroup + 16G swap）

## License

MIT
