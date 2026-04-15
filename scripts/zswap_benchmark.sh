#!/bin/bash
#
# zswap_benchmark.sh - Zswap 性能测试主脚本
# 对比 lz4/deflate-sw/lzo/zstd/deflate 在不同线程数下的性能表现
# 适配 openEuler 24.03 (LTS-SP2) aarch64 + 鲲鹏920 环境
#
# 测试模型: 每线程固定分配 256MB，随线程增长自然打满 cgroup → 触发 zswap → 打满 swap → OOM
# 三个阶段: 无 swap → zswap 压缩 → swap 满载
#

set -e

# ========== 配置参数 ==========
PER_THREAD_MEM="256M"                # 每线程分配内存
CGROUP_MEM_HIGH="16G"                # cgroup memory.high (软节流阈值, 不设 max 避免 OOM)
SWAPFILE_SIZE="16G"                  # swap 文件大小
SWAPFILE="/swapfile"                 # swap 文件路径
SWAP_PRIORITY=100                    # swap 优先级
THREADS="8 16 32 64 72 80 96 112 128 144 160"  # 三阶段均衡: 无swap(3) + zswap(5) + swap满(3), 64线程起进入二阶段
ALGOS="lz4 deflate-sw lzo zstd deflate"  # 对比: 软算lz4/deflate/lzo/zstd + 硬件deflate(hisi-deflate-acomp)
TEST_DURATION=30                     # 每组测试持续时间 (秒)
SAMPLE_INTERVAL=1                    # 采样间隔 (秒)
MODEL="/tmp/llama.cpp/models/7b-q4_0.gguf"   # 测试模型路径 (需下载 GGUF 模型, 留空则跳过)
PROMPT_LEN=512                       # prompt 长度
GEN_LEN=128                          # 生成长度
ITERATIONS=3                         # 每组测试次数

# 结果目录
RESULT_DIR="$(dirname "$0")/../results/results_$(date +%Y%m%d_%H%M%S)"
# ========== 配置结束 ==========

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1"; }
log_hw()   { echo -e "${CYAN}[HW]${NC} $1"; }

# 将带单位的内存字符串转换为字节数
mem_to_bytes() {
    local val="$1"
    local num="${val%[KkMmGg]}"
    local unit="${val##*[0-9]}"
    case "$unit" in
        G|g) echo "$((num * 1024 * 1024 * 1024))" ;;
        M|m) echo "$((num * 1024 * 1024))" ;;
        K|k) echo "$((num * 1024))" ;;
        *)   echo "$num" ;;
    esac
}

# ========== 依赖检查 ==========
check_dependencies() {
    log_info "检查依赖..."

    local deps=("bc" "awk" "python3" "numactl")
    for dep in "${deps[@]}"; do
        if ! command -v $dep &> /dev/null; then
            log_err "缺少依赖: $dep"
            log_err "请运行: sudo yum install -y $dep"
            exit 1
        fi
    done

    # 检查 llama-bench (可选)
    if [ -n "$MODEL" ] && [ -f "$MODEL" ]; then
        if command -v llama-bench &> /dev/null; then
            LLAMA_BENCH_AVAILABLE=1
            log_info "llama-bench 可用, 模型: $MODEL"
        else
            log_warn "llama-bench 未安装, 将使用内存压力测试"
            LLAMA_BENCH_AVAILABLE=0
        fi
    else
        log_info "未配置模型文件, 使用内存压力测试"
        LLAMA_BENCH_AVAILABLE=0
    fi
}

# ========== 硬件加速器检测 ==========
detect_hw_accelerator() {
    log_info "检测 HiSilicon ZIP 硬件加速器..."

    # 先 swapoff 再卸载可能残留的旧模块, 否则 hisi_zip 被 zswap 占用无法卸载
    swapoff -a 2>/dev/null || true
    rmmod hisi_zip 2>/dev/null || true
    modprobe hisi_zip uacc_mode=1 pf_q_num=256 2>/dev/null || true
    # 重新启用 swapfile
    swapon "$SWAPFILE" -p "$SWAP_PRIORITY" 2>/dev/null || true

    HW_ACCEL_AVAILABLE=0
    ZIP_NUMA_NODE=""

    if lsmod | grep -q hisi_zip; then
        log_hw "HiSilicon ZIP 已加载 (uacc_mode=1, pf_q_num=256)"

        # 发现 ZIP 设备的 NUMA 拓扑
        local dev_idx=0
        for uacce in /sys/class/uacce/hisi_zip-*; do
            if [ -d "$uacce" ]; then
                local dev_name=$(basename "$uacce")
                local node_id=""
                if [ -f "$uacce/node_id" ]; then
                    node_id=$(cat "$uacce/node_id" 2>/dev/null)
                fi
                if [ -n "$node_id" ]; then
                    log_hw "  $dev_name -> NUMA node $node_id"
                    # 取第一个设备的 NUMA node
                    if [ -z "$ZIP_NUMA_NODE" ]; then
                        ZIP_NUMA_NODE="$node_id"
                    fi
                else
                    log_hw "  $dev_name -> NUMA node (未知)"
                fi
                dev_idx=$((dev_idx + 1))
            fi
        done

        # 检查 deflate 硬件支持
        if grep -q "hisi-deflate-acomp" /proc/crypto 2>/dev/null; then
            log_hw "  deflate: 硬件加速可用 (hisi-deflate-acomp, priority 300)"
            HW_ACCEL_AVAILABLE=1
        else
            log_info "  deflate: 硬件加速不可用"
        fi

        # 打印系统 NUMA 拓扑摘要
        if command -v numactl &> /dev/null; then
            log_info "系统 NUMA 拓扑:"
            numactl --hardware 2>/dev/null | head -10
        fi
    else
        log_info "HiSilicon ZIP 硬件加速器不可用, 使用软件实现"
    fi
}

