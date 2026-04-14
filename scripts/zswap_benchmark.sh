#!/bin/bash
#
# zswap_benchmark.sh - Zswap 性能测试主脚本
# 对比 lz4/lzo/zstd 在不同线程数下的性能表现
# 适配 openEuler 24.03 (LTS-SP2) aarch64 + 鲲鹏920 环境
#
# 硬件加速: HiSilicon ZIP (hisi_zip) 支持 lz4/zstd 硬件压缩
#   - 内核模块: hisi_zip (PCI device 0xa250)
#   - 优先级 300，自动优先选择硬件，不可用时回退软件实现
#

set -e

# ========== 配置参数 ==========
MEM_LIMIT="4G"                      # 内存限制
THREADS="1 2 4 8 16 32 64 128"     # 线程数 (适配鲲鹏920 128核)
ALGOS="deflate lzo"                    # 压缩算法 (deflate 使用 hisi-deflate-acomp 硬件加速; lz4/zstd 硬件加速暂不可用)
MODEL=""                            # 测试模型路径 (留空则跳过 llama-bench)
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
log_err() { echo -e "${RED}[ERROR]${NC} $1"; }
log_hw()  { echo -e "${CYAN}[HW]${NC} $1"; }

# 检查依赖
check_dependencies() {
    log_info "检查依赖..."

    local deps=("bc" "awk")
    for dep in "${deps[@]}"; do
        if ! command -v $dep &> /dev/null; then
            log_warn "缺少依赖: $dep"
        fi
    done

    # 检查 llama-bench
    if [ -n "$MODEL" ] && [ -f "$MODEL" ]; then
        if command -v llama-bench &> /dev/null; then
            LLAMA_BENCH_AVAILABLE=1
            log_info "llama-bench 可用, 模型: $MODEL"
        else
            log_warn "llama-bench 未安装, 将使用内存压力测试"
            LLAMA_BENCH_AVAILABLE=0
        fi
    else
        log_info "未配置模型文件, 将使用内存压力测试 (stress-ng)"
        LLAMA_BENCH_AVAILABLE=0
    fi
}

# 检测硬件加速器
detect_hw_accelerator() {
    log_info "检测 HiSilicon ZIP 硬件加速器..."

    # 先卸载可能残留的旧模块, 再以指定参数重新加载
    rmmod hisi_zip 2>/dev/null || true
    modprobe hisi_zip uacc_mode=1 pf_q_num=256 2>/dev/null || true

    if lsmod | grep -q hisi_zip; then
        log_hw "HiSilicon ZIP 已加载 (uacc_mode=1, pf_q_num=256)"

        # 发现 ZIP 设备的 NUMA 拓扑
        ZIP_NUMA_MAP=""
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
                    ZIP_NUMA_MAP="$ZIP_NUMA_MAP $dev_name:$node_id"
                else
                    log_hw "  $dev_name -> NUMA node (未知)"
                fi
                dev_idx=$((dev_idx + 1))
            fi
        done

        # 检查每个算法的硬件支持
        for algo in $ALGOS; do
            local drv_name=""
            case $algo in
                deflate) drv_name="hisi-deflate-acomp" ;;
                lz4)     drv_name="hisi-lz4-acomp" ;;
                zstd)    drv_name="hisi-zstd-acomp" ;;
            esac
            if [ -n "$drv_name" ] && grep -q "$drv_name" /proc/crypto 2>/dev/null; then
                log_hw "  $algo: 硬件加速可用 ($drv_name, priority 300)"
            else
                log_info "  $algo: 使用软件实现"
            fi
        done

        # 打印系统 NUMA 拓扑摘要
        if command -v numactl &> /dev/null; then
            log_info "系统 NUMA 拓扑:"
            numactl --hardware 2>/dev/null | head -10
        fi
    else
        log_info "HiSilicon ZIP 硬件加速器不可用, 使用软件实现"
    fi
}

