#!/bin/bash

# 检查是否以 root 权限运行
if [ "$(id -u)" -ne 0 ]; then
  echo "请以 root 或使用 sudo 运行此脚本。" >&2
  exit 1
fi

echo "开始设置自动关机守护进程..."

# 0. 依赖检查和安装
echo "检查并安装依赖 (bc, cron)..."
DEPS_INSTALLED=true
if ! command -v bc &> /dev/null; then
    echo "未找到 'bc' 命令，尝试安装..."
    if apt-get update && apt-get install -y bc; then
        echo "'bc' 安装成功。"
    else
        echo "错误: 'bc' 安装失败。请手动安装后重试。" >&2
        DEPS_INSTALLED=false
    fi
else
    echo "'bc' 已安装。"
fi

# cron 用于非 systemd 环境下的开机启动
if ! command -v cron &> /dev/null; then
    echo "未找到 'cron' 命令，尝试安装..."
    # apt-get update 已经在上面执行过了（如果bc需要安装）
    if apt-get install -y cron; then
        echo "'cron' 安装成功。"
        # 某些最小系统可能需要手动启动 cron 服务
        if command -v systemctl &> /dev/null && [[ "$(ps -p 1 -o comm=)" == "systemd" ]]; then
            systemctl enable cron
            systemctl start cron
        elif command -v service &> /dev/null; then
             service cron start
        fi
    else
        echo "错误: 'cron' 安装失败。" >&2
        DEPS_INSTALLED=false
    fi
else
    echo "'cron' 已安装。"
    # 确保cron服务正在运行 (在非systemd环境下可能需要手动启动)
    if ! pgrep -x "cron" > /dev/null && ! pgrep -x "crond" > /dev/null; then
        if command -v systemctl &> /dev/null && [[ "$(ps -p 1 -o comm=)" == "systemd" ]]; then
             if ! systemctl is-active --quiet cron; then
                echo "Cron 服务未运行，尝试启动..."
                systemctl start cron
                systemctl enable cron # 确保开机自启
             fi
        elif command -v service &> /dev/null; then
            echo "Cron 服务未运行，尝试使用 'service cron start' 启动..."
            service cron start
        else
            echo "警告: Cron 服务未运行，且无法自动启动。开机自启可能无法工作。"
        fi
    fi
fi

if ! $DEPS_INSTALLED; then
    echo "部分依赖安装失败，请检查并手动安装后重试。"
    exit 1
fi


# 确保nvidia-smi可用
if ! command -v nvidia-smi &> /dev/null; then
    echo "警告: 'nvidia-smi' 命令未找到。GPU监控将无法工作。"
fi

# 1. 定义路径和文件名
SCRIPT_DIR_IN_REPO=$(dirname "$0")
INSTALL_DIR="/opt/auto-shutdown-daemon"
MONITOR_SCRIPT_NAME="auto_shutdown_monitor.sh"
MONITOR_SCRIPT_PATH="$INSTALL_DIR/$MONITOR_SCRIPT_NAME"
SERVICE_FILE_NAME="auto-shutdown.service" # systemd 服务名
LOG_FILE="/var/log/auto_shutdown.log" # 由监控脚本自身写入

# 2. 创建安装目录
echo "创建安装目录: $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

# 3. 复制监控脚本并设置权限
echo "复制监控脚本 $MONITOR_SCRIPT_NAME 到 $INSTALL_DIR/"
cp "$SCRIPT_DIR_IN_REPO/$MONITOR_SCRIPT_NAME" "$MONITOR_SCRIPT_PATH"
if [ $? -ne 0 ]; then
    echo "错误: 复制 $MONITOR_SCRIPT_NAME 失败。" >&2
    exit 1
fi
chmod +x "$MONITOR_SCRIPT_PATH"

# 4. 创建日志文件 (监控脚本会追加写入)
echo "确保日志文件存在: $LOG_FILE"
touch "$LOG_FILE"
chown root:root "$LOG_FILE" # 或者脚本执行的用户
chmod 644 "$LOG_FILE"

# 5. 检测 PID 1 是否为 systemd
INIT_SYSTEM="unknown"
if [[ "$(ps -p 1 -o comm=)" == "systemd" ]]; then
    INIT_SYSTEM="systemd"
    echo "检测到 systemd 作为 init 系统。"
