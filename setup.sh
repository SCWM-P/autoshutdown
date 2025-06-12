#!/bin/bash

# 检查是否以 root 权限运行
if [ "$(id -u)" -ne 0 ]; then
  echo "请以 root 或使用 sudo 运行此脚本。" >&2
  exit 1
fi

echo "开始设置自动关机守护进程..."

# 0. 依赖检查和安装 (bc 用于数学运算)
if ! command -v bc &> /dev/null; then
    echo "未找到 'bc' 命令，尝试安装..."
    if apt-get update && apt-get install -y bc; then
        echo "'bc' 安装成功。"
    else
        echo "错误: 'bc' 安装失败。请手动安装后重试。" >&2
        exit 1
    fi
else
    echo "'bc' 已安装。"
fi

# 确保nvidia-smi可用 (在Docker内通常是挂载进来的)
if ! command -v nvidia-smi &> /dev/null; then
    echo "警告: 'nvidia-smi' 命令未找到。GPU监控将无法工作。"
    echo "如果此容器确实有GPU，请确保nvidia-smi已正确配置。"
    # 这里不退出，允许在没有GPU的机器上（或无法检测GPU时）仅基于CPU监控
fi


# 1. 定义路径和文件名
SCRIPT_DIR_IN_REPO=$(dirname "$0") # 获取 setup.sh 所在目录 (仓库中的相对路径)
INSTALL_DIR="/opt/auto-shutdown-daemon"
MONITOR_SCRIPT_NAME="auto_shutdown_monitor.sh"
SERVICE_FILE_NAME="auto-shutdown.service"
LOG_FILE="/var/log/auto_shutdown.log"

# 2. 创建安装目录
echo "创建安装目录: $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

# 3. 复制监控脚本并设置权限
echo "复制监控脚本 $MONITOR_SCRIPT_NAME 到 $INSTALL_DIR/"
cp "$SCRIPT_DIR_IN_REPO/$MONITOR_SCRIPT_NAME" "$INSTALL_DIR/"
if [ $? -ne 0 ]; then
    echo "错误: 复制 $MONITOR_SCRIPT_NAME 失败。" >&2
    exit 1
fi
chmod +x "$INSTALL_DIR/$MONITOR_SCRIPT_NAME"

# 4. 创建日志文件并设置权限 (允许服务写入)
echo "创建日志文件: $LOG_FILE"
touch "$LOG_FILE"
# 通常systemd服务以root运行，所以root会有权限，但明确设置一下也无妨
chown root:root "$LOG_FILE"
chmod 644 "$LOG_FILE" # root写，其他读

# 5. 复制并配置 Systemd 服务文件
SERVICE_FILE_PATH_SYSTEMD="/etc/systemd/system/$SERVICE_FILE_NAME"
SERVICE_FILE_PATH_REPO="$SCRIPT_DIR_IN_REPO/$SERVICE_FILE_NAME"

echo "复制 Systemd 服务文件 $SERVICE_FILE_NAME 到 $SERVICE_FILE_PATH_SYSTEMD"
# 这里我们直接从仓库复制，因为它内部的ExecStart路径已经是我们期望的绝对路径
cp "$SERVICE_FILE_PATH_REPO" "$SERVICE_FILE_PATH_SYSTEMD"
if [ $? -ne 0 ]; then
    echo "错误: 复制 $SERVICE_FILE_NAME 失败。" >&2
    exit 1
fi
# 如果服务文件是模板，需要替换路径，但我们设计为直接可用
# sed -i "s|{{EXEC_START_PATH}}|$INSTALL_DIR/$MONITOR_SCRIPT_NAME|g" "$SERVICE_FILE_PATH_SYSTEMD"

# 6. 重载 Systemd，启用并启动服务
echo "重载 Systemd 配置..."
systemctl daemon-reload

echo "启用服务 $SERVICE_FILE_NAME 以开机自启..."
systemctl enable "$SERVICE_FILE_NAME"

echo "启动服务 $SERVICE_FILE_NAME..."
systemctl start "$SERVICE_FILE_NAME"

# 7. 检查服务状态
echo "检查服务状态:"
systemctl status "$SERVICE_FILE_NAME" --no-pager

echo ""
echo "自动关机守护进程设置完成并已启动。"
echo "配置文件位于: $INSTALL_DIR/$MONITOR_SCRIPT_NAME"
echo "日志文件位于: $LOG_FILE"
echo "若要修改配置 (如阈值、超时时间)，请编辑 $INSTALL_DIR/$MONITOR_SCRIPT_NAME 文件，然后使用 'sudo systemctl restart $SERVICE_FILE_NAME' 重启服务。"
echo "可以使用 'sudo journalctl -u $SERVICE_FILE_NAME -f' 查看服务实时日志 (如果StandardOutput/Error设为journal)。"
echo "或者 'tail -f $LOG_FILE' 查看自定义日志。"

exit 0
