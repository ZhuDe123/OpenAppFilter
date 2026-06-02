#!/bin/bash

# ==========================================
# OAF 流量统计数据库一致性验证脚本
# 功能：验证 traffic_daily, monthly, yearly, minute, ip_daily 数据是否对齐
# 作者：助手
# 时间：2026-06-01
# ==========================================

DB_PATH="/tmp/oaf/traffic.db"
LOG_FILE="/tmp/oaf/verify_traffic.log"

# 日志函数
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [VERIFY] $*" | tee -a "$LOG_FILE"
}

# 检查数据库是否存在
if [ ! -f "$DB_PATH" ]; then
    echo "错误：数据库文件 $DB_PATH 不存在！"
    exit 1
fi

log "开始执行流量数据一致性验证..."

# 获取当前日期用于查询
TODAY=$(date '+%Y-%m-%d')
CURRENT_MONTH=$(date '+%Y-%m')
CURRENT_YEAR=$(date '+%Y')

# 用于存储结果的关联数组 (Bash 4+)
declare -A RESULTS

# ==========================================
# 1. 验证：分钟表 (traffic_minute) 汇总是否等于 日表 (traffic_daily)
# ==========================================
log "验证 1/5: 分钟表汇总 vs 日表 (Today: $TODAY)"

MINUTE_UP=$(sqlite3 "$DB_PATH" "SELECT COALESCE(SUM(upload), 0) FROM traffic_minute WHERE date = '$TODAY';")
MINUTE_DOWN=$(sqlite3 "$DB_PATH" "SELECT COALESCE(SUM(download), 0) FROM traffic_minute WHERE date = '$TODAY';")

DAILY_UP=$(sqlite3 "$DB_PATH" "SELECT COALESCE(upload, 0) FROM traffic_daily WHERE date = '$TODAY';")
DAILY_DOWN=$(sqlite3 "$DB_PATH" "SELECT COALESCE(download, 0) FROM traffic_daily WHERE date = '$TODAY';")

# 计算差异
DIFF_UP=$((MINUTE_UP - DAILY_UP))
DIFF_DOWN=$((MINUTE_DOWN - DAILY_DOWN))

RESULTS["Minute_Daily_Up_Diff"]=$DIFF_UP
RESULTS["Minute_Daily_Down_Diff"]=$DIFF_DOWN

if [ $DIFF_UP -eq 0 ] && [ $DIFF_DOWN -eq 0 ]; then
    log "   通过: 分钟表汇总与日表完全一致。"
    log "   数据: 日表(U:$DAILY_UP D:$DAILY_DOWN) = 分钟汇总(U:$MINUTE_UP D:$MINUTE_DOWN)"
else
    log "   警告: 存在差异！日表(U:$DAILY_UP D:$DAILY_DOWN) vs 分钟汇总(U:$MINUTE_UP D:$MINUTE_DOWN)"
    log "   差异: 上传差值=$DIFF_UP 字节, 下载差值=$DIFF_DOWN 字节"
fi

# ==========================================
# 2. 验证：日表 (traffic_daily) 汇总是否等于 月表 (traffic_monthly)
# ==========================================
log "验证 2/5: 日表汇总 vs 月表 (Month: $CURRENT_MONTH)"

DAILY_SUM_UP=$(sqlite3 "$DB_PATH" "SELECT COALESCE(SUM(upload), 0) FROM traffic_daily WHERE date LIKE '$CURRENT_MONTH%';")
DAILY_SUM_DOWN=$(sqlite3 "$DB_PATH" "SELECT COALESCE(SUM(download), 0) FROM traffic_daily WHERE date LIKE '$CURRENT_MONTH%';")

MONTHLY_UP=$(sqlite3 "$DB_PATH" "SELECT COALESCE(upload, 0) FROM traffic_monthly WHERE month = '$CURRENT_MONTH';")
MONTHLY_DOWN=$(sqlite3 "$DB_PATH" "SELECT COALESCE(download, 0) FROM traffic_monthly WHERE month = '$CURRENT_MONTH';")

