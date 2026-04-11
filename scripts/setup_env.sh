#!/bin/bash
#
# setup_env.sh - Zswap 测试环境初始化脚本
# 适配 openEuler 24.03 (LTS-SP2) aarch64 环境
#

set -e

echo "=================================="
echo "  Zswap Benchmark Env Setup"
echo "  适配 openEuler 24.03 aarch64"
echo "=================================="

# 检查是否为 root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo)"
    exit 1
fi

# ========== 步骤 1: 检查内核配置 ==========
echo "[1/6] 检查内核配置..."

# 检查当前内核是否支持 zswap
ZSWAP_ENABLED=$(grep -c "CONFIG_ZSWAP=y" /boot/config-$(uname -r) 2>/dev/null || echo "0")

if [ "$ZSWAP_ENABLED" -eq 0 ]; then
    echo "  ! 当前内核未启用 zswap 支持"
    echo ""
    echo "  当前内核: $(uname -r)"
    echo ""
    echo "  可用的支持 zswap 的内核:"
    for kernel in /boot/config-*; do
        if grep -q "CONFIG_ZSWAP=y" "$kernel" 2>/dev/null; then
            kver=$(basename "$kernel" | sed 's/config-//')
            echo "    - $kver"
        fi
    done
    echo ""
    echo "  请执行以下步骤切换到支持 zswap 的内核:"
    echo "  1. 编辑 /etc/default/grub，设置 GRUB_DEFAULT=0"
    echo "  2. 运行: grub2-mkconfig -o /boot/efi/EFI/openEuler/grub.cfg"
    echo "  3. 重启系统"
    echo "  4. 验证: uname -r && cat /sys/module/zswap/parameters/enabled"
    echo ""
    read -p "  是否继续配置其他依赖？(y/n): " continue_setup
    if [[ ! "$continue_setup" =~ ^[Yy]$ ]]; then
        exit 1
    fi
else
    echo "  ✓ 当前内核支持 zswap"
fi

# 检查压缩算法支持
echo ""
echo "[2/6] 检查压缩算法..."
echo "  内核支持的压缩算法:"
for algo in lz4 lzo zstd; do
    if grep -q "CONFIG_CRYPTO_${algo^^}=y\|CONFIG_CRYPTO_${algo^^}=m" /boot/config-$(uname -r) 2>/dev/null; then
        echo "    ✓ $algo"
    else
        echo "    ✗ $algo (未启用)"
    fi
done

echo "[3/6] 安装系统依赖 (yum/dnf)..."
yum install -y -q \
    gcc \
    gcc-c++ \
    make \
    git \
    perf \
    bc \
    gawk \
    libcgroup \
    stress-ng \
    python3 \
    python3-matplotlib \
    || dnf install -y -q \
    gcc \
    gcc-c++ \
    make \
    git \
    perf \
    bc \
    gawk \
    libcgroup \
    stress-ng \
    python3 \
    python3-matplotlib \
    || echo "Some packages may have failed (ok if running in container)"

# ========== 步骤 4: 配置 memory cgroup ==========
echo ""
echo "[4/6] 配置 memory cgroup..."

# 检查 memory cgroup 是否已挂载
if mount | grep -q "cgroup.*memory"; then
    echo "  ✓ memory cgroup 已挂载"
else
    echo "  ! memory cgroup 未挂载，正在启用..."

    # 检查是否启用了 memory subsystem
    if ! grep -q "memory" /proc/cgroups; then
        echo "  ! memory cgroup subsystem 未启用"
        echo "  需要在内核启动参数中添加: cgroup_enable=memory"
        echo ""
        echo "  请执行以下步骤:"
        echo "  1. 编辑 /etc/default/grub"
        echo "  2. 在 GRUB_CMDLINE_LINUX 中添加: cgroup_enable=memory swapaccount=1"
        echo "  3. 运行: grub2-mkconfig -o /boot/efi/EFI/openEuler/grub.cfg"
        echo "  4. 重启系统"
    else
        # 挂载 memory cgroup
        mkdir -p /sys/fs/cgroup/memory
        mount -t cgroup -o memory none /sys/fs/cgroup/memory 2>/dev/null || {
            echo "  ! 无法挂载 memory cgroup"
            echo "  请检查内核启动参数是否包含: cgroup_enable=memory swapaccount=1"
        }

        if mount | grep -q "cgroup.*memory"; then
            echo "  ✓ memory cgroup 挂载成功"
        fi
    fi
fi

# 创建测试用的 cgroup
if [ -d /sys/fs/cgroup/memory ]; then
    mkdir -p /sys/fs/cgroup/memory/zswap_bench
    echo "  ✓ cgroup 目录已创建: /sys/fs/cgroup/memory/zswap_bench"
fi

# ========== 步骤 5: 加载压缩算法模块 ==========
echo ""
echo "[5/6] 加载压缩算法模块..."

# 加载 lz4 模块（如果是模块方式编译）
modprobe lz4 2>/dev/null || echo "  lz4 可能已内置或不可用"
modprobe lz4_compress 2>/dev/null || true

# 加载 zstd 模块
modprobe zstd 2>/dev/null || echo "  zstd 可能已内置"

# 验证
echo "  已加载的压缩算法:"
for algo in lz4 lzo lzo-rle zstd; do
    count=$(grep -c "name.*:.*${algo}" /proc/crypto 2>/dev/null || echo "0")
    if [ "$count" -gt 0 ]; then
        echo "    ✓ $algo ($count instances)"
    fi
done

# ========== 步骤 6: 编译 llama.cpp (可选) ==========
echo ""
echo "[6/6] 编译 llama.cpp (可选)..."
if command -v llama-bench &> /dev/null; then
    echo "  ✓ llama-bench 已安装"
else
    echo "  克隆 llama.cpp..."
    if [ ! -d /tmp/llama.cpp ]; then
        git clone --depth 1 https://github.com/ggml-org/llama.cpp.git /tmp/llama.cpp
    fi

    echo "  编译 llama-bench..."
    cd /tmp/llama.cpp
    make llama-bench -j$(nproc) 2>&1 | tail -5

    if [ -f llama-bench ]; then
        cp llama-bench /usr/local/bin/
        echo "  ✓ llama-bench 已安装到 /usr/local/bin/"
    else
        echo "  ! llama-bench 编译失败，请手动检查"
    fi
fi

echo ""
echo "=================================="
echo "  环境设置完成!"
echo "=================================="
echo ""
echo "验证步骤:"
echo "  1. 检查内核: uname -r"
echo "  2. 检查 zswap: cat /sys/module/zswap/parameters/enabled"
echo "  3. 检查 memory cgroup: ls /sys/fs/cgroup/memory/"
echo ""
echo "下一步:"
echo "  1. 下载测试模型到 /tmp/llama.cpp/models/"
echo "  2. 编辑 scripts/zswap_benchmark.sh 配置参数"
echo "  3. 运行: sudo ./scripts/zswap_benchmark.sh"
