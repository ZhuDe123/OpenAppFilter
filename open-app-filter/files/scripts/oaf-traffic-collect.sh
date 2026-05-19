#!/bin/sh
# /etc/oaf/scripts/oaf-traffic-collect.sh
# OAF 流量统计采集循环，由 procd 管理
# 参数 1: 采集间隔（秒），默认 60

COLLECT_INTERVAL=${1:-60}
LOG_FILE="/tmp/oaf/traffic.log"
PERSIST_COUNT=0
PERSIST_INTERVAL=30  # 默认每 30 次采集备份一次

while true; do
    /usr/bin/ucode /etc/oaf/ucode/traffic.uc collect

    # 定期备份
    PERSIST_COUNT=$((PERSIST_COUNT + 1))
    # 从 UCI 读取备份间隔
    local persist_min=$(uci get appfilter.traffic.persist_interval 2>/dev/null || echo "30")
    if [ "$persist_min" != "0" ] && [ $((PERSIST_COUNT * COLLECT_INTERVAL)) -ge $((persist_min * 60)) ]; then
        /usr/bin/ucode /etc/oaf/ucode/traffic.uc persist
        PERSIST_COUNT=0
    fi

    sleep "$COLLECT_INTERVAL"
done