DIFF_UP=$((DAILY_SUM_UP - MONTHLY_UP))
DIFF_DOWN=$((DAILY_SUM_DOWN - MONTHLY_DOWN))

RESULTS["Daily_Monthly_Up_Diff"]=$DIFF_UP
RESULTS["Daily_Monthly_Down_Diff"]=$DIFF_DOWN

if [ $DIFF_UP -eq 0 ] && [ $DIFF_DOWN -eq 0 ]; then
    log "   通过: 日表汇总与月表完全一致。"
    log "   数据: 月表(U:$MONTHLY_UP D:$MONTHLY_DOWN) = 日汇总(U:$DAILY_SUM_UP D:$DAILY_SUM_DOWN)"
else
    log "   警告: 存在差异！月表(U:$MONTHLY_UP D:$MONTHLY_DOWN) vs 日汇总(U:$DAILY_SUM_UP D:$DAILY_SUM_DOWN)"
    log "   差异: 上传差值=$DIFF_UP 字节, 下载差值=$DIFF_DOWN 字节"
fi

# ==========================================
# 3. 验证：月表 (traffic_monthly) 汇总是否等于 年表 (traffic_yearly)
# ==========================================
log "验证 3/5: 月表汇总 vs 年表 (Year: $CURRENT_YEAR)"

MONTHLY_SUM_UP=$(sqlite3 "$DB_PATH" "SELECT COALESCE(SUM(upload), 0) FROM traffic_monthly WHERE month LIKE '$CURRENT_YEAR%';")
MONTHLY_SUM_DOWN=$(sqlite3 "$DB_PATH" "SELECT COALESCE(SUM(download), 0) FROM traffic_monthly WHERE month LIKE '$CURRENT_YEAR%';")

YEARLY_UP=$(sqlite3 "$DB_PATH" "SELECT COALESCE(upload, 0) FROM traffic_yearly WHERE year = '$CURRENT_YEAR';")
YEARLY_DOWN=$(sqlite3 "$DB_PATH" "SELECT COALESCE(download, 0) FROM traffic_yearly WHERE year = '$CURRENT_YEAR';")

DIFF_UP=$((MONTHLY_SUM_UP - YEARLY_UP))
DIFF_DOWN=$((MONTHLY_SUM_DOWN - YEARLY_DOWN))

RESULTS["Monthly_Yearly_Up_Diff"]=$DIFF_UP
RESULTS["Monthly_Yearly_Down_Diff"]=$DIFF_DOWN

if [ $DIFF_UP -eq 0 ] && [ $DIFF_DOWN -eq 0 ]; then
    log "   通过: 月表汇总与年表完全一致。"
    log "   数据: 年表(U:$YEARLY_UP D:$YEARLY_DOWN) = 月汇总(U:$MONTHLY_SUM_UP D:$MONTHLY_SUM_DOWN)"
else
    log "   警告: 存在差异！年表(U:$YEARLY_UP D:$YEARLY_DOWN) vs 月汇总(U:$MONTHLY_SUM_UP D:$MONTHLY_SUM_DOWN)"
    log "   差异: 上传差值=$DIFF_UP 字节, 下载差值=$DIFF_DOWN 字节"
fi

# ==========================================
# 4. 验证：IP明细表 (traffic_ip_daily) 汇总是否等于 日表
# 注意：这里可能存在微小差异，取决于脚本是否将所有流量（如网关自身）都归入IP表
# ==========================================
log "验证 4/5: IP明细表汇总 vs 日表 (Today: $TODAY)"

IP_UP=$(sqlite3 "$DB_PATH" "SELECT COALESCE(SUM(upload), 0) FROM traffic_ip_daily WHERE date = '$TODAY';")
IP_DOWN=$(sqlite3 "$DB_PATH" "SELECT COALESCE(SUM(download), 0) FROM traffic_ip_daily WHERE date = '$TODAY';")

