#!/bin/bash

# --- 配置参数 ---
# ... (之前的配置参数不变) ...
CPU_IDLE_THRESHOLD_PERCENT=90
GPU_UTIL_THRESHOLD_PERCENT=5
CHECK_INTERVAL_SECONDS=60
IDLE_TIMEOUT_MINUTES=30
LOG_FILE="/var/log/auto_shutdown.log"

# 新增：需要保持系统运行的进程名列表 (部分匹配即可)
# 我们将检查命令行中是否包含这些关键字
# 注意：这可能会误判一些系统自身的python脚本，需要谨慎设置
# 或者更精确地匹配用户启动的，例如检查进程的TTY是否为pts
# 为了简单起见，我们先做关键字匹配
CRITICAL_PROCESSES_KEYWORDS=()

# --- 配置结束 ---

# ... (MAX_IDLE_CHECKS, idle_checks_count, log_message 函数不变) ...
MAX_IDLE_CHECKS=$((IDLE_TIMEOUT_MINUTES * 60 / CHECK_INTERVAL_SECONDS))
idle_checks_count=0

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# 返回值：0 表示存在关键进程，1 表示不存在
check_critical_processes() {
    for keyword in "${CRITICAL_PROCESSES_KEYWORDS[@]}"; do
        local monitor_pid=$$ # 当前脚本的PID
        if pgrep -af "$keyword" | grep -Ev "auto_shutdown_monitor.sh|$monitor_pid| pgrep " | grep -q .; then
            log_message "检测到关键进程活动: 包含 '$keyword' 的进程正在运行。"
            return 0 # 关键进程存在
        fi
    done
    return 1 # 没有关键进程
}


log_message "守护进程启动。CPU空闲阈值: ${CPU_IDLE_THRESHOLD_PERCENT}%, GPU利用率阈值: ${GPU_UTIL_THRESHOLD_PERCENT}%, 检查间隔: ${CHECK_INTERVAL_SECONDS}s, 关机前持续低活跃: ${IDLE_TIMEOUT_MINUTES}min (${MAX_IDLE_CHECKS}次检查)."
log_message "当以下任一关键字出现在进程中时，将阻止关机: ${CRITICAL_PROCESSES_KEYWORDS[*]}"

# 主循环
while true; do
    # 0. 检查是否有关键用户进程在运行
    if check_critical_processes; then
        # 如果有关键进程，则不进行空闲检查，并重置空闲计数器
        if [ $idle_checks_count -gt 0 ]; then
             log_message "检测到关键用户进程，系统保持运行。重置低活跃计数器。"
        fi
        idle_checks_count=0
        sleep "$CHECK_INTERVAL_SECONDS"
        continue # 跳过本次循环的后续空闲检查
    fi

    # 1. 检测 CPU 空闲率
    # ... (这部分不变) ...
    current_cpu_idle=$(vmstat 1 2 | tail -1 | awk '{print $15}')
    cpu_is_idle=false
    if (( $(echo "$current_cpu_idle >= $CPU_IDLE_THRESHOLD_PERCENT" | bc -l) )); then
        cpu_is_idle=true
    fi
    current_cpu_usage=$(echo "100 - $current_cpu_idle" | bc)

    # 2. 检测 GPU 利用率
    # ... (这部分不变) ...
    gpu_is_idle=true
    gpu_usages=()
    if command -v nvidia-smi &> /dev/null; then
        while IFS= read -r line; do
            util=${line//%}
            gpu_usages+=("$util")
            if (( $(echo "$util >= $GPU_UTIL_THRESHOLD_PERCENT" | bc -l) )); then
                gpu_is_idle=false
            fi
        done < <(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null)
        if [ ${#gpu_usages[@]} -eq 0 ]; then
             log_message "警告: 未检测到GPU或nvidia-smi执行失败。暂时认为GPU不空闲。"
             gpu_is_idle=false
        fi
    else
        log_message "警告: nvidia-smi 命令不存在。无法检测GPU状态，暂时认为GPU不空闲。"
        gpu_is_idle=false
    fi
    gpu_usages_str=$(IFS=, ; echo "${gpu_usages[*]}")

    # 3. 判断与决策
    if $cpu_is_idle && $gpu_is_idle; then
        idle_checks_count=$((idle_checks_count + 1))
        log_message "系统低活跃: CPU空闲 ${current_cpu_idle}% (使用率 ${current_cpu_usage}%), GPU利用率 [${gpu_usages_str}]%。连续低活跃检查次数: ${idle_checks_count}/${MAX_IDLE_CHECKS}."
    else
        if [ $idle_checks_count -gt 0 ]; then
             log_message "系统恢复活跃或关键进程未结束。重置低活跃计数器。CPU空闲 ${current_cpu_idle}% (使用率 ${current_cpu_usage}%), GPU利用率 [${gpu_usages_str}]%。"
        fi
        idle_checks_count=0
    fi

    # 4. 达到关机条件
    if [ $idle_checks_count -ge $MAX_IDLE_CHECKS ]; then
        log_message "系统已持续低活跃 ${IDLE_TIMEOUT_MINUTES} 分钟，且无关键用户进程。准备执行关机..."
        /sbin/shutdown -h now
        exit 0
    fi

    sleep "$CHECK_INTERVAL_SECONDS"
done
