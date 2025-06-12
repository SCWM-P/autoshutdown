#!/bin/bash

# 检查是否以 root 权限运行
if [ "$(id -u)" -ne 0 ]; then
  echo "请以 root 或使用 sudo 运行此脚本。" >&2
  exit 1
fi

echo "开始卸载自动关机守护进程..."

INSTALL_DIR="/opt/auto-shutdown-daemon"
SERVICE_FILE_NAME="auto-shutdown.service"
LOG_FILE="/var/log/auto_shutdown.log"
SERVICE_FILE_PATH_SYSTEMD="/etc/systemd/system/$SERVICE_FILE_NAME"

# 1. 停止服务
echo "停止服务 $SERVICE_FILE_NAME..."
systemctl stop "$SERVICE_FILE_NAME"

# 2. 禁用服务 (取消开机自启)
echo "禁用服务 $SERVICE_FILE_NAME..."
systemctl disable "$SERVICE_FILE_NAME"

# 3. 删除 Systemd 服务文件
if [ -f "$SERVICE_FILE_PATH_SYSTEMD" ]; then
    echo "删除 Systemd 服务文件 $SERVICE_FILE_PATH_SYSTEMD..."
    rm "$SERVICE_FILE_PATH_SYSTEMD"
else
    echo "Systemd 服务文件 $SERVICE_FILE_PATH_SYSTEMD 未找到。"
fi

# 4. 重载 Systemd 配置
echo "重载 Systemd 配置..."
systemctl daemon-reload
systemctl reset-failed # 清理可能存在的失败状态

# 5. 删除安装目录
if [ -d "$INSTALL_DIR" ]; then
    echo "删除安装目录 $INSTALL_DIR..."
    rm -rf "$INSTALL_DIR"
else
    echo "安装目录 $INSTALL_DIR 未找到。"
fi

# 6. (可选) 删除日志文件
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
