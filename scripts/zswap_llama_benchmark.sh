#!/bin/bash
#
# zswap_llama_benchmark.sh - Zswap Llama-bench 推理测试专用脚本
# 仅运行 llama-bench 多进程内存压力测试，对比不同压缩算法性能
# 适配 openEuler 24.03 (LTS-SP2) aarch64 + 鲲鹏920 环境
#
# 使用方式:
#   ./zswap_llama_benchmark.sh              # 使用默认配置运行
#   ./zswap_llama_benchmark.sh --model=/path/to/model.gguf  # 指定模型
#

set -e

# ========== 配置参数 ==========
PER_THREAD_MEM="256M"                # 每线程分配内存 (用于计算并发实例数)
CGROUP_MEM_HIGH="16G"                # cgroup memory.high (软节流阈值)
SWAPFILE_SIZE="16G"                  # swap 文件大小
SWAPFILE="/swapfile"                 # swap 文件路径
SWAP_PRIORITY=100                    # swap 优先级
# 线程梯度: 每阶段取 2 个代表值
THREADS="8 32 64 80 128 160"         # 三阶段均衡: 无swap(8,32) + zswap(64,80) + swap满(128,160)
ALGOS="lz4 deflate-sw lzo zstd deflate"  # 对比: 软算lz4/deflate/lzo/zstd + 硬件deflate(hisi-deflate-acomp)
MODEL="/tmp/llama.cpp/models/7b-q4_0.gguf"   # 测试模型路径
PROMPT_LEN=512                       # llama-bench prompt 长度
GEN_LEN=64                           # llama-bench 生成长度
ITERATIONS=1                         # llama-bench 每组测试次数

# 结果目录 (添加 llama 标识)
RESULT_DIR="$(dirname "$0")/../results/llama_$(date +%Y%m%d_%H%M%S)"
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
            exit 1
        fi
    done

    # 检查 llama-bench
    if [ -n "$MODEL" ] && [ -f "$MODEL" ]; then
        if command -v llama-bench &> /dev/null; then
            LLAMA_BENCH_AVAILABLE=1
            log_info "llama-bench 可用, 模型: $MODEL"
        else
            log_err "llama-bench 未安装"
            log_err "请运行: cd /tmp/llama.cpp && mkdir build && cd build && cmake .. && make llama-bench"
            exit 1
        fi
    else
        log_err "模型文件不存在: $MODEL"
        log_err "请先下载 GGUF 模型"
        exit 1
    fi
}

# ========== 硬件加速器检测 ==========
detect_hw_accelerator() {
    log_info "检测 HiSilicon ZIP 硬件加速器..."

    swapoff -a 2>/dev/null || true
    rmmod hisi_zip 2>/dev/null || true
    modprobe hisi_zip uacc_mode=1 pf_q_num=256 perf_mode=1 2>/dev/null || true
    swapon "$SWAPFILE" -p "$SWAP_PRIORITY" 2>/dev/null || true

    HW_ACCEL_AVAILABLE=0
    ZIP_NUMA_NODE=""

    if lsmod | grep -q hisi_zip; then
        log_hw "HiSilicon ZIP 已加载 (uacc_mode=1, pf_q_num=256)"

        for uacce in /sys/class/uacce/hisi_zip-*; do
            if [ -d "$uacce" ]; then
                local dev_name=$(basename "$uacce")
                local node_id=""
                if [ -f "$uacce/node_id" ]; then
                    node_id=$(cat "$uacce/node_id" 2>/dev/null)
                fi
                if [ -n "$node_id" ]; then
                    log_hw "  $dev_name -> NUMA node $node_id"
                    [ -z "$ZIP_NUMA_NODE" ] && ZIP_NUMA_NODE="$node_id"
                else
                    log_hw "  $dev_name -> NUMA node (未知)"
                fi
            fi
        done

        if grep -q "hisi-deflate-acomp" /proc/crypto 2>/dev/null; then
            log_hw "  deflate: 硬件加速可用 (hisi-deflate-acomp, priority 300)"
            HW_ACCEL_AVAILABLE=1
        else
            log_info "  deflate: 硬件加速不可用"
        fi

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

    swapoff -a 2>/dev/null || true
    log_info "已关闭所有现有 swap"

    if [ -f "$SWAPFILE" ]; then
        swapoff "$SWAPFILE" 2>/dev/null || true
        rm -f "$SWAPFILE"
        log_info "已清理旧 swapfile: $SWAPFILE"
    fi

    fallocate -l "$SWAPFILE_SIZE" "$SWAPFILE"
    chmod 600 "$SWAPFILE"
    mkswap "$SWAPFILE" > /dev/null
    swapon "$SWAPFILE" -p "$SWAP_PRIORITY"
    log_info "swapfile 已创建并启用: $SWAPFILE ($SWAPFILE_SIZE, priority=$SWAP_PRIORITY)"

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

    if [ ! -f /sys/fs/cgroup/cgroup.controllers ]; then
        log_err "cgroup v2 未启用, 请先配置内核启动参数:"
        log_err "  systemd.unified_cgroup_hierarchy=1 cgroup_no_v1=all"
        exit 1
    fi

    CGROUP_DIR="/sys/fs/cgroup/zswap_llama_bench"

    if [ -d "$CGROUP_DIR" ]; then
        if [ -f "$CGROUP_DIR/cgroup.procs" ] && [ -s "$CGROUP_DIR/cgroup.procs" ]; then
            while read pid; do
                echo "$pid" > /sys/fs/cgroup/cgroup.procs 2>/dev/null || true
            done < "$CGROUP_DIR/cgroup.procs"
        fi
        rmdir "$CGROUP_DIR" 2>/dev/null || true
    fi

    mkdir -p "$CGROUP_DIR"
    echo $$ > "$CGROUP_DIR/cgroup.procs"

    echo "max" > "$CGROUP_DIR/memory.max"
    echo "$CGROUP_MEM_HIGH" > "$CGROUP_DIR/memory.high"
    echo "$SWAPFILE_SIZE" > "$CGROUP_DIR/memory.swap.max"

    log_info "cgroup v2 创建完成:"
    log_info "  memory.max   = $(cat $CGROUP_DIR/memory.max)"
    log_info "  memory.high  = $(cat $CGROUP_DIR/memory.high)"
    log_info "  memory.swap.max = $(cat $CGROUP_DIR/memory.swap.max)"
}

