# Zswap Benchmark 环境A操作指导

本文档提供在环境A上执行 zswap benchmark 测试的完整操作步骤。

## 环境信息

基于环境B（192.168.90.37）收集的信息，环境A应具有以下特征：

| 项目 | 值 |
|------|-----|
| 架构 | aarch64 (ARM64) |
| CPU | 华为鲲鹏 920 (2×64核 = 128核) |
| 内存 | 约 256GB |
| 操作系统 | openEuler 24.03 (LTS-SP2) |
| 当前内核 | 6.19.0-rc7 (自定义内核，**未启用 zswap**) |
| 标准内核 | 6.6.0-127.0.0.126.oe2403sp2.aarch64 (**已启用 zswap**) |
| memory cgroup | 默认未挂载 |

## 重要提示

**当前使用的内核 (6.19.0-rc7) 未启用 zswap 支持！** 需要切换到标准 openEuler 内核才能进行测试。

**当前系统使用 cgroup v1，需要切换到 cgroup v2。** 通过内核启动参数 `systemd.unified_cgroup_hierarchy=1 cgroup_no_v1=all` 启用。

---

## 步骤一：切换到支持 zswap 的内核

### 1.1 检查当前内核

```bash
# 查看当前内核版本
uname -r

# 检查是否支持 zswap
grep "CONFIG_ZSWAP" /boot/config-$(uname -r)
# 如果显示 "# CONFIG_ZSWAP is not set"，则需要切换内核
```

### 1.2 查看可用的内核

```bash
# 列出已安装的内核
ls -la /boot/vmlinuz-*

# 检查哪个内核支持 zswap
for config in /boot/config-*; do
    if grep -q "CONFIG_ZSWAP=y" "$config"; then
        echo "支持 zswap: $(basename $config | sed 's/config-//')"
    fi
done
```

### 1.3 切换内核

```bash
# 方法1: 使用 grubby 设置默认内核
# 查看所有内核条目
sudo grubby --info=ALL | grep -E "index|title"

# 设置默认内核（选择支持 zswap 的内核，通常是 index=0）
sudo grubby --set-default-index=0

# 方法2: 编辑 GRUB 配置
sudo vi /etc/default/grub
# 设置 GRUB_DEFAULT=0（选择第一个内核，通常是标准内核）

# 更新 GRUB 配置
sudo grub2-mkconfig -o /boot/efi/EFI/openEuler/grub.cfg

# 重启系统
sudo reboot
```

### 1.4 验证内核切换

重启后执行：

```bash
# 检查内核版本
uname -r
# 应该显示: 6.6.0-127.0.0.126.oe2403sp2.aarch64 或类似版本

# 检查 zswap 支持
grep "CONFIG_ZSWAP" /boot/config-$(uname -r)
# 应该显示: CONFIG_ZSWAP=y

# 检查 zswap 模块
ls -la /sys/module/zswap/
# 应该能看到 parameters 目录
```

---

## 步骤二：启用 cgroup v2

### 2.1 检查当前 cgroup 版本

```bash
# 检查当前 cgroup 版本
# 如果输出包含 "cgroup2 on /sys/fs/cgroup" 则已启用 v2
mount | grep cgroup

# 检查 cgroup v2 特征文件是否存在
ls /sys/fs/cgroup/cgroup.controllers
```

### 2.2 通过内核启动参数启用 cgroup v2

如果当前仍使用 cgroup v1，需要在 GRUB 中添加启动参数：

```bash
# 编辑 GRUB 配置
sudo vi /etc/default/grub

# 在 GRUB_CMDLINE_LINUX 中添加以下两个参数：
#   systemd.unified_cgroup_hierarchy=1  — 启用 cgroup v2 统一层级
#   cgroup_no_v1=all                    — 禁用所有 cgroup v1 控制器
#
# 示例（在原有参数末尾追加）：
# GRUB_CMDLINE_LINUX="... existing_params ... systemd.unified_cgroup_hierarchy=1 cgroup_no_v1=all"

# 更新 GRUB 配置
sudo grub2-mkconfig -o /boot/efi/EFI/openEuler/grub.cfg

# 重启
sudo reboot
```

### 2.3 验证 cgroup v2 启用成功

重启后执行：

```bash
# 应看到 cgroup2 挂载在 /sys/fs/cgroup
mount | grep cgroup2
# 输出: cgroup2 on /sys/fs/cgroup type cgroup2 (rw,...)

# 确认 cgroup.controllers 文件存在
cat /sys/fs/cgroup/cgroup.controllers
# 应包含: cpuset cpu io memory hugetlb pids ...

# 启用 memory 控制器（如未自动启用）
echo "+memory" | sudo tee /sys/fs/cgroup/cgroup.subtree_control

# 验证 memory 控制器已启用
cat /sys/fs/cgroup/cgroup.subtree_control
# 应包含: memory
```

---

## 步骤三：获取测试代码

### 3.1 克隆仓库