# 初始化 cgroup v2
setup_cgroup() {
    log_info "初始化 cgroup v2 (内存限制: $MEM_LIMIT)..."

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

    # 设置内存限制 (cgroup v2 接口)
    echo "$MEM_LIMIT" > "$CGROUP_DIR/memory.max"
    echo "$MEM_LIMIT" > "$CGROUP_DIR/memory.high"

    # 启用 swap (不限制 swap 上限, 让 zswap 尽可能工作)
    echo "max" > "$CGROUP_DIR/memory.swap.max"

    log_info "cgroup v2 创建完成"
}

# 配置 zswap
configure_zswap() {
    local algo=$1
    log_info "配置 zswap: 算法=$algo"

    # 检查 zswap 是否可用
    if [ ! -d /sys/module/zswap ]; then
        log_err "zswap 模块未加载!"
        log_err "请确保使用支持 zswap 的内核, 并检查:"
        log_err "  - 内核配置: CONFIG_ZSWAP=y"
        log_err "  - 当前内核: $(uname -r)"
        log_err "  - 运行 setup_env.sh 进行环境检查"
        exit 1
    fi

    # 加载压缩算法的内核模块
    case $algo in
        lz4)
            modprobe lz4 2>/dev/null || true
            ;;
        lzo)
            modprobe lzo 2>/dev/null || true
            ;;
        zstd)
            modprobe zstd 2>/dev/null || true
            ;;
        deflate)
            modprobe deflate 2>/dev/null || true
            ;;
    esac

    # 硬件加速 (HiSilicon ZIP, 支持 deflate/lz4/zstd, 不支持 lzo)
    if [ "$algo" != "lzo" ]; then
        rmmod hisi_zip 2>/dev/null || true
        modprobe hisi_zip uacc_mode=1 pf_q_num=256 2>/dev/null || true
    fi

    # 配置 zswap 参数
    echo 1 > /sys/module/zswap/parameters/enabled
    echo "$algo" > /sys/module/zswap/parameters/compressor
    echo 25 > /sys/module/zswap/parameters/max_pool_percent

    # 清空 pool
    if [ -w /sys/kernel/debug/zswap/flush_pool ]; then
        echo 1 > /sys/kernel/debug/zswap/flush_pool
    fi

    # 验证配置
    local current_algo=$(cat /sys/module/zswap/parameters/compressor)
    local current_enabled=$(cat /sys/module/zswap/parameters/enabled)

    # 检查当前算法是否使用了硬件加速
    local hw_status="软件"
    case $algo in
        deflate)
            grep -q "hisi-deflate-acomp" /proc/crypto 2>/dev/null && hw_status="硬件(hisi_zip)"
            ;;
        lz4)
            grep -q "hisi-lz4-acomp" /proc/crypto 2>/dev/null && hw_status="硬件(hisi_zip)"
            ;;
        zstd)
            grep -q "hisi-zstd-acomp" /proc/crypto 2>/dev/null && hw_status="硬件(hisi_zip)"
            ;;
        lzo)
            hw_status="软件(lzo 不支持硬件加速)"
            ;;
    esac
    log_info "zswap 配置: enabled=$current_enabled, compressor=$current_algo, 实现=$hw_status"

    sleep 1
}

