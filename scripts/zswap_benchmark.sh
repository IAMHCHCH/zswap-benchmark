#!/bin/bash
#
# zswap_benchmark.sh - Zswap 性能测试主脚本
# 对比 lz4/lzo/zstd 在不同线程数下的性能表现
# 适配 openEuler 24.03 (LTS-SP2) aarch64 环境
#

set -e

# ========== 配置参数 ==========
MEM_LIMIT="4G"                      # 内存限制
THREADS="1 2 4 8 16 32 64 128"     # 线程数 (适配鲲鹏920 128核)
ALGOS="lz4 lzo zstd"                # 压缩算法
MODEL="/tmp/llama.cpp/models/7B/m.gguf"  # 测试模型路径
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
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err() { echo -e "${RED}[ERROR]${NC} $1"; }

# 检查依赖
check_dependencies() {
    log_info "检查依赖..."
    
    local deps=("bc" "awk")
    for dep in "${deps[@]}"; do
        if ! command -v $dep &> /dev/null; then
            log_warn "缺少依赖: $dep"
        fi
    done
    
    if ! command -v llama-bench &> /dev/null; then
        log_warn "llama-bench 未安装，将跳过 LLM 基准测试"
        LLAMA_BENCH_AVAILABLE=0
    else
        LLAMA_BENCH_AVAILABLE=1
    fi
}

# 初始化 cgroup v2
setup_cgroup() {
    log_info "初始化 cgroup v2 (内存限制: $MEM_LIMIT)..."

    # 检查 cgroup v2 是否可用
    if [ ! -f /sys/fs/cgroup/cgroup.controllers ]; then
        log_err "cgroup v2 未启用，请先配置内核启动参数:"
        log_err "  systemd.unified_cgroup_hierarchy=1 cgroup_no_v1=all"
        log_err "然后运行 setup_env.sh"
        exit 1
    fi

    # 启用 memory 控制器
    if ! grep -q "memory" /sys/fs/cgroup/cgroup.controllers 2>/dev/null && \
       ! grep -q "memory" /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null; then
        log_info "启用 memory 控制器..."
        echo "+memory" | sudo tee /sys/fs/cgroup/cgroup.subtree_control > /dev/null
    fi

    # 创建 cgroup 目录
    sudo mkdir -p /sys/fs/cgroup/zswap_bench

    # 将当前进程加入 cgroup
    echo $$ | sudo tee /sys/fs/cgroup/zswap_bench/cgroup.procs > /dev/null

    # 设置内存限制 (cgroup v2 接口)
    echo "$MEM_LIMIT" | sudo tee /sys/fs/cgroup/zswap_bench/memory.max > /dev/null
    echo "$MEM_LIMIT" | sudo tee /sys/fs/cgroup/zswap_bench/memory.high > /dev/null

    # 启用 swap（不限制 swap 上限，让 zswap 尽可能工作）
    echo "max" | sudo tee /sys/fs/cgroup/zswap_bench/memory.swap.max > /dev/null

    log_info "cgroup v2 创建完成"
}

