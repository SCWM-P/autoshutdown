#!/bin/bash

# 检查是否以 root 权限运行
if [ "$(id -u)" -ne 0 ]; then
  echo "请以 root 或使用 sudo 运行此脚本。" >&2
  exit 1
fi

echo "开始卸载自动关机守护进程..."

INSTALL_DIR="/opt/auto-shutdown-daemon"
MONITOR_SCRIPT_NAME="auto_shutdown_monitor.sh"
MONITOR_SCRIPT_PATH="$INSTALL_DIR/$MONITOR_SCRIPT_NAME"
SERVICE_FILE_NAME="auto-shutdown.service"
LOG_FILE="/var/log/auto_shutdown.log"
SERVICE_FILE_PATH_SYSTEMD="/etc/systemd/system/$SERVICE_FILE_NAME"

# 1. 停止脚本/服务
echo "停止监控脚本..."
# 先尝试用 pkill，这个对 nohup 和 systemd 都可能有效 (如果 systemd 执行的是这个脚本名)
pkill -f "$MONITOR_SCRIPT_NAME"
sleep 1 # 等待进程结束

# 如果 systemd 文件存在，也尝试通过 systemctl 停止和禁用
if [ -f "$SERVICE_FILE_PATH_SYSTEMD" ]; then
    echo "检测到 Systemd 服务文件，尝试停止和禁用..."
    if systemctl list-units --full -all | grep -q "$SERVICE_FILE_NAME"; then # 检查服务是否存在于systemd
        systemctl stop "$SERVICE_FILE_NAME" >/dev/null 2>&1
        systemctl disable "$SERVICE_FILE_NAME" >/dev/null 2>&1
    fi
    echo "删除 Systemd 服务文件 $SERVICE_FILE_PATH_SYSTEMD..."
    rm -f "$SERVICE_FILE_PATH_SYSTEMD"
    echo "重载 Systemd 配置..."
    systemctl daemon-reload >/dev/null 2>&1
    systemctl reset-failed >/dev/null 2>&1
fi

# 2. 移除 cron 任务 (如果存在)
echo "移除相关的 cron 任务..."
if command -v crontab &> /dev/null; then
    (crontab -l 2>/dev/null | grep -v "$MONITOR_SCRIPT_PATH") | crontab -
    if [ $? -eq 0 ]; then
        echo "Cron 任务已检查并清理。"
    else
        echo "警告: 清理 Cron 任务时可能出错，或者没有crontab。"
    fi
else
    echo "警告: crontab 命令不存在，无法自动清理 cron 任务。"
fi


# 3. 删除安装目录
if [ -d "$INSTALL_DIR" ]; then
    echo "删除安装目录 $INSTALL_DIR..."
    rm -rf "$INSTALL_DIR"
else
    echo "安装目录 $INSTALL_DIR 未找到。"
fi

# 4. (可选) 删除日志文件
read -p "是否删除日志文件 $LOG_FILE? [y/N]: " confirm_delete_log
if [[ "$confirm_delete_log" =~ ^[Yy]$ ]]; then
    if [ -f "$LOG_FILE" ]; then
        echo "删除日志文件 $LOG_FILE..."
        rm "$LOG_FILE"
    else
        echo "日志文件 $LOG_FILE 未找到。"
    fi
else
    echo "保留日志文件 $LOG_FILE。"
fi

echo "自动关机守护进程卸载完成。"
exit 0
