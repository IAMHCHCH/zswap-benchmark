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

## 步骤二：启用 memory cgroup

### 2.1 检查 memory cgroup 状态

```bash
# 检查 memory cgroup 是否已挂载
mount | grep cgroup | grep memory

# 检查 memory subsystem 是否启用
cat /proc/cgroups | grep memory
```

### 2.2 启用 memory cgroup（如果未启用）

如果 memory cgroup 未挂载，需要启用：

```bash
# 方法1: 临时挂载
sudo mkdir -p /sys/fs/cgroup/memory
sudo mount -t cgroup -o memory none /sys/fs/cgroup/memory

# 验证
mount | grep cgroup | grep memory
```

如果挂载失败，需要修改内核启动参数：

```bash
# 编辑 GRUB 配置
sudo vi /etc/default/grub

# 在 GRUB_CMDLINE_LINUX 中添加以下参数：
# cgroup_enable=memory swapaccount=1

# 示例：
# GRUB_CMDLINE_LINUX="... existing params ... cgroup_enable=memory swapaccount=1"

# 更新 GRUB
sudo grub2-mkconfig -o /boot/efi/EFI/openEuler/grub.cfg

# 重启
sudo reboot
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
3. 安装系统依赖
4. 配置 memory cgroup
5. 加载压缩算法模块
6. 编译 llama.cpp（可选）

### 4.2 手动安装依赖（如果脚本失败）

```bash
# 安装基础依赖
sudo yum install -y gcc gcc-c++ make git perf bc gawk libcgroup stress-ng python3 python3-matplotlib

# 加载压缩算法模块
sudo modprobe lz4
sudo modprobe zstd

# 验证
grep -E "lz4|zstd" /proc/crypto
```

---

## 步骤五：配置测试参数

### 5.1 编辑测试脚本配置

```bash
vi scripts/zswap_benchmark.sh
```

修改以下参数：

```bash
MEM_LIMIT="4G"                      # 内存限制（根据实际内存调整）
THREADS="1 2 4 8 16 32 64 128"     # 线程数（鲲鹏920有128核）
ALGOS="lz4 lzo zstd"                # 压缩算法
MODEL="/tmp/llama.cpp/models/7B/m.gguf"  # 测试模型路径
PROMPT_LEN=512                       # prompt 长度
GEN_LEN=128                          # 生成长度
ITERATIONS=3                         # 每组测试次数
```

### 5.2 下载测试模型（如果使用 llama-bench）

```bash
# 创建模型目录
mkdir -p /tmp/llama.cpp/models/7B

# 下载 GGUF 格式模型（示例）
# 可以从 Hugging Face 下载，例如：
# wget -O /tmp/llama.cpp/models/7B/m.gguf https://huggingface.co/.../model.gguf
```

---

## 步骤六：运行测试

### 6.1 运行完整测试

```bash
cd zswap-benchmark/scripts
chmod +x zswap_benchmark.sh
sudo ./zswap_benchmark.sh
```

### 6.2 运行单独测试（可选）

```bash
# 仅测试 lz4 算法
sudo bash -c '
echo 1 > /sys/module/zswap/parameters/enabled
echo lz4 > /sys/module/zswap/parameters/compressor
echo 25 > /sys/module/zswap/parameters/max_pool_percent
cat /sys/module/zswap/parameters/*
'

# 查看 zswap 状态
cat /sys/kernel/debug/zswap/*

# 运行内存压力测试
sudo stress-ng --vm 4 --vm-bytes 4G --timeout 60s
```

---

## 步骤七：查看结果

### 7.1 查看汇总报告

```bash
# 查看最新的结果目录
ls -la ../results/

# 查看汇总报告
cat ../results/results_*/summary.txt
```

### 7.2 分析结果

```bash
# 使用 Python 分析脚本生成图表
python3 analyze_results.py ../results/results_*/
```

---

## 常见问题排查

### Q1: zswap 模块未找到

```bash
# 检查内核配置
grep CONFIG_ZSWAP /boot/config-$(uname -r)

# 如果显示 "# CONFIG_ZSWAP is not set"，需要切换到支持 zswap 的内核
```

### Q2: memory cgroup 挂载失败

```bash
# 检查内核启动参数
cat /proc/cmdline

# 确保包含: cgroup_enable=memory swapaccount=1
# 如果没有，需要修改 GRUB 配置并重启
```

### Q3: 压缩算法不支持

```bash
# 检查可用的压缩算法
grep -E "lz4|lzo|zstd" /proc/crypto

# 尝试加载模块
sudo modprobe lz4
sudo modprobe zstd
```

### Q4: llama-bench 编译失败

```bash
# 安装额外依赖
sudo yum install -y cmake

# 手动编译
cd /tmp/llama.cpp
make clean
make llama-bench -j$(nproc)
```

---

## 预期测试结果

| 算法 | 压缩比 | 压缩速度 | 适用场景 |
|------|--------|----------|----------|
| lz4 | ~1.8x | 最快 | 高吞吐、低延迟优先 |
| lzo | ~2.0x | 中等 | 平衡场景 |
| zstd | ~2.8x | 较慢 | 内存紧张、压缩比优先 |

---

## 联系方式

如有问题，请在 GitHub 仓库提交 Issue: https://github.com/IAMHCHCH/zswap-benchmark