# 收集 zswap 统计
collect_zswap_stats() {
    local algo=$1
    local threads=$2
    local outfile="$RESULT_DIR/zswap_${algo}_t${threads}.log"

    {
        echo "=== Zswap Configuration ==="
        echo "Algorithm: $algo"
        echo "Threads: $threads"
        echo "Memory Limit: $MEM_LIMIT"
        echo "Timestamp: $(date)"
        echo ""
        echo "=== Kernel Parameters ==="
        paste -d= /sys/module/zswap/parameters/* 2>/dev/null || echo "Cannot read params"
        echo ""
        echo "=== Zswap Debug Info ==="
        cat /sys/kernel/debug/zswap/* 2>/dev/null || echo "Cannot read debug info"
        echo ""
        echo "=== Memory Info ==="
        grep -E "MemTotal|MemFree|MemAvailable|SwapTotal|SwapFree|Zswap" /proc/meminfo
        echo ""
        echo "=== Crypto Implementation ==="
        grep -A3 "name.*:.*${algo}" /proc/crypto 2>/dev/null || echo "Cannot read crypto info"
    } >> "$outfile"
}

# 运行 llama.cpp 基准测试
run_llama_bench() {
    local algo=$1
    local threads=$2
    local outfile="$RESULT_DIR/bench_${algo}_t${threads}.log"

    if [ $LLAMA_BENCH_AVAILABLE -eq 0 ]; then
        return
    fi

    log_info "运行 llama-bench: algo=$algo, threads=$threads"

    # 确保 cgroup 任务在组内
    echo $$ > "$CGROUP_DIR/cgroup.procs"

    {
        echo "=== Llama Benchmark ==="
        echo "Algorithm: $algo"
        echo "Threads: $threads"
        echo "Memory Limit: $MEM_LIMIT"
        echo "Model: $MODEL"
        echo "Prompt Length: $PROMPT_LEN"
        echo "Generate Length: $GEN_LEN"
        echo "Iterations: $ITERATIONS"
        echo "Timestamp: $(date)"
        echo ""
        echo "=== Output ==="
    } >> "$outfile"

    echo $$ > "$CGROUP_DIR/cgroup.procs" 2>/dev/null || true
    llama-bench \
        -m "$MODEL" \
        -p $PROMPT_LEN \
        -n $GEN_LEN \
        -t $threads \
        -r $ITERATIONS \
        2>&1 | tee -a "$outfile"
}

# 运行内存压力测试 (无 llama-bench 时)
run_memtest() {
    local algo=$1
    local threads=$2
    local outfile="$RESULT_DIR/memtest_${algo}_t${threads}.log"

    log_info "运行内存压力测试: algo=$algo, threads=$threads"

    echo $$ > "$CGROUP_DIR/cgroup.procs" 2>/dev/null || true

    # 根据 ZIP 设备 NUMA 拓扑选择最优 node
    # 对于多 socket 鲲鹏920, 选择与 ZIP 设备相同的 NUMA node 可获得最佳性能
    local numa_opt=""
    if [ -n "$ZIP_NUMA_MAP" ]; then
        # 取第一个 ZIP 设备的 node id
        local first_entry=$(echo $ZIP_NUMA_MAP | awk '{print $1}')
        local zip_node=$(echo "$first_entry" | cut -d: -f2)
        if [ -n "$zip_node" ] && command -v numactl &> /dev/null; then
            numa_opt="numactl --cpunodebind=$zip_node --membind=$zip_node"
            log_info "  NUMA 亲和: 绑定到 node $zip_node (ZIP 设备所在 node)"
        fi
    fi

    if command -v stress-ng &> /dev/null; then
        {
            echo "=== Memory Stress Test (stress-ng) ==="
            echo "Algorithm: $algo"
            echo "Threads: $threads"
            echo "Memory Limit: $MEM_LIMIT"
            [ -n "$numa_opt" ] && echo "NUMA binding: $numa_opt"
            echo ""
        } >> "$outfile"

        $numa_opt stress-ng --vm "$threads" --vm-bytes 80% --vm-method all \
            --timeout 30s 2>&1 | tee -a "$outfile"
    else
        {
            echo "=== Memory Stress Test (python3) ==="
            echo "Algorithm: $algo"
            echo "Threads: $threads"
            [ -n "$numa_opt" ] && echo "NUMA binding: $numa_opt"
            echo ""
        } >> "$outfile"

        # 使用 python3 分配匿名内存触发 zswap
        $numa_opt python3 -c "
import mmap, time, os
size = 512 * 1024 * 1024  # 512MB
buf = mmap.mmap(-1, size)
buf.write(b'x' * size)
print(f'Allocated {size // 1024 // 1024}MB, PID={os.getpid()}')
time.sleep(10)
buf.close()
" 2>&1 | tee -a "$outfile"
    fi
}

# 主测试循环
run_tests() {
    log_info "开始测试循环..."
    log_info "结果目录: $RESULT_DIR"

    for algo in $ALGOS; do
        log_info "========== 测试算法: $algo =========="
        configure_zswap $algo

        for t in $THREADS; do
            log_info "---------- 线程数: $t ----------"

            # 收集 zswap 状态
            collect_zswap_stats $algo $t

            # 运行基准测试
            if [ $LLAMA_BENCH_AVAILABLE -eq 1 ]; then
                run_llama_bench $algo $t
            else
                run_memtest $algo $t
            fi

            # 清空 zswap pool 为下一组测试
            if [ -w /sys/kernel/debug/zswap/flush_pool ]; then
                echo 1 > /sys/kernel/debug/zswap/flush_pool
            fi
            sleep 3
        done
    done
}

# 生成汇总报告
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
        echo "Memory Limit: $MEM_LIMIT"
        echo "Threads:      $THREADS"
        echo "Algorithms:   $ALGOS"
        echo ""
        echo "Hardware Accelerator:"
        if lsmod | grep -q hisi_zip; then
            echo "  HiSilicon ZIP: loaded (uacc_mode=1, pf_q_num=256)"
            grep -E "hisi-(lz4|deflate|zstd)-acomp" /proc/crypto 2>/dev/null | \
                awk -F: '/driver/{print "  "$2}' || echo "  (no hw algos registered)"
            # ZIP 设备 NUMA 拓扑
            for uacce in /sys/class/uacce/hisi_zip-*; do
                if [ -d "$uacce" ] && [ -f "$uacce/node_id" ]; then
                    echo "  $(basename $uacce): NUMA node $(cat $uacce/node_id 2>/dev/null)"
                fi
            done
        else
            echo "  None (software only)"
        fi
        echo ""
        echo "Test Results:"
        echo "-------------"
    } > "$summary_file"

    for algo in $ALGOS; do
        echo "" >> "$summary_file"
        echo "Algorithm: $algo" >> "$summary_file"
        echo "~~~~~~~~~~~~~~~~~~~~~~~~~~~~" >> "$summary_file"

        for t in $THREADS; do
            local bench_file="$RESULT_DIR/bench_${algo}_t${t}.log"
            local zswap_file="$RESULT_DIR/zswap_${algo}_t${t}.log"

            echo "" >> "$summary_file"
            echo "  Threads: $t" >> "$summary_file"

            # 提取关键指标
            if [ -f "$bench_file" ]; then
                local throughput=$(grep -oP 'tokens per second:\s*\K[\d.]+' "$bench_file" 2>/dev/null | tail -1)
                local latency=$(grep -oP 'eval time:\s*\K[\d.]+' "$bench_file" 2>/dev/null | tail -1)
                [ -n "$throughput" ] && echo "    Throughput: $throughput tokens/s" >> "$summary_file"
                [ -n "$latency" ] && echo "    Latency: $latency ms" >> "$summary_file"
            fi

            # 提取压缩比
            if [ -f "$zswap_file" ]; then
                local stored=$(grep "stored_pages" "$zswap_file" 2>/dev/null | awk '{print $2}')
                local compressed=$(grep "compressed_pages" "$zswap_file" 2>/dev/null | awk '{print $2}')
                if [ -n "$stored" ] && [ -n "$compressed" ] && [ "$compressed" -gt 0 ]; then
                    local ratio=$(echo "scale=2; $stored / $compressed" | bc 2>/dev/null)
                    echo "    Compression Ratio: ${ratio}x" >> "$summary_file"
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

# 清理函数
cleanup() {
    log_info "清理测试环境..."

    # 禁用 zswap
    echo 0 > /sys/module/zswap/parameters/enabled 2>/dev/null || true

    # 将进程移回根 cgroup 后删除
    if [ -n "$CGROUP_DIR" ] && [ -d "$CGROUP_DIR" ]; then
        echo $$ > /sys/fs/cgroup/cgroup.procs 2>/dev/null || true
        rmdir "$CGROUP_DIR" 2>/dev/null || true
    fi

    log_info "清理完成"
}

# 主函数
main() {
    log_info "Zswap Performance Benchmark Started"
    log_info "==================================="

    # 创建结果目录
    mkdir -p "$RESULT_DIR"

    # 检查依赖
    check_dependencies

    # 检测硬件加速器
    detect_hw_accelerator

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
