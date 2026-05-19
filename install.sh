#!/bin/bash

# =========================================================
# 流量监控与自动限速 一键安装脚本
#
# 功能：
# - 实时统计上下行总流量（RX+TX）
# - 自动识别主网卡
# - 80% 邮件提醒
# - 90% 自动限速 50Mbps
# - 每月自动重置
# =========================================================

set -e

echo "================================================="
echo " 流量监控与自动限速 一键安装"
echo "================================================="
echo

# =========================================================
# 自动识别网卡
# =========================================================

INTERFACE=$(ip route get 1.1.1.1 | awk '{print $5; exit}')

echo "检测到主网卡：$INTERFACE"
echo

# =========================================================
# 用户输入
# =========================================================

read -p "请输入 VPS 名称（例如 Tokyo-Emby）: " VPS_NAME

read -p "请输入月流量上限（单位GB，默认2000）: " LIMIT_GB
LIMIT_GB=${LIMIT_GB:-2000}

read -p "请输入 Gmail 邮箱（用于报警）: " ALERT_EMAIL

echo
echo "请提前准备 Google 应用专用密码："
echo "https://myaccount.google.com/apppasswords"
echo

read -p "请输入 Gmail 应用专用密码: " GMAIL_APP_PASSWORD
GMAIL_APP_PASSWORD=$(echo "$GMAIL_APP_PASSWORD" | xargs)

echo
echo

read -p "请输入当前本月已使用流量（GB，例如138）: " USED_GB

# =========================================================
# 安装依赖
# =========================================================

echo
echo ">>> 安装依赖..."

apt update

apt install -y \
bc \
mailutils \
msmtp \
msmtp-mta \
iproute2 \
ca-certificates \
curl

# =========================================================
# 配置 msmtp
# =========================================================

echo
echo ">>> 配置 Gmail SMTP..."

cat > /etc/msmtprc <<EOF
defaults
auth           on
tls            on
tls_trust_file /etc/ssl/certs/ca-certificates.crt

account        gmail
host           smtp.gmail.com
port           587
from           $ALERT_EMAIL
user           $ALERT_EMAIL
password       $GMAIL_APP_PASSWORD

account default : gmail
EOF

chmod 600 /etc/msmtprc

# =========================================================
# 创建监控脚本
# =========================================================

echo
echo ">>> 创建流量监控脚本..."

cat > /usr/local/bin/check_bandwidth.sh <<EOF
#!/bin/bash

# =========================================================
# 实时流量监控
# =========================================================

VPS_NAME="$VPS_NAME"

INTERFACE="$INTERFACE"

LIMIT_GB=$LIMIT_GB

LIMIT_BYTES=\$((LIMIT_GB * 1024 * 1024 * 1024))
LIMIT_80_BYTES=\$((LIMIT_BYTES * 80 / 100))
LIMIT_90_BYTES=\$((LIMIT_BYTES * 90 / 100))

ALERT_EMAIL="$ALERT_EMAIL"

LOG_FILE="/var/log/bandwidth_check.log"

STATE_DIR="/var/lib/bandwidth_monitor"

BASE_FILE="\$STATE_DIR/base_bytes"

ALERT_FLAG_FILE="\$STATE_DIR/alert_sent.flag"

STATUS_FILE="\$STATE_DIR/current_status"

mkdir -p "\$STATE_DIR"

# =========================================================
# 获取公网IP
# =========================================================

PUBLIC_IP=\$(curl -s ipv4.icanhazip.com || echo "Unknown")

# =========================================================
# 获取实时上下行累计流量
# =========================================================

RX_BYTES=\$(cat /sys/class/net/\$INTERFACE/statistics/rx_bytes)
TX_BYTES=\$(cat /sys/class/net/\$INTERFACE/statistics/tx_bytes)

CURRENT_TOTAL_BYTES=\$((RX_BYTES + TX_BYTES))

# =========================================================
# 初始化月基线
# =========================================================

if [ ! -f "\$BASE_FILE" ]; then

    echo "\$CURRENT_TOTAL_BYTES" > "\$BASE_FILE"

    echo "\$(date): [\$VPS_NAME] 初始化月流量基线" >> "\$LOG_FILE"
fi

BASE_BYTES=\$(cat "\$BASE_FILE")

# =========================================================
# 计算本月流量
# =========================================================

MONTH_USAGE_BYTES=\$((CURRENT_TOTAL_BYTES - BASE_BYTES))

if [ "\$MONTH_USAGE_BYTES" -lt 0 ]; then
    MONTH_USAGE_BYTES=0
fi

# =========================================================
# 月初自动重置
# =========================================================

DAY=\$(date +%d)

if [ "\$DAY" = "01" ]; then

    CURRENT_MONTH=\$(date +%Y-%m)

    MONTH_MARK_FILE="\$STATE_DIR/reset_\$CURRENT_MONTH"

    if [ ! -f "\$MONTH_MARK_FILE" ]; then

        echo "\$CURRENT_TOTAL_BYTES" > "\$BASE_FILE"

        rm -f "\$ALERT_FLAG_FILE"

        rm -f "\$STATUS_FILE"

        touch "\$MONTH_MARK_FILE"

        tc qdisc del dev \$INTERFACE root 2>/dev/null

        echo "\$(date): [\$VPS_NAME] 月初重置完成" >> "\$LOG_FILE"
    fi
fi

# =========================================================
# 格式化显示
# =========================================================