# 配置 zswap
configure_zswap() {
    local algo=$1
    log_info "配置 zswap: 算法=$algo"

    # 检查 zswap 是否可用
    if [ ! -d /sys/module/zswap ]; then
        log_err "zswap 模块未加载！"
        log_err "请确保使用支持 zswap 的内核，并检查:"
        log_err "  - 内核配置: CONFIG_ZSWAP=y"
        log_err "  - 当前内核: $(uname -r)"
        log_err "  - 运行 setup_env.sh 进行环境检查"
        exit 1
    fi

    # 尝试加载压缩算法模块
    case $algo in
        lz4)
            modprobe lz4 2>/dev/null || true
            modprobe lz4_compress 2>/dev/null || true
            ;;
        lzo)
            modprobe lzo 2>/dev/null || true
            ;;
        zstd)
            modprobe zstd 2>/dev/null || true
            ;;
    esac

    # 检查算法是否支持
    if ! grep -q "$algo" /sys/module/zswap/parameters/compressor 2>/dev/null; then
        log_warn "算法 $algo 可能不受支持，尝试继续..."
    fi

    # 配置参数
    echo 1 | sudo tee /sys/module/zswap/parameters/enabled > /dev/null
    echo "$algo" | sudo tee /sys/module/zswap/parameters/compressor > /dev/null
    echo 25 | sudo tee /sys/module/zswap/parameters/max_pool_percent > /dev/null

    # 清空 pool
    if [ -w /sys/kernel/debug/zswap/flush_pool ]; then
        echo 1 | sudo tee /sys/kernel/debug/zswap/flush_pool > /dev/null
    fi

    # 验证配置
    local current_algo=$(cat /sys/module/zswap/parameters/compressor)
    local current_enabled=$(cat /sys/module/zswap/parameters/enabled)
    log_info "zswap 配置: enabled=$current_enabled, compressor=$current_algo"

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
        cat /sys/module/zswap/parameters/* 2>/dev/null || echo "Cannot read params"
        echo ""
        echo "=== Zswap Debug Info ==="
        cat /sys/kernel/debug/zswap/* 2>/dev/null || echo "Cannot read debug info"
        echo ""
        echo "=== Memory Info ==="
        grep -E "MemTotal|MemFree|MemAvailable|SwapTotal|SwapFree|Zswap" /proc/meminfo
    } >> "$outfile"
}

# 运行 llama.cpp 基准测试
run_llama_bench() {
    local algo=$1
    local threads=$2
    local outfile="$RESULT_DIR/bench_${algo}_t${threads}.log"
    
    if [ $LLAMA_BENCH_AVAILABLE -eq 0 ]; then
        log_warn "llama-bench 不可用，跳过"
        return
    fi
    
    if [ ! -f "$MODEL" ]; then
        log_warn "模型文件不存在: $MODEL，跳过 llama-bench"
        return
    fi
    
    log_info "运行 llama-bench: algo=$algo, threads=$threads"
    
    # 确保 cgroup 任务在组内
    echo $$ | sudo tee /sys/fs/cgroup/zswap_bench/cgroup.procs > /dev/null

    # 运行测试
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

    # cgroup v2: 将 llama-bench 进程加入 zswap_bench cgroup
    sudo bash -c "echo \$$ > /sys/fs/cgroup/zswap_bench/cgroup.procs" 2>/dev/null || true
    llama-bench \
        -m "$MODEL" \
        -p $PROMPT_LEN \
        -n $GEN_LEN \
        -t $threads \
        -r $ITERATIONS \
        2>&1 | tee -a "$outfile"
}

# 运行简单内存压力测试（无 llama-bench 时）
run_memtest() {
    local algo=$1
    local threads=$2
    local outfile="$RESULT_DIR/memtest_${algo}_t${threads}.log"
    
    log_info "运行内存压力测试: algo=$algo, threads=$threads"
    
    # 使用 stress-ng 模拟内存压力
    if command -v stress-ng &> /dev/null; then
        {
            echo "=== Memory Stress Test ==="
            echo "Algorithm: $algo"
            echo "Threads: $threads"
            echo ""
        } >> "$outfile"
        
        sudo bash -c "echo \$$ > /sys/fs/cgroup/zswap_bench/cgroup.procs" 2>/dev/null || true
        stress-ng --vm 1 --vm-bytes 80% --vm-method all \
            --timeout 30s 2>&1 | tee -a "$outfile"
    else
        log_warn "stress-ng 不可用，使用简单内存测试"
        # 简单内存写入测试
        dd if=/dev/zero of=/dev/shm/test_$algo bs=1M count=100 2>&1 | tee -a "$outfile"
        rm -f /dev/shm/test_$algo
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
                echo 1 | sudo tee /sys/kernel/debug/zswap/flush_pool > /dev/null
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
        echo "Test Date: $(date)"
        echo "Memory Limit: $MEM_LIMIT"
        echo "Threads: $THREADS"
        echo "Algorithms: $ALGOS"
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
    echo 0 | sudo tee /sys/module/zswap/parameters/enabled > /dev/null 2>&1
    
    # 删除 cgroup v2
    sudo rmdir /sys/fs/cgroup/zswap_bench 2>/dev/null || true
    
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