else
    echo "未检测到 systemd 作为 init 系统 (PID 1 is $(ps -p 1 -o comm=)). 将使用 nohup + cron 作为备选方案。"
    INIT_SYSTEM="other"
fi

# 停止任何可能已存在的旧版本进程
echo "尝试停止任何已存在的监控脚本实例..."
pkill -f "$MONITOR_SCRIPT_NAME"
# 如果使用systemd，也尝试停止服务
if [ "$INIT_SYSTEM" == "systemd" ]; then
    if systemctl list-units --full -all | grep -q "$SERVICE_FILE_NAME"; then
        systemctl stop "$SERVICE_FILE_NAME" >/dev/null 2>&1
    fi
fi


if [ "$INIT_SYSTEM" == "systemd" ]; then
    # 使用 Systemd
    SERVICE_FILE_PATH_SYSTEMD="/etc/systemd/system/$SERVICE_FILE_NAME"
    SERVICE_FILE_PATH_REPO="$SCRIPT_DIR_IN_REPO/$SERVICE_FILE_NAME" # 仓库中的模板

    echo "复制 Systemd 服务文件 $SERVICE_FILE_NAME 到 $SERVICE_FILE_PATH_SYSTEMD"
    cp "$SERVICE_FILE_PATH_REPO" "$SERVICE_FILE_PATH_SYSTEMD"
    if [ $? -ne 0 ]; then
        echo "错误: 复制 $SERVICE_FILE_NAME 失败。" >&2
        exit 1
    fi

    echo "重载 Systemd 配置..."
    systemctl daemon-reload
    echo "启用服务 $SERVICE_FILE_NAME 以开机自启..."
    systemctl enable "$SERVICE_FILE_NAME"
    echo "启动服务 $SERVICE_FILE_NAME..."
    systemctl start "$SERVICE_FILE_NAME"
    echo "检查服务状态:"
    systemctl status "$SERVICE_FILE_NAME" --no-pager
else
    # 非 Systemd 环境 (例如 Docker 容器内无 systemd作为PID 1)
    echo "使用 nohup 启动监控脚本..."
    # 确保日志文件存在且脚本可写
    nohup "$MONITOR_SCRIPT_PATH" >> "$LOG_FILE" 2>&1 &
    
    # 检查进程是否启动
    sleep 2 # 给点时间启动
    if pgrep -f "$MONITOR_SCRIPT_NAME" > /dev/null; then
        echo "监控脚本已通过 nohup 启动。PID: $(pgrep -f "$MONITOR_SCRIPT_NAME")"
    else
        echo "错误: 使用 nohup 启动监控脚本失败。请查看日志 $LOG_FILE。"
        exit 1
    fi

    echo "设置 cron 任务以实现开机自启 (容器重启后)..."
    # 构建cron命令，确保日志重定向
    CRON_JOB_CMD="$MONITOR_SCRIPT_PATH >> $LOG_FILE 2>&1"
    # 移除旧的cron条目 (如果有)
    (crontab -l 2>/dev/null | grep -v "$MONITOR_SCRIPT_PATH" ; echo "@reboot $CRON_JOB_CMD") | crontab -
    if [ $? -eq 0 ]; then
        echo "Cron 任务设置成功。"
        echo "当前 crontab 内容:"
        crontab -l
    else
        echo "错误: 设置 Cron 任务失败。"
    fi
fi

echo ""
echo "自动关机守护进程设置完成。"
echo "配置文件位于: $MONITOR_SCRIPT_PATH"
echo "日志文件位于: $LOG_FILE"

if [ "$INIT_SYSTEM" == "systemd" ]; then
    echo "若要修改配置，请编辑 $MONITOR_SCRIPT_PATH 文件，然后使用 'sudo systemctl restart $SERVICE_FILE_NAME' 重启服务。"
    echo "查看服务日志: 'sudo journalctl -u $SERVICE_FILE_NAME -f' 或 'tail -f $LOG_FILE'"
else
    echo "若要修改配置，请编辑 $MONITOR_SCRIPT_PATH 文件，然后你需要手动停止脚本 (sudo pkill -f $MONITOR_SCRIPT_NAME) 并重新用 nohup 启动它。"
    echo "查看脚本日志: 'tail -f $LOG_FILE'"
    echo "脚本正在后台运行。你可以使用 'ps aux | grep $MONITOR_SCRIPT_NAME' 来检查。"
fi

exit 0