# ========== Zswap 配置 ==========
configure_zswap() {
    local algo=$1
    local display_algo="$algo"

    if [ "$algo" = "deflate-sw" ]; then
        algo="deflate"
        log_info "配置 zswap: 算法=deflate (强制软件实现)"
    else
        log_info "配置 zswap: 算法=$algo"
    fi

    if [ ! -d /sys/module/zswap ]; then
        log_err "zswap 模块未加载!"
        exit 1
    fi

    case $algo in
        lz4)     modprobe lz4 2>/dev/null || true ;;
        lzo)     modprobe lzo 2>/dev/null || true ;;
        zstd)    modprobe zstd 2>/dev/null || true ;;
        deflate) modprobe deflate 2>/dev/null || true ;;
    esac

    swapoff -a 2>/dev/null || true
    rmmod hisi_zip 2>/dev/null || true
    if [ "$display_algo" = "deflate" ]; then
        modprobe hisi_zip uacc_mode=1 pf_q_num=256 perf_mode=1 2>/dev/null || true
    fi
    swapon "$SWAPFILE" -p "$SWAP_PRIORITY" 2>/dev/null || true

    echo 1 > /sys/module/zswap/parameters/enabled
    echo "$algo" > /sys/module/zswap/parameters/compressor
    echo 25 > /sys/module/zswap/parameters/max_pool_percent
    echo 0 > /sys/module/zswap/parameters/shrinker_enabled 2>/dev/null || true

    if [ -w /sys/kernel/debug/zswap/flush_pool ]; then
        echo 1 > /sys/kernel/debug/zswap/flush_pool
    fi

    local current_algo=$(cat /sys/module/zswap/parameters/compressor)
    local current_enabled=$(cat /sys/module/zswap/parameters/enabled)

    local hw_status="软件"
    case $display_algo in
        deflate)
            grep -q "hisi-deflate-acomp" /proc/crypto 2>/dev/null && hw_status="硬件(hisi-deflate-acomp)"
            ;;
        deflate-sw) hw_status="软件(deflate)" ;;
        lz4|lzo|zstd) hw_status="软件($algo)" ;;
    esac
    log_info "zswap 配置: enabled=$current_enabled, compressor=$current_algo, 实现=$hw_status"

    sleep 1
}

# ========== 采集 zswap 统计 ==========
collect_zswap_stats() {
    local algo=$1
    local threads=$2
    local tag=$3
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
        echo "memory.max=$(cat $CGGROUP_DIR/memory.max 2>/dev/null)"
    } >> "$outfile"
}