# ========== Swap 准备 ==========
prepare_swap() {
    log_info "准备 swap 环境..."

    # 关闭所有现有 swap
    swapoff -a 2>/dev/null || true
    log_info "已关闭所有现有 swap"

    # 清理旧 swapfile
    if [ -f "$SWAPFILE" ]; then
        swapoff "$SWAPFILE" 2>/dev/null || true
        rm -f "$SWAPFILE"
        log_info "已清理旧 swapfile: $SWAPFILE"
    fi

    # 创建 swapfile
    fallocate -l "$SWAPFILE_SIZE" "$SWAPFILE"
    chmod 600 "$SWAPFILE"
    mkswap "$SWAPFILE" > /dev/null
    swapon "$SWAPFILE" -p "$SWAP_PRIORITY"
    log_info "swapfile 已创建并启用: $SWAPFILE ($SWAPFILE_SIZE, priority=$SWAP_PRIORITY)"

    # 验证
    local swap_info=$(swapon --show=NAME,SIZE,PRIO --noheadings 2>/dev/null | grep "$SWAPFILE")
    if [ -n "$swap_info" ]; then
        log_info "swap 验证: $swap_info"
    else
        log_err "swap 启用失败!"
        exit 1
    fi
}

# ========== cgroup v2 初始化 ==========
setup_cgroup() {
    log_info "初始化 cgroup v2 (memory.high=$CGROUP_MEM_HIGH, memory.max=max)..."

    # 检查 cgroup v2 是否可用
    if [ ! -f /sys/fs/cgroup/cgroup.controllers ]; then
        log_err "cgroup v2 未启用, 请先配置内核启动参数:"
        log_err "  systemd.unified_cgroup_hierarchy=1 cgroup_no_v1=all"
        log_err "然后运行 setup_env.sh"
        exit 1
    fi

    CGROUP_DIR="/sys/fs/cgroup/zswap_bench"

    # 清理可能残留的旧 cgroup
    if [ -d "$CGROUP_DIR" ]; then
        if [ -f "$CGROUP_DIR/cgroup.procs" ] && [ -s "$CGROUP_DIR/cgroup.procs" ]; then
            while read pid; do
                echo "$pid" > /sys/fs/cgroup/cgroup.procs 2>/dev/null || true
            done < "$CGROUP_DIR/cgroup.procs"
        fi
        rmdir "$CGROUP_DIR" 2>/dev/null || true
    fi

    # 创建 cgroup 目录
    mkdir -p "$CGROUP_DIR"

    # 将当前进程加入 cgroup
    echo $$ > "$CGROUP_DIR/cgroup.procs"

    # 设置内存限制
    # memory.max 保持 "max" 不设硬限制, 避免 OOM killer 杀进程
    # 当 swap 空间耗尽后, 新的内存分配会在 page fault 处阻塞 (throttle),
    # 直到已有页面被回收释放, 但进程不会被 kill
    echo "max" > "$CGROUP_DIR/memory.max"
    echo "$CGROUP_MEM_HIGH" > "$CGROUP_DIR/memory.high"

    # 限制 swap 用量 (等于 swapfile 大小, 可观察满载)
    echo "$SWAPFILE_SIZE" > "$CGROUP_DIR/memory.swap.max"

    log_info "cgroup v2 创建完成:"
    log_info "  memory.max   = $(cat $CGROUP_DIR/memory.max) (不设硬限制, 避免 OOM)"
    log_info "  memory.high  = $(cat $CGROUP_DIR/memory.high)"
    log_info "  memory.swap.max = $(cat $CGROUP_DIR/memory.swap.max)"
}

# ========== Zswap 配置 ==========
configure_zswap() {
    local algo=$1
    local display_algo="$algo"

    # deflate-sw 内部使用 deflate 算法但卸载硬件加速器
    if [ "$algo" = "deflate-sw" ]; then
        algo="deflate"
        log_info "配置 zswap: 算法=deflate (强制软件实现)"
    else
        log_info "配置 zswap: 算法=$algo"
    fi

    # 检查 zswap 是否可用
    if [ ! -d /sys/module/zswap ]; then
        log_err "zswap 模块未加载!"
        log_err "请确保使用支持 zswap 的内核 (CONFIG_ZSWAP=y)"
        exit 1
    fi

    # 加载压缩算法的内核模块
    case $algo in
        lz4)     modprobe lz4 2>/dev/null || true ;;
        lzo)     modprobe lzo 2>/dev/null || true ;;
        zstd)    modprobe zstd 2>/dev/null || true ;;
        deflate) modprobe deflate 2>/dev/null || true ;;
    esac

    # 控制硬件加速器: 仅在测试 "deflate"(非 sw) 时加载 hisi_zip
    # 其他算法均卸载 hisi_zip 以确保使用纯软件实现
    # rmmod 前需 swapoff, 否则 zswap 占用 hisi_zip 导致卸载失败
    swapoff -a 2>/dev/null || true
    rmmod hisi_zip 2>/dev/null || true
    if [ "$display_algo" = "deflate" ]; then
        modprobe hisi_zip uacc_mode=1 pf_q_num=256 2>/dev/null || true
    fi
    # 重新启用 swapfile (swapoff 后必须 swapon)
    swapon "$SWAPFILE" -p "$SWAP_PRIORITY" 2>/dev/null || true

    # 配置 zswap 参数
    echo 1 > /sys/module/zswap/parameters/enabled
    echo "$algo" > /sys/module/zswap/parameters/compressor
    echo 25 > /sys/module/zswap/parameters/max_pool_percent
    echo 0 > /sys/module/zswap/parameters/shrinker_enabled 2>/dev/null || true

    # 清空 pool
    if [ -w /sys/kernel/debug/zswap/flush_pool ]; then
        echo 1 > /sys/kernel/debug/zswap/flush_pool
    fi

    # 验证配置
    local current_algo=$(cat /sys/module/zswap/parameters/compressor)
    local current_enabled=$(cat /sys/module/zswap/parameters/enabled)
    local current_shrinker=$(cat /sys/module/zswap/parameters/shrinker_enabled 2>/dev/null || echo "N/A")

    local hw_status="软件"
    case $display_algo in
        deflate)
            grep -q "hisi-deflate-acomp" /proc/crypto 2>/dev/null && hw_status="硬件(hisi-deflate-acomp)"
            ;;
        deflate-sw) hw_status="软件(deflate)" ;;
        lz4)        hw_status="软件(lz4)" ;;
        lzo)        hw_status="软件(lzo)" ;;
        zstd)       hw_status="软件(zstd)" ;;
    esac
    log_info "zswap 配置: enabled=$current_enabled, compressor=$current_algo, shrinker=$current_shrinker, 实现=$hw_status"

    sleep 1
}