CURRENT_GB=\$(awk "BEGIN {printf \\"%.2f\\", \$MONTH_USAGE_BYTES/1024/1024/1024}")

PERCENT=\$(awk "BEGIN {printf \\"%.2f\\", \$MONTH_USAGE_BYTES*100/\$LIMIT_BYTES}")

REMAIN_GB=\$(awk "BEGIN {printf \\"%.2f\\", (\$LIMIT_BYTES-\$MONTH_USAGE_BYTES)/1024/1024/1024}")

# =========================================================
# 邮件提醒
# =========================================================

send_alert_email() {

SUBJECT="[\$VPS_NAME] 流量警告"

BODY="VPS 流量警告

VPS名称：\${VPS_NAME}
公网IP：\${PUBLIC_IP}
网卡：\${INTERFACE}

当前总流量：\${CURRENT_GB} GB
占用率：\${PERCENT}%
剩余流量：\${REMAIN_GB} GB

系统已自动进入流量保护模式。"

echo "\$BODY" | mail -s "\$SUBJECT" "\$ALERT_EMAIL"

}

# =========================================================
# 当前状态
# =========================================================

CURRENT_STATUS="normal"

if [ "\$MONTH_USAGE_BYTES" -ge "\$LIMIT_90_BYTES" ]; then

    CURRENT_STATUS="limited"

elif [ "\$MONTH_USAGE_BYTES" -ge "\$LIMIT_80_BYTES" ]; then

    CURRENT_STATUS="warning"

fi

# =========================================================
# 读取旧状态
# =========================================================

OLD_STATUS="unknown"

if [ -f "\$STATUS_FILE" ]; then
    OLD_STATUS=\$(cat "\$STATUS_FILE")
fi

# =========================================================
# 状态变化处理
# =========================================================

if [ "\$CURRENT_STATUS" != "\$OLD_STATUS" ]; then

    echo "\$CURRENT_STATUS" > "\$STATUS_FILE"

    # =====================================================
    # warning
    # =====================================================

    if [ "\$CURRENT_STATUS" = "warning" ]; then

        if [ ! -f "\$ALERT_FLAG_FILE" ]; then

            send_alert_email

            touch "\$ALERT_FLAG_FILE"

        fi

        echo "\$(date): [\$VPS_NAME] 流量警告 - 当前总流量 \${CURRENT_GB} GB，占用率 \${PERCENT}%" >> "\$LOG_FILE"

    # =====================================================
    # limited
    # =====================================================

    elif [ "\$CURRENT_STATUS" = "limited" ]; then

        tc qdisc del dev \$INTERFACE root 2>/dev/null

        tc qdisc add dev \$INTERFACE root handle 1: tbf rate 50mbit burst 32kbit latency 400ms

        echo "\$(date): [\$VPS_NAME] 已启动限速 - 当前总流量 \${CURRENT_GB} GB，占用率 \${PERCENT}% - 限速 50Mbps" >> "\$LOG_FILE"

    # =====================================================
    # normal
    # =====================================================

    elif [ "\$CURRENT_STATUS" = "normal" ]; then

        tc qdisc del dev \$INTERFACE root 2>/dev/null

        echo "\$(date): [\$VPS_NAME] 流量恢复正常 - 当前总流量 \${CURRENT_GB} GB，占用率 \${PERCENT}%" >> "\$LOG_FILE"

    fi

fi
EOF

chmod +x /usr/local/bin/check_bandwidth.sh

# =========================================================
# 设置当前已用流量
# =========================================================

echo
echo ">>> 设置当前已使用流量..."

RX=$(cat /sys/class/net/$INTERFACE/statistics/rx_bytes)

TX=$(cat /sys/class/net/$INTERFACE/statistics/tx_bytes)

TOTAL=$((RX + TX))

BASE=$((TOTAL - USED_GB * 1024 * 1024 * 1024))

mkdir -p /var/lib/bandwidth_monitor

echo $BASE > /var/lib/bandwidth_monitor/base_bytes

# =========================================================
# 配置 cron
# =========================================================

echo
echo ">>> 配置定时任务..."

CRON_JOB="*/30 * * * * /usr/local/bin/check_bandwidth.sh"

(crontab -l 2>/dev/null | grep -v check_bandwidth.sh; echo "$CRON_JOB") | crontab -

# =========================================================
# 发送测试邮件
# =========================================================

echo
echo ">>> 发送测试邮件..."

echo "[$VPS_NAME] 邮件测试成功" | mail -s "[$VPS_NAME] 测试邮件" "$ALERT_EMAIL"

# =========================================================
# 首次运行
# =========================================================

echo
echo ">>> 首次运行脚本..."

/usr/local/bin/check_bandwidth.sh

echo
echo "================================================="
echo " 安装完成"
echo "================================================="
echo
echo "VPS名称：$VPS_NAME"
echo "主网卡：$INTERFACE"
echo "流量上限：${LIMIT_GB}GB"
echo
echo "日志文件："
echo "  /var/log/bandwidth_check.log"
echo
echo "查看日志："
echo "  cat /var/log/bandwidth_check.log"
echo
echo "查看限速状态："
echo "  tc qdisc show dev $INTERFACE"
echo
echo "取消限速："
echo "  sudo tc qdisc del dev $INTERFACE root"
echo
echo "查看定时任务："
echo "  crontab -l"
echo
echo "================================================="