# ========== llama.cpp 基准测试 ==========
run_llama_bench() {
    local algo=$1
    local threads=$2
    local outfile="$RESULT_DIR/bench_${algo}_t${threads}.log"
    local phasefile="$RESULT_DIR/phase_llama_${algo}_t${threads}.log"

    if [ $LLAMA_BENCH_AVAILABLE -eq 0 ]; then
        log_warn "llama-bench 未安装，跳过"
        return
    fi

    if [ ! -f "$MODEL" ]; then
        log_warn "模型文件不存在，跳过: $MODEL"
        return
    fi

    # ---- 计算并发实例数 ----
    local model_size_bytes
    model_size_bytes=$(stat -c %s "$MODEL" 2>/dev/null || echo "0")
    local model_size_mb=$((model_size_bytes / 1024 / 1024))

    if [ "$model_size_bytes" -eq 0 ]; then
        log_warn "无法获取模型文件大小，使用 1 个实例"
        model_size_mb=1024
    fi

    local kv_overhead_mb=$((model_size_mb * 40 / 100))
    [ "$kv_overhead_mb" -lt 512 ] && kv_overhead_mb=512

    local per_instance_mem_mb=$((model_size_mb + kv_overhead_mb))

    local cgroup_high_mb
    cgroup_high_mb=$(($(mem_to_bytes "$CGROUP_MEM_HIGH") / 1024 / 1024))
    local swap_size_mb
    swap_size_mb=$(($(mem_to_bytes "$SWAPFILE_SIZE") / 1024 / 1024))
    local total_capacity_mb=$((cgroup_high_mb + swap_size_mb))

    local safe_capacity_mb=$((total_capacity_mb - 2048))

    local per_thread_bytes
    per_thread_bytes=$(mem_to_bytes "$PER_THREAD_MEM")
    local total_target_mb=$((per_thread_bytes * threads / 1024 / 1024))
    local num_instances_by_target=1
    if [ "$model_size_mb" -gt 0 ]; then
        num_instances_by_target=$(( (total_target_mb + model_size_mb - 1) / model_size_mb ))
    fi

    local num_instances_by_capacity=1
    if [ "$per_instance_mem_mb" -gt 0 ]; then
        num_instances_by_capacity=$(( safe_capacity_mb / per_instance_mem_mb ))
    fi
    [ "$num_instances_by_capacity" -lt 1 ] && num_instances_by_capacity=1

    local num_instances=$num_instances_by_target
    if [ "$num_instances_by_capacity" -lt "$num_instances" ]; then
        log_warn "目标需要 $num_instances 实例(${total_target_mb}MB)，"
        log_warn "但 cgroup 容量 ${safe_capacity_mb}MB 最多支持 $num_instances_by_capacity 实例"
        num_instances=$num_instances_by_capacity
    fi
    [ "$num_instances" -lt 1 ] && num_instances=1
    [ "$num_instances" -gt 32 ] && num_instances=32

    local threads_per_instance=$((threads / num_instances))
    [ "$threads_per_instance" -lt 1 ] && threads_per_instance=1

    local total_with_overhead_mb=$((num_instances * per_instance_mem_mb))

    local expected_phase="无 swap"
    if [ "$total_with_overhead_mb" -ge "$cgroup_high_mb" ]; then
        expected_phase="zswap 压缩"
    fi
    if [ "$total_with_overhead_mb" -ge "$total_capacity_mb" ]; then
        expected_phase="swap 满载"
    fi

    log_info "运行 llama-bench (多进程): algo=$algo, threads=$threads"
    log_info "  并发实例: $num_instances, 每实例线程: $threads_per_instance"
    log_info "  模型大小: ${model_size_mb}MB, KV+overhead: ${kv_overhead_mb}MB/实例"
    log_info "  估算总内存: ${total_with_overhead_mb}MB (容量: ${safe_capacity_mb}MB)"
    log_info "  预期阶段: $expected_phase"

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
        echo "KV_Overhead_MB: $kv_overhead_mb"
        echo "Total_Mem_Estimate_MB: $total_with_overhead_mb"
        echo "Safe_Capacity_MB: $safe_capacity_mb"
        echo "Cgroup_High_MB: $cgroup_high_mb"
        echo "Swap_Size_MB: $swap_size_mb"
        echo "Expected_Phase: $expected_phase"
        echo "Prompt_Len: $PROMPT_LEN"
        echo "Gen_Len: $GEN_LEN"
        echo "Iterations: $ITERATIONS"
        echo "Timestamp: $(date)"
        echo ""
    } > "$outfile"

    echo "timestamp,memory_current,swap_current,running_instances" > "$phasefile"

    # ---- cgroup CPU 计数 (前) ----
    local cpu_user_before=0 cpu_sys_before=0
    if [ -f "$CGROUP_DIR/cpu.stat" ]; then
        cpu_user_before=$(grep "^user_usec" "$CGROUP_DIR/cpu.stat" 2>/dev/null | awk '{print $2}')
        cpu_sys_before=$(grep "^system_usec" "$CGROUP_DIR/cpu.stat" 2>/dev/null | awk '{print $2}')
    fi

    # ---- Phase 1: 预加载模型文件 ----
    log_info "  Phase 1: 预加载 $num_instances 份模型文件到内存..."
    local preloader_pids=()
    for i in $(seq 1 "$num_instances"); do
        python3 -c "
