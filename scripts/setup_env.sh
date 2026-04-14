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

echo "[3/6] 安装系统依赖..."
yum install -y -q \
    gcc \
    gcc-c++ \
    make \
    cmake \
    git \
    bc \
    stress-ng \
    python3 \
    python3-matplotlib \
    || echo "  部分包安装失败（可忽略）"

# ========== 步骤 4: 配置 cgroup v2 ==========
echo ""
echo "[4/6] 配置 cgroup v2..."

# ---- 4.1 检查 cgroup v2 是否已启用 ----
CGROUP_V2_READY=false
if stat -f /sys/fs/cgroup 2>/dev/null | grep -q "Type: cgroup2"; then
    CGROUP_V2_READY=true
    echo "  ✓ cgroup v2 已启用 (cgroup2 文件系统)"
elif mount | grep -q "cgroup2 on /sys/fs/cgroup"; then
    CGROUP_V2_READY=true
    echo "  ✓ cgroup v2 已启用 (mount 确认)"
else
    echo "  ! cgroup v2 未启用（当前使用 cgroup v1）"
    echo ""
    echo "  需要通过内核启动参数切换到 cgroup v2:"
    echo ""
    echo "  操作步骤:"
    echo "    1. 编辑 /etc/default/grub"
    echo "    2. 在 GRUB_CMDLINE_LINUX 中添加:"
    echo "       systemd.unified_cgroup_hierarchy=1 cgroup_no_v1=all"
    echo "    3. 生成 GRUB 配置:"
    echo "       grub2-mkconfig -o /boot/efi/EFI/openEuler/grub.cfg"
    echo "    4. 重启系统: reboot"
    echo "    5. 重启后重新运行本脚本"
    echo ""
    read -p "  是否继续配置其他依赖？(y/n): " continue_cgroup
    if [[ ! "$continue_cgroup" =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# ---- 4.2 启用 memory 控制器 ----
if $CGROUP_V2_READY; then
    echo "  配置 memory 控制器..."

    # 在根 cgroup 启用 memory 控制器
    ROOT_SUBTREE="/sys/fs/cgroup/cgroup.subtree_control"
    if ! grep -qw "memory" "$ROOT_SUBTREE" 2>/dev/null; then
        echo "+memory" > "$ROOT_SUBTREE" 2>/dev/null || {
            echo "  ! 无法在根 cgroup 启用 memory 控制器"
            echo "    请检查: cat /sys/fs/cgroup/cgroup.controllers"
            echo "    如果 memory 不在列表中，说明内核未编译 memory cgroup 支持"
        }
    fi
    if grep -qw "memory" "$ROOT_SUBTREE" 2>/dev/null; then
        echo "    ✓ memory 控制器已在根 cgroup 中启用"
    else
        echo "    ! memory 控制器未启用"
    fi
fi

# ---- 4.3 创建测试 cgroup ----
if $CGROUP_V2_READY; then
    CGROUP_DIR="/sys/fs/cgroup/zswap_bench"

    # 删除可能残留的旧 cgroup（确保干净状态）
    if [ -d "$CGROUP_DIR" ]; then
        # 如果 cgroup 中还有进程，先移走
        if [ -f "$CGROUP_DIR/cgroup.procs" ] && [ -s "$CGROUP_DIR/cgroup.procs" ]; then
            while read pid; do
                echo "$pid" > /sys/fs/cgroup/cgroup.procs 2>/dev/null || true
            done < "$CGROUP_DIR/cgroup.procs"
        fi
        rmdir "$CGROUP_DIR" 2>/dev/null || true
    fi

    mkdir -p "$CGROUP_DIR"
    echo "    ✓ cgroup 目录已创建: $CGROUP_DIR"

    # 设置内存限制 (与 zswap_benchmark.sh 保持一致)
    MEM_LIMIT_SETUP="4G"
    echo "$MEM_LIMIT_SETUP" > "$CGROUP_DIR/memory.max" 2>/dev/null || \
        echo "  ! 无法设置 memory.max"
    echo "$MEM_LIMIT_SETUP" > "$CGROUP_DIR/memory.high" 2>/dev/null || \
        echo "  ! 无法设置 memory.high"
    echo "max" > "$CGROUP_DIR/memory.swap.max" 2>/dev/null || \
        echo "  ! 无法设置 memory.swap.max"
    echo "    ✓ 内存限制已设置: memory.max=$MEM_LIMIT_SETUP, memory.high=$MEM_LIMIT_SETUP"

    # 验证配置
    echo ""
    echo "  cgroup v2 配置验证:"
    echo "    memory.max:         $(cat $CGROUP_DIR/memory.max 2>/dev/null)"
    echo "    memory.high:        $(cat $CGROUP_DIR/memory.high 2>/dev/null)"
    echo "    memory.swap.max:    $(cat $CGROUP_DIR/memory.swap.max 2>/dev/null)"
    echo "    cgroup.controllers: $(cat $CGROUP_DIR/cgroup.controllers 2>/dev/null)"
    echo "    cgroup.procs:       $(cat $CGROUP_DIR/cgroup.procs 2>/dev/null | wc -l) 个进程"

    # ---- 4.4 快速验证: 写入进程 + 观测 memory.current ----
    echo ""
    echo "  ---- cgroup v2 快速验证 ----"

    # 先将当前 shell 加入 zswap_bench cgroup
    echo $$ > "$CGROUP_DIR/cgroup.procs"
    if grep -qw "$$" "$CGROUP_DIR/cgroup.procs" 2>/dev/null; then
        echo "    ✓ 当前 shell ($$) 已加入 cgroup"
    else
        echo "    ! 当前 shell 加入 cgroup 失败"
    fi

    # 记录分配前的 memory.current
    MEM_BEFORE=$(cat "$CGROUP_DIR/memory.current" 2>/dev/null)
    echo "    memory.current (分配前): $MEM_BEFORE bytes ($(( MEM_BEFORE / 1024 / 1024 )) MB)"

    # 在 cgroup 内启动 python3 后台进程分配约 500MB 匿名内存
    # 子进程自动继承父进程的 cgroup，无需单独写入 cgroup.procs
    python3 -c "x='a'*500000000;import time;time.sleep(10)" &
    pid=$!
    echo "    测试进程 PID: $pid (继承 cgroup)"
    sleep 3

    # 读取分配后的 memory.current
    MEM_AFTER=$(cat "$CGROUP_DIR/memory.current" 2>/dev/null)
    echo "    memory.current (分配后): $MEM_AFTER bytes ($(( MEM_AFTER / 1024 / 1024 )) MB)"

    # 等待后台 python3 进程结束（sleep 10 会自动退出）
    wait $pid 2>/dev/null || true

    # 将当前 shell 移回根 cgroup
    echo $$ > /sys/fs/cgroup/cgroup.procs 2>/dev/null || true

    # 判断结果
    MEM_DIFF=$(( MEM_AFTER - MEM_BEFORE ))
    if [ "$MEM_DIFF" -gt 1048576 ]; then
        echo "    ✓ memory.current 变化: +$(( MEM_DIFF / 1024 / 1024 )) MB (cgroup v2 memory 统计工作正常)"
    else
        echo "    ! memory.current 变化过小 (+$(( MEM_DIFF / 1024 )) KB)，memory 控制器可能未正确启用"
    fi

    echo "  ---- 快速验证结束 ----"
fi

# ========== 步骤 5: 加载压缩算法模块 ==========
echo ""
echo "[5/6] 加载压缩算法模块..."

# 软件压缩算法
modprobe lz4 2>/dev/null || true
modprobe lzo 2>/dev/null || true
modprobe zstd 2>/dev/null || true

# HiSilicon ZIP 硬件加速器 (鲲鹏920, 支持 lz4/zstd 硬件加速, 不支持 lzo)
if modprobe hisi_zip 2>/dev/null; then
    echo "  ✓ HiSilicon ZIP 硬件加速器已加载 (hisi_zip)"
else
    echo "  hisi_zip 不可用, 将使用软件压缩"
fi

# 验证
echo "  已加载的压缩算法:"
for algo in lz4 lzo lzo-rle zstd; do
    count=$(grep -c "name.*:.*${algo}" /proc/crypto 2>/dev/null || echo "0")
    if [ "$count" -gt 0 ]; then
        # 检查是否有硬件加速版本
        hw_drv=""
        case $algo in
            lz4)  hw_drv="hisi-lz4-acomp" ;;
            zstd) hw_drv="hisi-zstd-acomp" ;;
        esac
        if [ -n "$hw_drv" ] && grep -q "$hw_drv" /proc/crypto 2>/dev/null; then
            echo "    ✓ $algo ($count instances, 含硬件加速 $hw_drv)"
        else
            echo "    ✓ $algo ($count instances)"
        fi
    fi