```bash
# 如果环境A有网络，直接克隆
git clone https://github.com/IAMHCHCH/zswap-benchmark.git
cd zswap-benchmark

# 如果环境A无网络，从环境B复制
# 在环境B上打包：
# cd /path/to/zswap-benchmark
# tar czf zswap-benchmark.tar.gz .
# scp zswap-benchmark.tar.gz root@环境A_IP:/root/

# 在环境A上解压：
# cd /root
# tar xzf zswap-benchmark.tar.gz
# cd zswap-benchmark
```

---

## 步骤四：环境初始化

### 4.1 运行环境初始化脚本

```bash
cd zswap-benchmark
chmod +x scripts/setup_env.sh
sudo ./scripts/setup_env.sh
```

脚本会自动执行以下操作：
1. 检查内核 zswap 支持
2. 检查压缩算法支持
3. 安装系统依赖（gcc, cmake, python3, numactl 等）
4. 配置 cgroup v2（含快速验证）
5. 加载压缩算法模块（含 HiSilicon ZIP 硬件加速器）
6. 编译 llama.cpp（可选）

### 4.2 手动安装依赖（如果脚本失败）

```bash
# 安装基础依赖
sudo yum install -y gcc gcc-c++ make cmake git bc numactl python3 python3-matplotlib

# 加载压缩算法模块
sudo modprobe lz4
sudo modprobe zstd

# 验证
grep -E "lz4|zstd" /proc/crypto
```

---

## 步骤五：配置测试参数

### 5.1 测试模型说明

测试脚本使用**固定每线程分配**模型：

- 每线程分配 256MB 匿名内存
- cgroup memory.high = 16G（软节流阈值）
- cgroup memory.max = 24G（硬限制）
- swapfile = 16G

随线程数增长，自然经历三个阶段：

| 线程数 | 总负载 | 阶段 | 行为 |
|--------|--------|------|------|
| 1-32 | 0.25G-8G | 无 swap | 内存充裕 |
| 64 | 16G | zswap 压缩 | 接近 cgroup high，触发压缩 |
| 128 | 32G | swap 满载 | 超出容量，压力最大 |

### 5.2 编辑测试脚本配置

```bash
vi scripts/zswap_benchmark.sh
```

主要配置参数：

```bash
PER_THREAD_MEM="256M"                # 每线程分配内存
CGROUP_MEM_HIGH="16G"                # cgroup 软节流阈值
CGROUP_MEM_MAX="24G"                 # cgroup 硬限制
SWAPFILE_SIZE="16G"                  # swap 文件大小
THREADS="1 2 4 8 16 32 64 128"      # 线程数梯度
ALGOS="lz4 deflate-sw lzo zstd deflate"  # 压缩算法
TEST_DURATION=30                     # 每组持续时间(秒)
MODEL="/tmp/llama.cpp/models/7b-q4_0.gguf"  # llama-bench 模型路径
```

### 5.3 下载 llama-bench 模型

llama-bench 默认启用。需下载 GGUF 格式模型到指定路径：

```bash
mkdir -p /tmp/llama.cpp/models/

# 下载 GGUF 模型（例如 Qwen2.5-7B Q4_0 量化）
# wget -O /tmp/llama.cpp/models/7b-q4_0.gguf <model_url>
```

> 若不下载模型，llama-bench 自动跳过，仅运行内存压力测试并采集吞吐量/CPU 指标。

---

## 步骤六：运行测试

### 6.1 运行完整测试

```bash
cd zswap-benchmark/scripts
chmod +x zswap_benchmark.sh
sudo ./zswap_benchmark.sh
```

测试会依次执行所有 算法 × 线程数 的组合：

```
lz4:     1, 2, 4, 8, 16, 32, 64, 128 threads
deflate-sw: 1, 2, 4, 8, 16, 32, 64, 128 threads
lzo:     1, 2, 4, 8, 16, 32, 64, 128 threads
zstd:    1, 2, 4, 8, 16, 32, 64, 128 threads
deflate: 1, 2, 4, 8, 16, 32, 64, 128 threads (硬件加速)
```

每组测试约 30 秒，完整测试约需 25-30 分钟。

### 6.2 测试输出说明

测试过程中会看到实时进度：

```
[INFO] 内存压力测试: algo=lz4, threads=64, 总负载=16384MB
[INFO]   cgroup memory.high=16384MB, swap=16384MB
[INFO]   预期阶段: zswap 压缩
METRICS:total_throughput_kbps=12345678.90
METRICS:avg_throughput_kbps=192896.23
METRICS:alloc_elapsed_sec=2.1456
  [1/30s] memory=15234MB, swap=0MB
  [2/30s] memory=16345MB, swap=234MB
  ...
METRICS:user_time_sec=1.2345
METRICS:sys_time_sec=5.6789
METRICS:cpu_user_pct=35.20
METRICS:cpu_sys_pct=45.30
```

### 6.3 快速验证测试（可选）

如需快速验证环境是否正常，可以先只测试 lz4 + 少量线程：

```bash
# 编辑 zswap_benchmark.sh，临时修改：
# ALGOS="lz4"
# THREADS="1 8 64"
sudo ./zswap_benchmark.sh
```

---