import os, sys
file_path = '$MODEL'
file_size = os.path.getsize(file_path)
buf = bytearray(file_size)
with open(file_path, 'rb') as f:
    total = 0
    while total < file_size:
        n = f.readinto(buf[total:])
        if not n:
            break
        total += n
sys.stdin.read()
" &
        preloader_pids+=($!)
    done

    # 等待预加载完成
    local preload_wait=0
    local preload_target=$((model_size_mb * num_instances * 90 / 100))
    while [ "$preload_wait" -lt 120 ]; do
        local mem_now=$(cat "$CGROUP_DIR/memory.current" 2>/dev/null || echo "0")
        local mem_now_mb=$((mem_now / 1024 / 1024))
        if [ "$mem_now_mb" -ge "$preload_target" ] 2>/dev/null; then
            log_info "  预加载完成: memory=${mem_now_mb}MB (目标 ${preload_target}MB)"
            break
        fi
        if [ $((preload_wait % 10)) -eq 0 ]; then
            log_info "  预加载中... [${preload_wait}s] memory=${mem_now_mb}MB"
        fi
        sleep 2
        preload_wait=$((preload_wait + 2))
    done

    # 采样预加载后的内存状态
    {
        local mem_now=$(cat "$CGROUP_DIR/memory.current" 2>/dev/null || echo "0")
        local swap_now=$(cat "$CGROUP_DIR/memory.swap.current" 2>/dev/null || echo "0")
        local ts=$(date +%s)
        echo "$ts,$mem_now,$swap_now,$num_instances" >> "$phasefile"
        local mem_mb=$((mem_now / 1024 / 1024))
        local swap_mb=$((swap_now / 1024 / 1024))
        log_info "  [预加载完成] memory=${mem_mb}MB, swap=${swap_mb}MB"
    }

    # ---- Phase 2: 启动 llama-bench ----
    log_info "  Phase 2: 启动 llama-bench 推理..."
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
            -ngl 0 \
            -mmp 0 \
            > "$inst_out" 2>&1 &
        pids+=($!)
    done

    log_info "  已启动 $num_instances 个实例: PIDs ${pids[*]}"

    # ---- 监控直到完成 ----
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

    # ---- Phase 3: 清理预加载进程 ----
    for pid in "${preloader_pids[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    for pid in "${preloader_pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    log_info "  预加载进程已清理"

    # ---- 汇总各实例结果 ----
    {
        echo ""
        echo "=== Aggregated Results ==="
        echo "Concurrent_Instances: $num_instances"
        echo "Total_Mem_Estimate_MB: $total_with_overhead_mb"
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
                if grep -qE '^\|.+\|.+±' "$f" 2>/dev/null; then
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

        # 采集测试前 zswap 快照
        collect_zswap_stats "$algo" "0" "pre"

        for t in $THREADS; do
            log_info "---------- 线程数: $t ----------"
            run_llama_bench "$algo" "$t"

            # 清空 zswap pool
            if [ -w /sys/kernel/debug/zswap/flush_pool ]; then
                echo 1 > /sys/kernel/debug/zswap/flush_pool
            fi
            sleep 3
        done

        # 采集测试后 zswap 快照
        collect_zswap_stats "$algo" "0" "post"
    done
}

# ========== 生成汇总报告 ==========
generate_summary() {
    local summary_file="$RESULT_DIR/summary.txt"

    {
        echo "============================================"
        echo "  Zswap Llama-bench Benchmark Summary"
        echo "============================================"
        echo ""
        echo "Test Date:    $(date)"
        echo "Kernel:       $(uname -r)"
        echo "Architecture: $(uname -m)"
        echo "CPU:          $(grep 'Model name' /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)"
        echo "Memory:       $(grep MemTotal /proc/meminfo | awk '{print $2" kB"}')"
        echo "Cgroup High:  $CGROUP_MEM_HIGH"
        echo "Swapfile:     $SWAPFILE ($SWAPFILE_SIZE, priority=$SWAP_PRIORITY)"
        echo "Model:        $MODEL"
        echo "Prompt Len:   $PROMPT_LEN"
        echo "Gen Len:      $GEN_LEN"
        echo "Iterations:   $ITERATIONS"
        echo "Threads:      $THREADS"
        echo "Algorithms:   $ALGOS"
        echo ""
        echo "Hardware Accelerator:"
        if lsmod | grep -q hisi_zip; then
            echo "  HiSilicon ZIP: loaded (uacc_mode=1, pf_q_num=256)"
            grep -E "hisi-(lz4|deflate|zstd)-acomp" /proc/crypto 2>/dev/null | \
                awk -F: '/driver/{print "  "$2}' || echo "  (no hw algos registered)"
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
            local bench_file="$RESULT_DIR/bench_${algo}_t${t}.log"
            local phasefile="$RESULT_DIR/phase_llama_${algo}_t${t}.log"
            local zswap_pre="$RESULT_DIR/zswap_${algo}_t${t}_pre.log"
            local zswap_post="$RESULT_DIR/zswap_${algo}_t${t}_post.log"

            echo "" >> "$summary_file"
            echo "  Threads: $t" >> "$summary_file"

            if [ -f "$bench_file" ]; then
                local bench_instances=$(grep "^Concurrent_Instances:" "$bench_file" 2>/dev/null | awk '{print $2}')
                local bench_total_mem=$(grep "^Total_Mem_Estimate_MB:" "$bench_file" 2>/dev/null | awk '{print $2}')
                local bench_success=$(grep "^Successful_Instances:" "$bench_file" 2>/dev/null | awk '{print $2}')
                local bench_user=$(grep "^llama_user_ms:" "$bench_file" 2>/dev/null | awk '{print $2}')
                local bench_sys=$(grep "^llama_sys_ms:" "$bench_file" 2>/dev/null | awk '{print $2}')

                [ -n "$bench_instances" ] && echo "    Instances:         ${bench_instances}" >> "$summary_file"
                [ -n "$bench_total_mem" ] && echo "    Total Model Mem:   ${bench_total_mem} MB" >> "$summary_file"
                [ -n "$bench_success" ] && echo "    Successful:        ${bench_success}" >> "$summary_file"
                [ -n "$bench_user" ] && echo "    User CPU:          ${bench_user} ms" >> "$summary_file"
                [ -n "$bench_sys" ] && echo "    Sys CPU:           ${bench_sys} ms" >> "$summary_file"

                # 提取 eval tokens/s
                local inst_tokens=""
                inst_tokens=$(grep -A 100 "Per-Instance Output" "$bench_file" 2>/dev/null | \
                    grep -oP '[\d.]+(?=\s*tokens\s*/\s*sec|\s*t/s)' | head -1)
                [ -n "$inst_tokens" ] && echo "    Eval Rate:         ${inst_tokens} tokens/s (per instance)" >> "$summary_file"
            fi

            # 从 phase file 提取峰值
            if [ -f "$phasefile" ]; then
                local last_line=$(tail -1 "$phasefile" 2>/dev/null)
                if [ -n "$last_line" ]; then
                    local peak_mem=$(echo "$last_line" | cut -d, -f2)
                    local peak_swap=$(echo "$last_line" | cut -d, -f3)
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
                fi
            fi

            # zswap 快照
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

    echo 0 > /sys/module/zswap/parameters/enabled 2>/dev/null || true

    if [ -n "$CGROUP_DIR" ] && [ -d "$CGROUP_DIR" ]; then
        echo $$ > /sys/fs/cgroup/cgroup.procs 2>/dev/null || true
        rmdir "$CGGROUP_DIR" 2>/dev/null || true
    fi

    if [ -f "$SWAPFILE" ]; then
        swapoff "$SWAPFILE" 2>/dev/null || true
        rm -f "$SWAPFILE" 2>/dev/null || true
        log_info "swapfile 已清理"
    fi

    log_info "清理完成"
}

# ========== 主函数 ==========
main() {
    log_info "Zswap Llama-bench Benchmark Started"
    log_info "==================================="

    # 创建结果目录
    mkdir -p "$RESULT_DIR"

    # 记录测试配置
    {
        echo "Test Type: llama"
        echo "Date: $(date)"
        echo "THREADS=$THREADS"
        echo "ALGOS=$ALGOS"
        echo "MODEL=$MODEL"
        echo "PROMPT_LEN=$PROMPT_LEN"
        echo "GEN_LEN=$GEN_LEN"
        echo "ITERATIONS=$ITERATIONS"
    } > "$RESULT_DIR/test_config.txt"

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