# 重新获取日表数据（防止上面被覆盖）
DAILY_UP=$(sqlite3 "$DB_PATH" "SELECT COALESCE(upload, 0) FROM traffic_daily WHERE date = '$TODAY';")
DAILY_DOWN=$(sqlite3 "$DB_PATH" "SELECT COALESCE(download, 0) FROM traffic_daily WHERE date = '$TODAY';")

DIFF_UP=$((IP_UP - DAILY_UP))
DIFF_DOWN=$((IP_DOWN - DAILY_DOWN))

RESULTS["IP_Daily_Up_Diff"]=$DIFF_UP
RESULTS["IP_Daily_Down_Diff"]=$DIFF_DOWN

if [ $DIFF_UP -eq 0 ] && [ $DIFF_DOWN -eq 0 ]; then
    log "   通过: IP明细表汇总与日表完全一致。"
else
    # 允许一定的偏差说明（例如：-100 到 100 字节可能是统计抖动）
    if [ $DIFF_UP -lt 100 ] && [ $DIFF_UP -gt -100 ] && [ $DIFF_DOWN -lt 100 ] && [ $DIFF_DOWN -gt -100 ]; then
        log "   提示: 存在微小差异（<100字节），可能是统计抖动或未归属IP的流量（如广播包）。"
    else
        log "   警告: 存在显著差异！日表(U:$DAILY_UP D:$DAILY_DOWN) vs IP汇总(U:$IP_UP D:$IP_DOWN)"
    fi
    log "   细节: IP汇总(U:$IP_UP D:$IP_DOWN)"
fi

# ==========================================
# 5. 最终摘要报告
# ==========================================
log "=================================================="
log "验证完成。摘要报告："

echo "--------------------------------------------------"
echo "📊 验证结果摘要"
echo "--------------------------------------------------"
echo "1. 分钟表 vs 日表:"
echo "   上传差异: ${RESULTS[Minute_Daily_Up_Diff]} 字节"
echo "   下载差异: ${RESULTS[Minute_Daily_Down_Diff]} 字节"
echo ""
echo "2. 日表 vs 月表:"
echo "   上传差异: ${RESULTS[Daily_Monthly_Up_Diff]} 字节"
echo "   下载差异: ${RESULTS[Daily_Monthly_Down_Diff]} 字节"
echo ""
echo "3. 月表 vs 年表:"
echo "   上传差异: ${RESULTS[Monthly_Yearly_Up_Diff]} 字节"
echo "   下载差异: ${RESULTS[Monthly_Yearly_Down_Diff]} 字节"
echo ""
echo "4. IP明细 vs 日表:"
echo "   上传差异: ${RESULTS[IP_Daily_Up_Diff]} 字节"
echo "   下载差异: ${RESULTS[IP_Daily_Down_Diff]} 字节"
echo "--------------------------------------------------"

# 判断整体状态
if [ ${RESULTS[Minute_Daily_Up_Diff]} -eq 0 ] && [ ${RESULTS[Minute_Daily_Down_Diff]} -eq 0 ] && \
   [ ${RESULTS[Daily_Monthly_Up_Diff]} -eq 0 ] && [ ${RESULTS[Daily_Monthly_Down_Diff]} -eq 0 ] && \
   [ ${RESULTS[Monthly_Yearly_Up_Diff]} -eq 0 ] && [ ${RESULTS[Monthly_Yearly_Down_Diff]} -eq 0 ] && \
   [ ${RESULTS[IP_Daily_Up_Diff]} -eq 0 ] && [ ${RESULTS[IP_Daily_Down_Diff]} -eq 0 ]; then
    log "🎉 整体状态: 所有数据校验通过 (OK)"
    echo "整体状态:  数据一致"
else
    log "整体状态: 发现数据不一致 (ERROR)"
    echo "整体状态:  数据存在差异，请检查日志 $LOG_FILE"
fi
