#!/bin/bash

# 定义日志文件路径
LOG_FILE="/root/monitor.log"

# 定义日志文件大小限制（5MB）
LOG_SIZE_LIMIT=$((5 * 1024 * 1024))  # 5MB in bytes

# 定义日志函数
log() {
    echo "$1" >> "$LOG_FILE"
}

# 检查日志文件大小，如果超过限制则清空
if [ -f "$LOG_FILE" ] && [ $(stat -c%s "$LOG_FILE") -gt $LOG_SIZE_LIMIT ]; then
    > "$LOG_FILE"  # 清空日志文件
    echo "Log file cleared due to size exceeding 5MB." 
fi

# 获取当前时间
CURRENT_TIME=$(date '+%Y-%m-%d %H:%M:%S')

# 输出分隔符和时间
log "===== $CURRENT_TIME =====" 

# Parameter order: LIMIT_GB, reset_day, CHECK_TYPE, INTERFACE

LIMIT_GB=${1:-1024}

reset_day=${2:-1}

CHECK_TYPE=${3:-4}

INTERFACE=${4:-$(ip route | grep default | awk '{print $5}')}

LIMIT=$(echo "$LIMIT_GB * 1024" | bc)

log "流量限制：$LIMIT MiB" 

log "流量将在每月的第 $reset_day 天重置" 

current_day=$(date +'%-d')

last_day_of_month=$(date -d "$(date +'%Y%m01') +1 month -1 day" +%d)

if [ "$current_day" -eq "$reset_day" ] || ([ "$reset_day" -gt "$last_day_of_month" ] && [ "$current_day" -eq "$last_day_of_month" ]); then

  if [ ! -f "/tmp/vnstat_reset" ]; then

    touch /tmp/vnstat_reset

    rm /var/lib/vnstat/*

    sudo systemctl restart vnstat

    log "流量已经重置，下次重置将在下个月的第 $reset_day 天" 

  else

    log "今天已经进行过流量重置，无需再次重置" 

  fi

else

  if [ -f "/tmp/vnstat_reset" ]; then

    rm /tmp/vnstat_reset

  fi

  if [ "$current_day" -lt "$reset_day" ]; then

    days_until_reset=$(($reset_day - $current_day))

    log "还有 $days_until_reset 天流量将会重置" 

  else

    days_until_reset=$(( $last_day_of_month - $current_day + $reset_day ))

    log "还有 $days_until_reset 天流量将会重置" 

  fi

fi

if [ -z "$INTERFACE" ]; then

  log "错误：无法自动检测网络接口。请手动指定。" 

  exit 1

fi

log "正在监控的网络接口：$INTERFACE"

DATA=$(vnstat -i $INTERFACE --oneline)

CURRENT_DATE=$(echo $DATA | cut -d ';' -f 8)

TRAFFIC_RX=$(echo $DATA | cut -d ';' -f 13 | tr -d ' ' | sed 's/MiB//;s/GiB/*1024/;s/KiB/\/1024/' | bc)

TRAFFIC_TX=$(echo $DATA | cut -d ';' -f 14 | tr -d ' ' | sed 's/MiB//;s/GiB/*1024/;s/KiB/\/1024/' | bc)

log "当前月份：$CURRENT_DATE"

if [ "$CHECK_TYPE" = "1" ]; then

  TRAFFIC_TO_CHECK=$TRAFFIC_TX

  log "只检查上传流量。当前上传流量为：$TRAFFIC_TX MiB。"

  log "当前对比项是：上传流量。"

elif [ "$CHECK_TYPE" = "2" ]; then

  TRAFFIC_TO_CHECK=$TRAFFIC_RX

  log "只检查下载流量。当前下载流量为：$TRAFFIC_RX MiB。"

  log "当前对比项是：下载流量。"

elif [ "$CHECK_TYPE" = "3" ]; then

  TRAFFIC_TO_CHECK=$(echo "$TRAFFIC_TX $TRAFFIC_RX" | awk '{print ($1>$2)?$1:$2}')

  if [ "$TRAFFIC_TO_CHECK" = "$TRAFFIC_TX" ]; then

    log "当前上传流量为：$TRAFFIC_TX MiB，下载流量为：$TRAFFIC_RX MiB。"

    log "作为比较的流量是：上传流量。"

  else

    log "当前上传流量为：$TRAFFIC_TX MiB，下载流量为：$TRAFFIC_RX MiB。"

    log "作为比较的流量是：下载流量。"

  fi

elif [ "$CHECK_TYPE" = "4" ]; then

  TRAFFIC_TO_CHECK=$(echo "$TRAFFIC_TX + $TRAFFIC_RX" | bc)

  log "检查上传和下载流量的总和。当前上传流量为：$TRAFFIC_TX MiB，下载流量为：$TRAFFIC_RX MiB。"

  log "作为比较的流量是：上传和下载流量的总和（$TRAFFIC_TO_CHECK MiB）。"

else

  log "错误：未提供有效的流量检查参数。参数应为1（只检查上传流量）、2（只检查下载流量）、3（检查上传和下载流量中的最大值）或4（检查上传和下载流量的总和）。"

  exit 1

fi

if (( $(echo "$TRAFFIC_TO_CHECK > $LIMIT" | bc -l) )); then

  iptables -F

  iptables -X

  iptables -P INPUT DROP

  iptables -P FORWARD DROP

  iptables -P OUTPUT ACCEPT

  iptables -A INPUT -p tcp --dport 22 -j ACCEPT

  iptables -A INPUT -i lo -j ACCEPT

  iptables -A OUTPUT -o lo -j ACCEPT

  log "警告：流量已超出限制！除SSH（端口22）外，所有端口已被阻止。"

else

  iptables -P INPUT ACCEPT

  iptables -P OUTPUT ACCEPT

  iptables -P FORWARD ACCEPT

  iptables -F

  log "流量在设定的限制内，所有流量都被允许。"

fi