#!/bin/bash
#
# setup_env.sh - Zswap 测试环境初始化脚本
#

set -e

echo "=================================="
echo "  Zswap Benchmark Env Setup"
echo "=================================="

# 检查是否为 root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo)"
    exit 1
fi

echo "[1/5] 检查内核配置..."
if [ -d /sys/module/zswap ]; then
    echo "  ✓ zswap 模块已加载"
else
    echo "  ! zswap 可能已编译进内核"
fi

# 检查压缩算法支持
echo "[2/5] 检查压缩算法..."
echo "  lz4: $(grep -c lz4 /proc/crypto 2>/dev/null || echo 0) instances"
echo "  lzo: $(grep -c lzo /proc/crypto 2>/dev/null || echo 0) instances"
echo "  zstd: $(grep -c zstd /proc/crypto 2>/dev/null || echo 0) instances"

echo "[3/5] 安装系统依赖..."
apt-get update -qq
apt-get install -y -qq \
    build-essential \
    git \
    perf-tools-unstable \
    bc \
    awk \
    cgroup-tools \
    stress-ng \
    linux-tools-common \
    linux-tools-generic \
    python3 \
    python3-matplotlib \
    || echo "Some packages may have failed (ok if running in container)"

echo "[4/5] 编译 llama.cpp (可选)..."
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

echo "[5/5] 配置 cgroup..."
mkdir -p /sys/fs/cgroup/memory/zswap_bench
echo "  ✓ cgroup 目录已创建"

echo ""
echo "=================================="
echo "  环境设置完成!"
echo "=================================="
echo ""
echo "下一步:"
echo "  1. 下载测试模型到 /tmp/llama.cpp/models/"
echo "  2. 编辑 scripts/zswap_benchmark.sh 配置参数"
echo "  3. 运行: sudo ./scripts/zswap_benchmark.sh"