# ========== 采集 zswap 统计 ==========
collect_zswap_stats() {
    local algo=$1
    local threads=$2
    local tag=$3  # "pre" or "post"
    local outfile="$RESULT_DIR/zswap_${algo}_t${threads}_${tag}.log"

    {
        echo "=== Zswap Stats ($tag) ==="
        echo "Algorithm: $algo"
        echo "Threads: $threads"
        echo "Timestamp: $(date +%s.%N)"
        echo ""
        echo "=== Kernel Parameters ==="
        for p in /sys/module/zswap/parameters/*; do
            echo "$(basename $p)=$(cat $p 2>/dev/null)"
        done
        echo ""
        echo "=== Zswap Debug Info ==="
        for f in /sys/kernel/debug/zswap/*; do
            [ -f "$f" ] && echo "$(basename $f)=$(cat $f 2>/dev/null)"
        done
        echo ""
        echo "=== Memory Info ==="
        grep -E "MemTotal|MemFree|MemAvailable|SwapTotal|SwapFree|Zswap" /proc/meminfo
        echo ""
        echo "=== cgroup Memory ==="
        echo "memory.current=$(cat $CGROUP_DIR/memory.current 2>/dev/null)"
        echo "memory.swap.current=$(cat $CGROUP_DIR/memory.swap.current 2>/dev/null)"
        echo "memory.high=$(cat $CGROUP_DIR/memory.high 2>/dev/null)"
        echo "memory.max=$(cat $CGROUP_DIR/memory.max 2>/dev/null)"
    } >> "$outfile"
}

# ========== 生成内存测试 Python 脚本 ==========
generate_memtest_script() {
    cat > "$RESULT_DIR/_memtest_runner.py" << 'PYEOF'
#!/usr/bin/env python3
"""Memory stress test runner: per-thread mmap allocation with throughput/CPU measurement."""

import mmap
import time
import os
import sys


def read_proc_stat():
    """Read CPU time breakdown from /proc/stat.
    Returns (total, user, system, idle) in jiffies.
    """
    with open('/proc/stat') as f:
        line = f.readline()
    parts = line.split()[1:]
    vals = [int(x) for x in parts[:8]]
    total = sum(vals)
    idle = vals[3] + vals[4]
    user = vals[0] + vals[1]
    system = vals[2] + vals[5] + vals[6]
    return total, user, system, idle


def main():
    per_thread = int(sys.argv[1])
    n_threads = int(sys.argv[2])
    duration = int(sys.argv[3])
    phasefile = sys.argv[4]
    cgroup_dir = sys.argv[5]

    # ============================================================
    # Phase 1: Fork children, allocate memory, measure throughput
    # ============================================================

    wall_start = time.time()
    pids = []
    pipes = {}

    for i in range(n_threads):
        r_fd, w_fd = os.pipe()
        pid = os.fork()
        if pid == 0:
            # --- Child process ---
            os.close(r_fd)
            try:
                t0 = time.time()
                buf = mmap.mmap(-1, per_thread)
                page_size = 4096
                for offset in range(0, per_thread, page_size):
                    buf[offset] = 0xAA
                t1 = time.time()
                wt = t1 - t0
                tp = (per_thread / 1024) / wt if wt > 0 else 0
                os.write(w_fd, f'{wt:.6f},{tp:.2f}\n'.encode())
                os.close(w_fd)
                while True:
                    time.sleep(1)
            except Exception as e:
                try:
                    os.write(w_fd, f'ERROR:{e}\n'.encode())
                except Exception:
                    pass
                try:
                    os.close(w_fd)
                except Exception:
                    pass
                os._exit(1)
        else:
            os.close(w_fd)
            pids.append(pid)
            pipes[pid] = r_fd

    # Collect child stats via pipes
    child_write_times = []
    child_throughputs = []
    n_ok = 0
    for pid in pids:
        try:
            data = b''
            while True:
                chunk = os.read(pipes[pid], 256)
                if not chunk:
                    break
                data += chunk
            os.close(pipes[pid])
            text = data.decode().strip()
            if text.startswith('ERROR:'):
                print(f'  Child {pid} failed: {text[6:]}')
            else:
                wt_str, tp_str = text.split(',')
                child_write_times.append(float(wt_str))
                child_throughputs.append(float(tp_str))
                n_ok += 1
        except Exception as e:
            print(f'  Child {pid} read error: {e}')

    wall_alloc_done = time.time()
    alloc_elapsed = wall_alloc_done - wall_start

    # Calculate throughput metrics
    total_bytes = per_thread * n_threads
    total_throughput = (total_bytes / 1024) / alloc_elapsed if alloc_elapsed > 0 else 0
    avg_throughput = sum(child_throughputs) / len(child_throughputs) if child_throughputs else 0

    print(f'METRICS:total_throughput_kbps={total_throughput:.2f}')
    print(f'METRICS:avg_throughput_kbps={avg_throughput:.2f}')
    print(f'METRICS:alloc_elapsed_sec={alloc_elapsed:.4f}')
    print(f'METRICS:total_bytes={total_bytes}')
    print(f'METRICS:n_threads_ok={n_ok}/{n_threads}')
    sys.stdout.flush()

    # ============================================================
    # Phase 2: Hold memory and sample metrics
    # ============================================================

    cpu_before = read_proc_stat()

    # Read cgroup cpu.stat baseline
    cgroup_cpu_user_before = 0
    cgroup_cpu_sys_before = 0
    try:
        with open(os.path.join(cgroup_dir, 'cpu.stat')) as f:
            for line in f:
                if line.startswith('user_usec'):
                    cgroup_cpu_user_before = int(line.split()[1])
                elif line.startswith('system_usec'):
                    cgroup_cpu_sys_before = int(line.split()[1])
    except Exception:
        pass

    for sec in range(duration):
        ts = time.time()

        # cgroup metrics
        try:
            with open(os.path.join(cgroup_dir, 'memory.current')) as f:
                mem_current = f.read().strip()
        except Exception:
            mem_current = '0'

        try:
            with open(os.path.join(cgroup_dir, 'memory.swap.current')) as f:
                swap_current = f.read().strip()
        except Exception:
            swap_current = '0'

        # zswap metrics
        stored_pages = '0'
        pool_total_size = '0'
        try:
            with open('/sys/kernel/debug/zswap/stored_pages') as f:
                stored_pages = f.read().strip()
        except Exception:
            pass
        try:
            with open('/sys/kernel/debug/zswap/pool_total_size') as f:
                pool_total_size = f.read().strip()
        except Exception:
            pass

        # CPU metrics from /proc/stat
        cpu_total, cpu_user, cpu_sys, cpu_idle = read_proc_stat()

        # Write CSV row
        with open(phasefile, 'a') as f:
            f.write(f'{ts:.2f},{mem_current},{swap_current},'
                    f'{stored_pages},{pool_total_size},'
                    f'{cpu_user},{cpu_sys},{cpu_idle},{cpu_total}\n')

        mem_mb = int(mem_current) // (1024 * 1024) if mem_current.isdigit() else 0
        swap_mb = int(swap_current) // (1024 * 1024) if swap_current.isdigit() else 0
        print(f'  [{sec+1}/{duration}s] memory={mem_mb}MB, swap={swap_mb}MB', flush=True)

        time.sleep(1)

    # ============================================================
    # Phase 3: Collect per-child CPU, then kill children
    # ============================================================

    cpu_after = read_proc_stat()
    wall_end = time.time()
    wall_elapsed = wall_end - wall_start

    # Read per-child CPU usage before killing (utime=stat[13], stime=stat[14])
    clk_tck = os.sysconf('SC_CLK_TCK') or 100
    child_user_ticks = 0
    child_sys_ticks = 0
    for pid in pids:
        try:
            with open(f'/proc/{pid}/stat') as f:
                stat = f.read().split()
            child_user_ticks += int(stat[13])
            child_sys_ticks += int(stat[14])
        except Exception:
            pass
    child_user_sec = child_user_ticks / clk_tck
    child_sys_sec = child_sys_ticks / clk_tck

    # Read cgroup cpu.stat for per-cgroup user/sys breakdown
    cgroup_cpu_user_after = 0
    cgroup_cpu_sys_after = 0
    try:
        with open(os.path.join(cgroup_dir, 'cpu.stat')) as f:
            for line in f:
                if line.startswith('user_usec'):
                    cgroup_cpu_user_after = int(line.split()[1])
                elif line.startswith('system_usec'):
                    cgroup_cpu_sys_after = int(line.split()[1])
    except Exception:
        pass

    for pid in pids:
        try:
            os.kill(pid, 9)
        except Exception:
            pass

    for pid in pids:
        try:
            os.waitpid(pid, 0)
        except Exception:
            pass

    # Per-process CPU time (children cumulative)
    try:
        import resource
        ru = resource.getrusage(resource.RUSAGE_CHILDREN)
        proc_user_sec = ru.ru_utime
        proc_sys_sec = ru.ru_stime
    except Exception:
        proc_user_sec = 0.0
        proc_sys_sec = 0.0

    # System-wide CPU breakdown during hold phase
    cpu_d_total = cpu_after[0] - cpu_before[0]
    cpu_d_user = cpu_after[1] - cpu_before[1]
    cpu_d_sys = cpu_after[2] - cpu_before[2]
    cpu_d_idle = cpu_after[3] - cpu_before[3]

    if cpu_d_total > 0:
        cpu_user_pct = cpu_d_user * 100.0 / cpu_d_total
        cpu_sys_pct = cpu_d_sys * 100.0 / cpu_d_total
        cpu_idle_pct = cpu_d_idle * 100.0 / cpu_d_total
    else:
        cpu_user_pct = 0.0
        cpu_sys_pct = 0.0
        cpu_idle_pct = 0.0

    # cgroup CPU delta: business (user) vs compression/kernel (sys)
    cg_d_user = cgroup_cpu_user_after - cgroup_cpu_user_before
    cg_d_sys = cgroup_cpu_sys_after - cgroup_cpu_sys_before
    cg_d_total = cg_d_user + cg_d_sys
    if cg_d_total > 0:
        business_pct = cg_d_user * 100.0 / cg_d_total
        compression_pct = cg_d_sys * 100.0 / cg_d_total
    else:
        business_pct = 0.0
        compression_pct = 0.0

    print(f'METRICS:user_time_sec={proc_user_sec:.4f}')
    print(f'METRICS:sys_time_sec={proc_sys_sec:.4f}')
    print(f'METRICS:child_user_sec={child_user_sec:.4f}')
    print(f'METRICS:child_sys_sec={child_sys_sec:.4f}')
    print(f'METRICS:cgroup_cpu_user_usec={cgroup_cpu_user_after}')
    print(f'METRICS:cgroup_cpu_sys_usec={cgroup_cpu_sys_after}')
    print(f'METRICS:wall_elapsed_sec={wall_elapsed:.4f}')
    print(f'METRICS:cpu_user_pct={cpu_user_pct:.2f}')
    print(f'METRICS:cpu_sys_pct={cpu_sys_pct:.2f}')
    print(f'METRICS:cpu_idle_pct={cpu_idle_pct:.2f}')
    print(f'METRICS:business_pct={business_pct:.2f}')
    print(f'METRICS:compression_pct={compression_pct:.2f}')
    print('All children terminated.', flush=True)


if __name__ == '__main__':
    main()
PYEOF
    chmod +x "$RESULT_DIR/_memtest_runner.py"
}

# ========== 内存压力测试 (核心) ==========
# 每线程分配 PER_THREAD_MEM 匿名内存, 逐秒采样 cgroup/zswap 指标
run_memtest() {
    local algo=$1
    local threads=$2
    local outfile="$RESULT_DIR/memtest_${algo}_t${threads}.log"
    local phasefile="$RESULT_DIR/phase_${algo}_t${threads}.log"

    local per_thread_bytes=$(mem_to_bytes "$PER_THREAD_MEM")
    local total_mem_bytes=$((per_thread_bytes * threads))
    local total_mem_mb=$((total_mem_bytes / 1024 / 1024))
    local cgroup_high_mb=$(($(mem_to_bytes "$CGROUP_MEM_HIGH") / 1024 / 1024))
    local swap_size_mb=$(($(mem_to_bytes "$SWAPFILE_SIZE") / 1024 / 1024))

    log_info "内存压力测试: algo=$algo, threads=$threads, 总负载=${total_mem_mb}MB"
    log_info "  cgroup memory.high=${cgroup_high_mb}MB, swap=${swap_size_mb}MB"

    # 判断预期阶段
    local expected_phase="无 swap"
    if [ "$total_mem_bytes" -ge "$(mem_to_bytes "$CGROUP_MEM_HIGH")" ]; then
        expected_phase="zswap 压缩"
    fi
    local total_capacity=$(($(mem_to_bytes "$CGROUP_MEM_HIGH") + $(mem_to_bytes "$SWAPFILE_SIZE")))
    if [ "$total_mem_bytes" -ge "$total_capacity" ]; then
        expected_phase="swap 满载/OOM"
    fi
    log_info "  预期阶段: $expected_phase"

    # 确定 NUMA 绑定策略
    local numa_prefix=""
    if [ "$algo" = "deflate" ] && [ -n "$ZIP_NUMA_NODE" ]; then
        # 硬件 deflate: 绑定到 ZIP 设备所在 NUMA node
        numa_prefix="numactl --cpunodebind=$ZIP_NUMA_NODE --membind=$ZIP_NUMA_NODE"
        log_info "  NUMA 亲和: 绑定到 node $ZIP_NUMA_NODE (ZIP 设备所在 node)"
    fi

    # 确保 cgroup 任务在组内
    echo $$ > "$CGROUP_DIR/cgroup.procs" 2>/dev/null || true

    # 写入测试头信息
    {
        echo "=== Memory Stress Test ==="
        echo "Algorithm: $algo"
        echo "Threads: $threads"
        echo "Per_Thread_Mem: $PER_THREAD_MEM ($per_thread_bytes bytes)"
        echo "Total_Mem: ${total_mem_mb}MB"
        echo "Cgroup_High: ${cgroup_high_mb}MB"
        echo "Swap_Size: ${swap_size_mb}MB"
        echo "Expected_Phase: $expected_phase"
        echo "NUMA_Policy: $numa_prefix"
        echo "Duration: ${TEST_DURATION}s"
        echo "Timestamp: $(date)"
        echo ""
    } > "$outfile"

    # 写入采样 CSV 头
    echo "timestamp,memory_current,swap_current,zswap_stored_pages,zswap_pool_total_size,cpu_user,cpu_system,cpu_idle,cpu_total" > "$phasefile"

    # 采集 zswap 测试前快照
    collect_zswap_stats "$algo" "$threads" "pre"

    # 记录启动时间
    local start_ts=$(date +%s)

    # 启动内存压力测试 (独立 Python 脚本, 避免内联引号问题)
    $numa_prefix python3 "$RESULT_DIR/_memtest_runner.py" \
        "$per_thread_bytes" "$threads" "$TEST_DURATION" "$phasefile" "$CGROUP_DIR" \
        2>&1 | tee -a "$outfile"

    local end_ts=$(date +%s)
    local elapsed=$((end_ts - start_ts))

    # 采集 zswap 测试后快照
    collect_zswap_stats "$algo" "$threads" "post"

    # 提取关键指标写入测试日志
    {
        echo ""
        echo "=== Test Summary ==="
        echo "Elapsed: ${elapsed}s"
        echo "Total_Mem_Loaded: ${total_mem_mb}MB"
        echo "Expected_Phase: $expected_phase"
    } >> "$outfile"

    log_info "内存压力测试完成: algo=$algo, threads=$threads, 耗时=${elapsed}s"
}

# ========== llama.cpp 基准测试 (多进程内存压力) ==========
#
# 设计思路:
#   启动 N 个并发 llama-bench 进程，每个进程独立加载模型到内存。
#   通过进程数控制总内存占用: N × model_size
#   随进程数增长自然经历三阶段: 无 swap → zswap 压缩 → swap 满载
#
# 示例 (model ~5GB, cgroup high=16G, swap=16G):
#   1 进程  →  5GB  < 16G   → 无 swap
#   3 进程  → 15GB  ≈ 16G   → 接近触发 zswap
#   4 进程  → 20GB  > 16G   → zswap 压缩 + swap 写入
#   7 进程  → 35GB  > 32G   → swap 满载
#
run_llama_bench() {
    local algo=$1
    local threads=$2
    local outfile="$RESULT_DIR/bench_${algo}_t${threads}.log"
    local phasefile="$RESULT_DIR/phase_llama_${algo}_t${threads}.log"

    if [ $LLAMA_BENCH_AVAILABLE -eq 0 ]; then
        return
    fi

    if [ ! -f "$MODEL" ]; then
        log_info "  模型文件不存在，跳过 llama-bench: $MODEL"
        return
    fi

    # ---- 计算并发实例数 ----
    # 目标: N 个实例 × model_size ≈ threads × PER_THREAD_MEM
    # 使 llama-bench 独立构造与 memtest 相同量级的内存压力
    local model_size_bytes
    model_size_bytes=$(stat -c %s "$MODEL" 2>/dev/null || echo "0")
    local model_size_mb=$((model_size_bytes / 1024 / 1024))

    if [ "$model_size_bytes" -eq 0 ]; then
        log_warn "  无法获取模型文件大小，使用 1 个实例"
        model_size_mb=1024  # 保守估计 1GB
    fi

    local per_thread_bytes
    per_thread_bytes=$(mem_to_bytes "$PER_THREAD_MEM")
    local total_target_mb=$((per_thread_bytes * threads / 1024 / 1024))

    # num_instances = ceil(total_target / model_size), 至少 1
    local num_instances=1
    if [ "$model_size_mb" -gt 0 ]; then
        num_instances=$(( (total_target_mb + model_size_mb - 1) / model_size_mb ))
    fi
    [ "$num_instances" -lt 1 ] && num_instances=1
    [ "$num_instances" -gt 32 ] && num_instances=32

    # 每个实例分配的线程数 (均匀分配)
    local threads_per_instance=$((threads / num_instances))
    [ "$threads_per_instance" -lt 1 ] && threads_per_instance=1

    local total_model_mem_mb=$((num_instances * model_size_mb))
    local cgroup_high_mb
    cgroup_high_mb=$(($(mem_to_bytes "$CGROUP_MEM_HIGH") / 1024 / 1024))
    local swap_size_mb
    swap_size_mb=$(($(mem_to_bytes "$SWAPFILE_SIZE") / 1024 / 1024))

    # 判断预期阶段
    local expected_phase="无 swap"
    local total_capacity=$((cgroup_high_mb + swap_size_mb))
    if [ "$total_model_mem_mb" -ge "$cgroup_high_mb" ]; then
        expected_phase="zswap 压缩"
    fi
    if [ "$total_model_mem_mb" -ge "$total_capacity" ]; then
        expected_phase="swap 满载"
    fi

    log_info "运行 llama-bench (多进程): algo=$algo, threads=$threads"
    log_info "  并发实例: $num_instances, 每实例线程: $threads_per_instance"
    log_info "  模型大小: ${model_size_mb}MB, 总模型内存: ${total_model_mem_mb}MB"
    log_info "  预期阶段: $expected_phase"

    # ---- 确保当前 shell 在 cgroup 中 ----
    echo $$ > "$CGROUP_DIR/cgroup.procs" 2>/dev/null || true

    # ---- 写入测试头 ----
    {
        echo "=== Llama Benchmark (Multi-Instance Memory Pressure) ==="
        echo "Algorithm: $algo"
        echo "Threads: $threads"
        echo "Concurrent_Instances: $num_instances"
        echo "Threads_Per_Instance: $threads_per_instance"
        echo "Model: $MODEL"
        echo "Model_Size_MB: $model_size_mb"
        echo "Total_Model_Mem_MB: $total_model_mem_mb"
        echo "Cgroup_High_MB: $cgroup_high_mb"
        echo "Swap_Size_MB: $swap_size_mb"
        echo "Expected_Phase: $expected_phase"
        echo "Prompt_Len: $PROMPT_LEN"
        echo "Gen_Len: $GEN_LEN"
        echo "Iterations: $ITERATIONS"
        echo "Timestamp: $(date)"
        echo ""
    } > "$outfile"

    # ---- 采样 CSV 头 ----
    echo "timestamp,memory_current,swap_current,running_instances" > "$phasefile"

    # ---- cgroup CPU 计数 (前) ----
    local cpu_user_before=0 cpu_sys_before=0
    if [ -f "$CGROUP_DIR/cpu.stat" ]; then
        cpu_user_before=$(grep "^user_usec" "$CGROUP_DIR/cpu.stat" 2>/dev/null | awk '{print $2}')
        cpu_sys_before=$(grep "^system_usec" "$CGROUP_DIR/cpu.stat" 2>/dev/null | awk '{print $2}')
    fi

    # ---- 启动 N 个并发 llama-bench 实例 ----
    local pids=()
    local inst_outfiles=()
    for i in $(seq 1 "$num_instances"); do
        local inst_out="$RESULT_DIR/_llama_inst${i}.log"
        inst_outfiles+=("$inst_out")
        llama-bench \
            -m "$MODEL" \
            -p "$PROMPT_LEN" \
            -n "$GEN_LEN" \
            -t "$threads_per_instance" \
            -r "$ITERATIONS" \
            > "$inst_out" 2>&1 &
        pids+=($!)
    done

    log_info "  已启动 $num_instances 个实例: PIDs ${pids[*]}"

    # ---- 监控 memory/swap 直到所有实例完成 ----
    local max_wait=600
    local waited=0

    while [ "$waited" -lt "$max_wait" ]; do
        local running=0
        for pid in "${pids[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                running=$((running + 1))
            fi
        done

        local mem_now swap_now ts
        mem_now=$(cat "$CGROUP_DIR/memory.current" 2>/dev/null || echo "0")
        swap_now=$(cat "$CGROUP_DIR/memory.swap.current" 2>/dev/null || echo "0")
        ts=$(date +%s)
        echo "$ts,$mem_now,$swap_now,$running" >> "$phasefile"

        # 每 10 秒打印一次进度
        if [ $((waited % 10)) -eq 0 ]; then
            local mem_mb=$((mem_now / 1024 / 1024))
            local swap_mb=$((swap_now / 1024 / 1024))
            log_info "  [${waited}s] memory=${mem_mb}MB, swap=${swap_mb}MB, running=${running}/${num_instances}"
        fi

        if [ "$running" -eq 0 ]; then
            break
        fi

        sleep 1
        waited=$((waited + 1))
    done

    # ---- 等待残留实例 ----
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    # ---- cgroup CPU 计数 (后) ----
    local cpu_user_after=0 cpu_sys_after=0
    if [ -f "$CGROUP_DIR/cpu.stat" ]; then
        cpu_user_after=$(grep "^user_usec" "$CGROUP_DIR/cpu.stat" 2>/dev/null | awk '{print $2}')
        cpu_sys_after=$(grep "^system_usec" "$CGROUP_DIR/cpu.stat" 2>/dev/null | awk '{print $2}')
    fi
    local llama_user_ms=$(( (cpu_user_after - cpu_user_before) / 1000 ))
    local llama_sys_ms=$(( (cpu_sys_after - cpu_sys_before) / 1000 ))

    # ---- 汇总各实例结果 ----
    {
        echo ""
        echo "=== Aggregated Results ==="
        echo "Concurrent_Instances: $num_instances"
        echo "Total_Model_Mem_MB: $total_model_mem_mb"
        echo "llama_user_ms: $llama_user_ms"
        echo "llama_sys_ms: $llama_sys_ms"
        echo ""
        echo "=== Per-Instance Output ==="
        local success_count=0
        for i in $(seq 1 "$num_instances"); do
            local f="${inst_outfiles[$((i-1))]}"
            if [ -f "$f" ]; then
                echo "--- Instance $i (PID ${pids[$((i-1))]}) ---"
                cat "$f"
                echo ""
                # 统计成功实例数 (llama-bench 正常退出会产生包含数字的输出)
                if grep -qE '^[0-9]+' "$f" 2>/dev/null; then
                    success_count=$((success_count + 1))
                fi
            else
                echo "--- Instance $i: output file missing ---"
            fi
        done
        echo ""
        echo "Successful_Instances: $success_count / $num_instances"
    } >> "$outfile"

    # 清理临时文件
    for f in "${inst_outfiles[@]}"; do
        rm -f "$f" 2>/dev/null
    done

    log_info "  llama-bench 完成: user=${llama_user_ms}ms, sys=${llama_sys_ms}ms, 成功=${success_count:-?}/${num_instances}"
}

# ========== 主测试循环 ==========
run_tests() {
    log_info "开始测试循环..."
    log_info "结果目录: $RESULT_DIR"

    for algo in $ALGOS; do
        log_info "========== 测试算法: $algo =========="
        configure_zswap "$algo"

        for t in $THREADS; do
            log_info "---------- 线程数: $t ----------"

            # 运行内存压力测试
            run_memtest "$algo" "$t"

            # 可选: 运行 llama-bench
            if [ $LLAMA_BENCH_AVAILABLE -eq 1 ]; then
                run_llama_bench "$algo" "$t"
            fi

            # 清空 zswap pool 为下一组测试准备
            if [ -w /sys/kernel/debug/zswap/flush_pool ]; then
                echo 1 > /sys/kernel/debug/zswap/flush_pool
            fi
            sleep 3
        done
    done
}

# ========== 生成汇总报告 ==========
generate_summary() {
    local summary_file="$RESULT_DIR/summary.txt"

    {
        echo "============================================"
        echo "  Zswap Performance Benchmark Summary"
        echo "============================================"
        echo ""
        echo "Test Date:    $(date)"
        echo "Kernel:       $(uname -r)"
        echo "Architecture: $(uname -m)"
        echo "CPU:          $(grep 'Model name' /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)"
        echo "Memory:       $(grep MemTotal /proc/meminfo | awk '{print $2" kB"}')"
        echo "Cgroup High:  $CGROUP_MEM_HIGH"
        echo "Cgroup Max:   max (不设硬限制)"
        echo "Swapfile:     $SWAPFILE ($SWAPFILE_SIZE, priority=$SWAP_PRIORITY)"
        echo "Per-Thread:   $PER_THREAD_MEM"
        echo "Test Duration: ${TEST_DURATION}s"
        echo "Threads:      $THREADS"
        echo "Algorithms:   $ALGOS"
        echo ""
        echo "Hardware Accelerator:"
        if lsmod | grep -q hisi_zip; then
            echo "  HiSilicon ZIP: loaded (uacc_mode=1, pf_q_num=256)"
            grep -E "hisi-(lz4|deflate|zstd)-acomp" /proc/crypto 2>/dev/null | \
                awk -F: '/driver/{print "  "$2}' || echo "  (no hw algos registered)"
            for uacce in /sys/class/uacce/hisi_zip-*; do
                if [ -d "$uacce" ] && [ -f "$uacce/node_id" ]; then
                    echo "  $(basename $uacce): NUMA node $(cat $uacce/node_id 2>/dev/null)"
                fi
            done
        else
            echo "  None (software only)"
        fi
        echo ""
        echo "Memory Pressure Phases:"
        echo "  无 swap:     total_load < ${CGROUP_MEM_HIGH}"
        echo "  zswap 压缩:  ${CGROUP_MEM_HIGH} <= total_load < ${CGROUP_MEM_HIGH}+${SWAPFILE_SIZE}"
        echo "  swap 满载:   total_load >= ${CGROUP_MEM_HIGH}+${SWAPFILE_SIZE}"
        echo ""
        echo "============================================"
        echo "Per-Algorithm Results"
        echo "============================================"
    } > "$summary_file"

    for algo in $ALGOS; do
        echo "" >> "$summary_file"
        echo "Algorithm: $algo" >> "$summary_file"
        echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~" >> "$summary_file"

        for t in $THREADS; do
            local phasefile="$RESULT_DIR/phase_${algo}_t${t}.log"
            local memtest_file="$RESULT_DIR/memtest_${algo}_t${t}.log"
            local zswap_pre="$RESULT_DIR/zswap_${algo}_t${t}_pre.log"
            local zswap_post="$RESULT_DIR/zswap_${algo}_t${t}_post.log"
            local total_mem_mb=$(( $(mem_to_bytes "$PER_THREAD_MEM") / 1024 / 1024 * t ))

            echo "" >> "$summary_file"
            echo "  Threads: $t  (total load: ${total_mem_mb}MB)" >> "$summary_file"

            # 从 memtest log 提取 METRICS
            if [ -f "$memtest_file" ]; then
                local tp=$(grep "^METRICS:total_throughput_kbps=" "$memtest_file" 2>/dev/null | tail -1 | cut -d= -f2)
                local avg_tp=$(grep "^METRICS:avg_throughput_kbps=" "$memtest_file" 2>/dev/null | tail -1 | cut -d= -f2)
                local alloc_t=$(grep "^METRICS:alloc_elapsed_sec=" "$memtest_file" 2>/dev/null | tail -1 | cut -d= -f2)
                local user_t=$(grep "^METRICS:user_time_sec=" "$memtest_file" 2>/dev/null | tail -1 | cut -d= -f2)
                local sys_t=$(grep "^METRICS:sys_time_sec=" "$memtest_file" 2>/dev/null | tail -1 | cut -d= -f2)
                local wall_t=$(grep "^METRICS:wall_elapsed_sec=" "$memtest_file" 2>/dev/null | tail -1 | cut -d= -f2)
                local cpu_u=$(grep "^METRICS:cpu_user_pct=" "$memtest_file" 2>/dev/null | tail -1 | cut -d= -f2)
                local cpu_s=$(grep "^METRICS:cpu_sys_pct=" "$memtest_file" 2>/dev/null | tail -1 | cut -d= -f2)
                local cpu_i=$(grep "^METRICS:cpu_idle_pct=" "$memtest_file" 2>/dev/null | tail -1 | cut -d= -f2)
                local biz=$(grep "^METRICS:business_pct=" "$memtest_file" 2>/dev/null | tail -1 | cut -d= -f2)
                local comp=$(grep "^METRICS:compression_pct=" "$memtest_file" 2>/dev/null | tail -1 | cut -d= -f2)
                local c_user=$(grep "^METRICS:child_user_sec=" "$memtest_file" 2>/dev/null | tail -1 | cut -d= -f2)
                local c_sys=$(grep "^METRICS:child_sys_sec=" "$memtest_file" 2>/dev/null | tail -1 | cut -d= -f2)

                [ -n "$tp" ] && echo "    Total Throughput:   ${tp} KB/s" >> "$summary_file"
                [ -n "$avg_tp" ] && echo "    Avg Throughput:     ${avg_tp} KB/s" >> "$summary_file"
                [ -n "$alloc_t" ] && echo "    Alloc Elapsed:      ${alloc_t} sec" >> "$summary_file"
                [ -n "$wall_t" ] && echo "    Wall Elapsed:       ${wall_t} sec" >> "$summary_file"
                [ -n "$c_user" ] && echo "    Child User (业务):  ${c_user} sec" >> "$summary_file"
                [ -n "$c_sys" ] && echo "    Child Sys  (压缩):  ${c_sys} sec" >> "$summary_file"
                [ -n "$biz" ] && echo "    Business CPU%:      ${biz}%" >> "$summary_file"
                [ -n "$comp" ] && echo "    Compression CPU%:   ${comp}%" >> "$summary_file"
                [ -n "$cpu_u" ] && echo "    System CPU User%:   ${cpu_u}%" >> "$summary_file"
                [ -n "$cpu_s" ] && echo "    System CPU Sys%:    ${cpu_s}%" >> "$summary_file"
                [ -n "$cpu_i" ] && echo "    System CPU Idle%:   ${cpu_i}%" >> "$summary_file"
            fi

            # 从 phase file 提取峰值指标
            if [ -f "$phasefile" ]; then
                # 跳过 CSV 头, 取最后一行作为稳态值
                local last_line=$(tail -1 "$phasefile" 2>/dev/null)
                if [ -n "$last_line" ]; then
                    local peak_mem=$(echo "$last_line" | cut -d, -f2)
                    local peak_swap=$(echo "$last_line" | cut -d, -f3)
                    local peak_stored=$(echo "$last_line" | cut -d, -f4)
                    local peak_pool_size=$(echo "$last_line" | cut -d, -f5)

                    local peak_mem_mb=0
                    local peak_swap_mb=0
                    if [ -n "$peak_mem" ] && [ "$peak_mem" -eq "$peak_mem" ] 2>/dev/null; then
                        peak_mem_mb=$((peak_mem / 1024 / 1024))
                    fi
                    if [ -n "$peak_swap" ] && [ "$peak_swap" -eq "$peak_swap" ] 2>/dev/null; then
                        peak_swap_mb=$((peak_swap / 1024 / 1024))
                    fi
                    echo "    Peak memory.current: ${peak_mem_mb}MB" >> "$summary_file"
                    echo "    Peak swap.current:   ${peak_swap_mb}MB" >> "$summary_file"

                    # 压缩比 = stored_pages * 4096 / pool_total_size
                    if [ -n "$peak_stored" ] && [ "$peak_stored" -gt 0 ] 2>/dev/null \
                       && [ -n "$peak_pool_size" ] && [ "$peak_pool_size" -gt 0 ] 2>/dev/null; then
                        local orig_bytes=$((peak_stored * 4096))
                        local ratio=$(echo "scale=2; $orig_bytes / $peak_pool_size" | bc 2>/dev/null)
                        echo "    Compression Ratio:   ${ratio}x" >> "$summary_file"
                    fi
                fi
            fi

            # ---- llama-bench 多进程指标 ----
            local bench_file="$RESULT_DIR/bench_${algo}_t${t}.log"
            if [ -f "$bench_file" ]; then
                local bench_instances=$(grep "^Concurrent_Instances:" "$bench_file" 2>/dev/null | awk '{print $2}')
                local bench_total_mem=$(grep "^Total_Model_Mem_MB:" "$bench_file" 2>/dev/null | awk '{print $2}')
                local bench_success=$(grep "^Successful_Instances:" "$bench_file" 2>/dev/null | awk '{print $2}')
                local bench_user=$(grep "^llama_user_ms:" "$bench_file" 2>/dev/null | awk '{print $2}')
                local bench_sys=$(grep "^llama_sys_ms:" "$bench_file" 2>/dev/null | awk '{print $2}')

                echo "    [llama-bench]" >> "$summary_file"
                [ -n "$bench_instances" ] && echo "      Instances:         ${bench_instances}" >> "$summary_file"
                [ -n "$bench_total_mem" ] && echo "      Total Model Mem:   ${bench_total_mem} MB" >> "$summary_file"
                [ -n "$bench_success" ] && echo "      Successful:        ${bench_success}" >> "$summary_file"
                [ -n "$bench_user" ] && echo "      User CPU:          ${bench_user} ms" >> "$summary_file"
                [ -n "$bench_sys" ] && echo "      Sys CPU:           ${bench_sys} ms" >> "$summary_file"

                # 提取各实例的 eval tokens/s (llama-bench 输出的最后一列通常包含速率)
                local inst_tokens=""
                inst_tokens=$(grep -A 100 "Per-Instance Output" "$bench_file" 2>/dev/null | \
                    grep -oP '[\d.]+(?=\s*tokens\s*/\s*sec|\s*t/s)' | head -1)
                [ -n "$inst_tokens" ] && echo "      Eval Rate:         ${inst_tokens} tokens/s (per instance)" >> "$summary_file"
            fi

            # 提取 zswap 前后差异
            if [ -f "$zswap_pre" ] && [ -f "$zswap_post" ]; then
                local pre_stored=$(grep "^stored_pages" "$zswap_pre" 2>/dev/null | awk '{print $2}' | head -1)
                local post_stored=$(grep "^stored_pages" "$zswap_post" 2>/dev/null | awk '{print $2}' | head -1)
                if [ -n "$pre_stored" ] && [ -n "$post_stored" ]; then
                    local delta=$((post_stored - pre_stored))
                    local delta_mb=$((delta * 4 / 1024))
                    echo "    Zswap delta:         ${delta_mb}MB (${delta} pages)" >> "$summary_file"
                fi
            fi
        done
    done

    {
        echo ""
        echo "============================================"
        echo "Results saved to: $RESULT_DIR"
        echo "============================================"
    } >> "$summary_file"

    log_info "汇总报告已生成: $summary_file"
    cat "$summary_file"
}

