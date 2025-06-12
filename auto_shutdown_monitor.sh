#!/bin/bash

# --- 配置参数 ---
# CPU 空闲阈值 (百分比)。如果 CPU 空闲超过此值，则认为 CPU 低活跃。
# 例如，95 表示 CPU 使用率低于 5% 时认为是低活跃。
CPU_IDLE_THRESHOLD_PERCENT=95

# GPU 利用率阈值 (百分比)。如果所有 GPU 利用率都低于此值，则认为 GPU 低活跃。
GPU_UTIL_THRESHOLD_PERCENT=5

# 检查间隔时间 (秒)
CHECK_INTERVAL_SECONDS=60

# 持续低活跃多久后关机 (分钟)
IDLE_TIMEOUT_MINUTES=30

# 日志文件路径
LOG_FILE="/var/log/auto_shutdown.log"
# --- 配置结束 ---

# 将分钟转换为检查次数
MAX_IDLE_CHECKS=$((IDLE_TIMEOUT_MINUTES * 60 / CHECK_INTERVAL_SECONDS))

# 当前持续低活跃的检查次数
idle_checks_count=0

# 日志函数
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

log_message "守护进程启动。CPU空闲阈值: ${CPU_IDLE_THRESHOLD_PERCENT}%, GPU利用率阈值: ${GPU_UTIL_THRESHOLD_PERCENT}%, 检查间隔: ${CHECK_INTERVAL_SECONDS}s, 关机前持续低活跃: ${IDLE_TIMEOUT_MINUTES}min (${MAX_IDLE_CHECKS}次检查)."

# 主循环
while true; do
    # 1. 检测 CPU 空闲率
    # vmstat 的输出中，第15列是空闲百分比 (id)
    # 我们取两次采样间隔1秒，取第二次的采样结果
    current_cpu_idle=$(vmstat 1 2 | tail -1 | awk '{print $15}')

    cpu_is_idle=false
    if (( $(echo "$current_cpu_idle >= $CPU_IDLE_THRESHOLD_PERCENT" | bc -l) )); then
        cpu_is_idle=true
    fi
    # 将CPU使用率也记录一下，方便调试
    current_cpu_usage=$(echo "100 - $current_cpu_idle" | bc)


    # 2. 检测 GPU 利用率
    # nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits
    # 会输出每个GPU的利用率，每行一个
    gpu_is_idle=true # 默认为 true，如果任何一个GPU活跃，则设为 false
    gpu_usages=() # 存储每个GPU的使用率
    if command -v nvidia-smi &> /dev/null; then
        while IFS= read -r line; do
            # 去掉可能存在的 % 符号 (虽然 --nounits 应该会去掉)
            util=${line//%}
            gpu_usages+=("$util")
            if (( $(echo "$util >= $GPU_UTIL_THRESHOLD_PERCENT" | bc -l) )); then
                gpu_is_idle=false
                # 由于我们关心的是“所有GPU都空闲”，一旦发现一个不空闲，就可以停止检查其他GPU
                # 但为了日志完整，我们还是继续获取所有GPU的使用率
            fi
        done < <(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null)

        if [ ${#gpu_usages[@]} -eq 0 ]; then
             # 如果没有检测到GPU (nvidia-smi可能出错了或没有GPU)，我们保守地认为GPU不空闲，或者根据实际需要调整此逻辑
             log_message "警告: 未检测到GPU或nvidia-smi执行失败。暂时认为GPU不空闲。"
             gpu_is_idle=false
        fi
    else
        log_message "警告: nvidia-smi 命令不存在。无法检测GPU状态，暂时认为GPU不空闲。"
        gpu_is_idle=false # 没有nvidia-smi，认为GPU不空闲
    fi
    gpu_usages_str=$(IFS=, ; echo "${gpu_usages[*]}")


    # 3. 判断与决策
    if $cpu_is_idle && $gpu_is_idle; then
        idle_checks_count=$((idle_checks_count + 1))
        log_message "系统低活跃: CPU空闲 ${current_cpu_idle}% (使用率 ${current_cpu_usage}%), GPU利用率 [${gpu_usages_str}]%。连续低活跃检查次数: ${idle_checks_count}/${MAX_IDLE_CHECKS}."
    else
        if [ $idle_checks_count -gt 0 ]; then
             log_message "系统恢复活跃。重置低活跃计数器。CPU空闲 ${current_cpu_idle}% (使用率 ${current_cpu_usage}%), GPU利用率 [${gpu_usages_str}]%。"
        fi
        idle_checks_count=0 # 重置计数器
    fi

    # 4. 达到关机条件
    if [ $idle_checks_count -ge $MAX_IDLE_CHECKS ]; then
        log_message "系统已持续低活跃 ${IDLE_TIMEOUT_MINUTES} 分钟。准备执行关机..."
        # 在Docker容器内，这通常会停止容器
        /sbin/shutdown -h now
        # 如果shutdown命令由于某种原因没能终止脚本，这里加个exit确保循环停止
        exit 0
    fi

    sleep "$CHECK_INTERVAL_SECONDS"
done