done

# ========== 步骤 6: 编译 llama.cpp (可选) ==========
echo ""
echo "[6/6] 编译 llama.cpp (可选)..."
if command -v llama-bench &> /dev/null; then
    echo "  ✓ llama-bench 已安装"
else
    # 按优先级查找 llama.cpp 源码目录：
    #   1. 项目相对目录 ../../llama.cpp
    #   2. /tmp/llama.cpp（之前的默认路径）
    LLAMA_CPP_SRC=""
    LOCAL_LLAMA="$(dirname "$0")/../../llama.cpp"
    if [ -d "$LOCAL_LLAMA" ]; then
        LLAMA_CPP_SRC="$(cd "$LOCAL_LLAMA" && pwd)"
        echo "  ✓ 使用本地 llama.cpp: $LLAMA_CPP_SRC"
    elif [ -d /tmp/llama.cpp ]; then
        LLAMA_CPP_SRC="/tmp/llama.cpp"
        echo "  ✓ 使用 /tmp/llama.cpp"
    else
        echo "  克隆 llama.cpp..."
        git clone --depth 1 https://github.com/ggml-org/llama.cpp.git /tmp/llama.cpp
        LLAMA_CPP_SRC="/tmp/llama.cpp"
    fi

    echo "  编译 llama-bench (CMake)..."
    cd "$LLAMA_CPP_SRC"

    BUILD_LOG="$LLAMA_CPP_SRC/build.log"
    mkdir -p build && cd build
    cmake .. -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF > "$BUILD_LOG" 2>&1
    cmake --build . --target llama-bench -j$(nproc) >> "$BUILD_LOG" 2>&1

    if [ -f bin/llama-bench ]; then
        cp bin/llama-bench /usr/local/bin/
        echo "  ✓ llama-bench 已安装到 /usr/local/bin/"
    elif [ -f llama-bench ]; then
        cp llama-bench /usr/local/bin/
        echo "  ✓ llama-bench 已安装到 /usr/local/bin/"
    else
        echo "  ! llama-bench 编译失败，构建日志:"
        tail -20 "$BUILD_LOG"
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
echo "  3. 检查 cgroup v2: mount | grep cgroup2"
echo "  4. 检查 memory 控制器: cat /sys/fs/cgroup/cgroup.controllers"
echo ""
echo "下一步:"
echo "  1. 下载测试模型到 /tmp/llama.cpp/models/"
echo "  2. 编辑 scripts/zswap_benchmark.sh 配置参数"
echo "  3. 运行: sudo ./scripts/zswap_benchmark.sh"