# ========== 清理函数 ==========
cleanup() {
    log_info "清理测试环境..."

    # 禁用 zswap
    echo 0 > /sys/module/zswap/parameters/enabled 2>/dev/null || true

    # 将进程移回根 cgroup 后删除
    if [ -n "$CGROUP_DIR" ] && [ -d "$CGROUP_DIR" ]; then
        echo $$ > /sys/fs/cgroup/cgroup.procs 2>/dev/null || true
        rmdir "$CGROUP_DIR" 2>/dev/null || true
    fi

    # 清理 swapfile
    if [ -f "$SWAPFILE" ]; then
        swapoff "$SWAPFILE" 2>/dev/null || true
        rm -f "$SWAPFILE" 2>/dev/null || true
        log_info "swapfile 已清理"
    fi

    log_info "清理完成"
}

# ========== 主函数 ==========
main() {
    log_info "Zswap Performance Benchmark Started"
    log_info "==================================="

    # 创建结果目录
    mkdir -p "$RESULT_DIR"

    # 生成内存测试 Python 脚本
    generate_memtest_script

    # 检查依赖
    check_dependencies

    # 检测硬件加速器
    detect_hw_accelerator

    # 准备 swap
    prepare_swap

    # 初始化 cgroup
    setup_cgroup

    # 注册清理函数
    trap cleanup EXIT

    # 运行测试
    run_tests

    # 生成汇总
    generate_summary

    log_info "==================================="
    log_info "Benchmark Completed!"
}

# 运行
main "$@"