## 步骤七：查看和分析结果

### 7.1 结果文件结构

```bash
results/
└── results_20260414_120000/          # 时间戳命名的结果目录
    ├── summary.txt                   # 汇总报告
    ├── phase_lz4_t64.log             # 逐秒采样 CSV
    ├── memtest_lz4_t64.log           # 测试日志
    ├── zswap_lz4_t64_pre.log         # 测试前 zswap 快照
    ├── zswap_lz4_t64_post.log        # 测试后 zswap 快照
    └── ...
```

### 7.2 查看汇总报告

```bash
# 查看最新的结果目录
ls -la ../results/

# 查看汇总报告
cat ../results/results_*/summary.txt
```

### 7.3 生成分析图表

```bash
# 使用 Python 分析脚本生成图表和报告
python3 analyze_results.py ../results/results_*/
```

生成的图表：

| 图表 | 说明 |
|------|------|
| `throughput_vs_threads.png` | **各算法总吞吐量 (KB/s) 随线程数变化** |
| `time_vs_threads.png` | **分配耗时 + 内核时间 (sys_time) 随线程数变化** |
| `cpu_breakdown_algo.png` | **CPU 占比堆叠柱状图 (User业务/ Sys压缩/ Idle)** |
| `memory_pressure.png` | 各算法 memory/swap 峰值随线程数变化 |
| `timeseries_algo_tN.png` | 单算法 memory+swap 时间线 |
| `swap_usage.png` | 各算法 swap 使用量对比 |
| `compression_ratio.png` | 各算法压缩比柱状图 |
| `hw_vs_sw_deflate.png` | 硬件 vs 软件 deflate 三面板对比 |
| `all_algos_t128_timeline.png` | 所有算法最高线程数 memory+swap 时间线 |

### 7.4 分析输出文件

```bash
# JSON 格式的完整结果数据
cat ../results/results_*/results.json

# 文本分析报告
cat ../results/results_*/analysis_report.txt
```

---

## 常见问题排查

### Q1: zswap 模块未找到

```bash
# 检查内核配置
grep CONFIG_ZSWAP /boot/config-$(uname -r)

# 如果显示 "# CONFIG_ZSWAP is not set"，需要切换到支持 zswap 的内核
# 参见步骤一
```

### Q2: cgroup v2 未启用

```bash
# 检查内核启动参数
cat /proc/cmdline

# 确保包含以下两个参数:
#   systemd.unified_cgroup_hierarchy=1 cgroup_no_v1=all
#
# 如果没有，编辑 /etc/default/grub 添加后重新生成 GRUB 配置并重启:
#   sudo grub2-mkconfig -o /boot/efi/EFI/openEuler/grub.cfg
#   sudo reboot
```

### Q3: 压缩算法不支持

```bash
# 检查可用的压缩算法
grep -E "lz4|lzo|zstd" /proc/crypto

# 尝试加载模块
sudo modprobe lz4
sudo modprobe zstd
```

### Q4: HiSilicon ZIP 硬件加速器不可用

```bash
# 检查 hisi_zip 模块
lsmod | grep hisi_zip

# 尝试加载
sudo modprobe hisi_zip uacc_mode=1 pf_q_num=256

# 检查设备
ls /sys/class/uacce/hisi_zip-*

# 如果不可用，deflate 算法会自动回退到软件实现
# 测试仍可正常进行
```

### Q5: swapfile 创建失败

```bash
# 检查磁盘空间
df -h /

# 检查是否有残留 swapfile
swapon --show
sudo swapoff /swapfile 2>/dev/null
sudo rm -f /swapfile

# 手动创建
sudo fallocate -l 16G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile -p 100
```

### Q6: 测试过程中 OOM

```bash
# 如果系统 OOM killer 触发，可以:
# 1. 降低线程梯度: THREADS="1 2 4 8 16 32 64"
# 2. 增大 cgroup 限制: CGROUP_MEM_MAX="32G"
# 3. 减小每线程分配: PER_THREAD_MEM="128M"
```

---

## 预期测试结果

### 压缩性能对比

| 算法 | 压缩比 | 压缩速度 | 适用场景 |
|------|--------|----------|----------|
| lz4 | ~1.8x | 最快 | 高吞吐、低延迟优先 |
| lzo | ~2.0x | 中等 | 平衡场景 |
| zstd | ~2.8x | 较慢 | 内存紧张、压缩比优先 |
| deflate (sw) | ~2.2x | 中等 | 软件基准 |
| deflate (hw) | ~2.2x | 快（硬件） | 鲲鹏920 硬件加速场景 |

### 三阶段特征

1. **无 swap 阶段** (1-32 threads): 各算法无显著差异，无压缩开销
2. **zswap 压缩阶段** (64 threads): 压缩比高的算法 (zstd) 节省更多内存，但 CPU 开销更大
3. **swap 满载阶段** (128 threads): 各算法均面临 swap thrashing，硬件加速的优势体现

---

## 联系方式

如有问题，请在 GitHub 仓库提交 Issue: https://github.com/IAMHCHCH/zswap-benchmark
