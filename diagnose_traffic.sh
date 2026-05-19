#!/bin/sh
# ============================================================
# OAF 流量统计诊断脚本
# 用法: sh diagnose_traffic.sh [--fix]
#   --fix  尝试自动修复发现的问题
# ============================================================

AUTO_FIX=0
if [ "$1" = "--fix" ]; then
    AUTO_FIX=1
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

pass() { echo "  ${GREEN}[✓]${NC} $1"; PASS=$((PASS + 1)); }
fail() { echo "  ${RED}[✗]${NC} $1"; FAIL=$((FAIL + 1)); }
warn() { echo "  ${YELLOW}[!]${NC} $1"; WARN=$((WARN + 1)); }
info() { echo "  ${CYAN}[i]${NC} $1"; }
fix()  { echo "  ${YELLOW}[修复]${NC} $1"; }

echo "========================================"
echo "  OAF 流量统计诊断脚本"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"
echo ""

# ==========================================
# 1. 检查软件包是否安装
# ==========================================
echo "── 1. 软件包检查 ──"

if opkg list-installed 2>/dev/null | grep -q "^appfilter "; then
    VER=$(opkg list-installed 2>/dev/null | grep "^appfilter " | awk '{print $3}')
    pass "appfilter 已安装 (版本: $VER)"
else
    fail "appfilter 未安装"
fi

if opkg list-installed 2>/dev/null | grep -q "luci-app-oaf"; then
    VER=$(opkg list-installed 2>/dev/null | grep "luci-app-oaf" | awk '{print $3}')
    pass "luci-app-oaf 已安装 (版本: $VER)"
else
    fail "luci-app-oaf 未安装"
fi

if opkg list-installed 2>/dev/null | grep -q "kmod-oaf"; then
    VER=$(opkg list-installed 2>/dev/null | grep "kmod-oaf" | awk '{print $3}')
    pass "kmod-oaf 已安装 (版本: $VER)"
else
    fail "kmod-oaf 未安装"
fi

if which sqlite3 >/dev/null 2>&1; then
    pass "sqlite3-cli 已安装"
else
    fail "sqlite3-cli 未安装 — 流量统计必需"
    if [ "$AUTO_FIX" = "1" ]; then
        fix "尝试安装 sqlite3-cli..."
        opkg update >/dev/null 2>&1 && opkg install sqlite3-cli
    fi
fi

if which ucode >/dev/null 2>&1; then
    pass "ucode 已安装"
else
    fail "ucode 未安装 — traffic.uc 脚本无法运行"
fi

echo ""

# ==========================================
# 2. 检查内核模块
# ==========================================
echo "── 2. 内核模块检查 ──"

if lsmod | grep -q oaf; then
    pass "oaf 内核模块已加载"
    # 检查模块信息
    MOD_SIZE=$(lsmod | grep oaf | awk '{print $2}')
    info "模块占用内存: ${MOD_SIZE} 字节"
else
    fail "oaf 内核模块未加载 — 流量统计无法工作"
    if [ "$AUTO_FIX" = "1" ]; then
        if [ -f /lib/modules/*/oaf.ko ]; then
            fix "尝试加载 oaf 内核模块..."
            insmod /lib/modules/*/oaf.ko 2>/dev/null || true
        else
            fix "未找到 oaf.ko 文件，请重新安装 kmod-oaf"
        fi
    fi
fi

# 检查 /proc/net/af_client（内核模块暴露的接口）
if [ -f /proc/net/af_client ]; then
    CLIENT_COUNT=$(grep -c "^[0-9]" /proc/net/af_client 2>/dev/null || echo 0)
    pass "/proc/net/af_client 存在 ($CLIENT_COUNT 个设备在线)"
    if [ "$CLIENT_COUNT" -gt 0 ]; then
        info "示例数据 (前3行):"
        head -n 4 /proc/net/af_client | while read line; do
            echo "    $line"
        done
    fi
else
    fail "/proc/net/af_client 不存在 — 内核模块未正确加载或未导出 proc 接口"
fi

echo ""

# ==========================================
# 3. 检查 oafd 守护进程
# ==========================================
echo "── 3. oafd 守护进程检查 ──"

OAFD_PID=$(pgrep -f oafd 2>/dev/null || true)
if [ -n "$OAFD_PID" ]; then
    pass "oafd 守护进程运行中 (PID: $OAFD_PID)"
else
    fail "oafd 守护进程未运行"
    if [ "$AUTO_FIX" = "1" ]; then
        fix "尝试启动 oafd..."
        /etc/init.d/appfilter start 2>/dev/null || true
        sleep 2
    fi
fi

# 检查 ubus 接口
if which ubus >/dev/null 2>&1; then
    if ubus list 2>/dev/null | grep -q "appfilter"; then
        pass "ubus appfilter 接口已注册"
    else
        fail "ubus appfilter 接口未注册 — oafd 可能未完全启动"
    fi
else
    warn "ubus 命令不可用，跳过检查"
fi

echo ""

# ==========================================
# 4. 检查 ubus 流量数据
# ==========================================
echo "── 4. ubus 数据源检查 ──"

if which ubus >/dev/null 2>&1 && ubus list 2>/dev/null | grep -q "appfilter"; then
    UBUS_OUT=$(ubus call appfilter get_all_users '{"flag":3,"page":0}' 2>/dev/null || echo "")
    if [ -n "$UBUS_OUT" ] && echo "$UBUS_OUT" | grep -q "today_up_flow"; then
        pass "ubus get_all_users 返回了 today_up_flow 字段"

        # 解析一个设备的流量
        DEV_COUNT=$(echo "$UBUS_OUT" | grep -c '"mac"' 2>/dev/null || echo 0)
        HAS_TRAFFIC=0
        TOTAL_DEVICES=0

        # 用更简单的方式：统计有流量的设备数
        UP_LIST=$(echo "$UBUS_OUT" | grep -o '"today_up_flow":[0-9]*' | grep -v ':0$' | wc -l)
        DOWN_LIST=$(echo "$UBUS_OUT" | grep -o '"today_down_flow":[0-9]*' | grep -v ':0$' | wc -l)

        if [ "$UP_LIST" -gt 0 ] || [ "$DOWN_LIST" -gt 0 ]; then
            HAS_TRAFFIC=$UP_LIST
            [ "$DOWN_LIST" -gt "$HAS_TRAFFIC" ] && HAS_TRAFFIC=$DOWN_LIST
            pass "有 $HAS_TRAFFIC 个设备产生了今日流量"
        else
            warn "所有设备的今日流量均为 0"
            warn "可能原因: 内核模块刚加载尚无流量 / 设备均离线 / 今天尚未有设备上网"
        fi
    else
        fail "ubus get_all_users 未返回 today_up_flow 字段"
        fail "可能原因: flag 参数不生效 / appfilter 版本过旧 / ubus 接口变更"
        info "原始返回(前500字符):"
        echo "$UBUS_OUT" | head -c 500
        echo ""
    fi
else
    warn "无法调用 ubus，跳过流量数据检查"
fi

echo ""

# ==========================================
# 5. 检查流量统计服务 (oaf-traffic)
# ==========================================
echo "── 5. 流量统计服务检查 ──"

# 检查 init 脚本
if [ -f /etc/init.d/oaf-traffic ]; then
    pass "/etc/init.d/oaf-traffic 存在"
else
    fail "/etc/init.d/oaf-traffic 不存在 — 流量采集服务未安装"
    info "请确认 appfilter 包是否包含 traffic 相关文件"
fi

# 检查 traffic.uc
if [ -f /etc/oaf/ucode/traffic.uc ]; then
    pass "/etc/oaf/ucode/traffic.uc 存在 ($(wc -l < /etc/oaf/ucode/traffic.uc) 行)"
elif [ -f /usr/share/oaf/traffic.uc ]; then
    warn "/etc/oaf/ucode/traffic.uc 不在预期路径，但在 /usr/share/oaf/ 找到"
else
    fail "/etc/oaf/ucode/traffic.uc 不存在 — 核心采集脚本缺失"
fi

# 检查采集脚本
if [ -f /etc/oaf/scripts/oaf-traffic-collect.sh ]; then
    pass "采集脚本存在"
else
    fail "/etc/oaf/scripts/oaf-traffic-collect.sh 不存在"
fi

# 检查进程
TRAFFIC_PID=$(pgrep -f "traffic.uc\|oaf-traffic-collect" 2>/dev/null || true)
if [ -n "$TRAFFIC_PID" ]; then
    pass "流量采集进程运行中 (PID: $TRAFFIC_PID)"
else
    warn "流量采集进程未运行"
    # 检查 UCI 开关
    ENABLED=$(uci get appfilter.traffic.enabled 2>/dev/null || echo "未设置")
    if [ "$ENABLED" != "1" ]; then
        fail "UCI 开关 appfilter.traffic.enabled = '$ENABLED' (应为 1)"
    else
        warn "开关已启用但进程未运行，可能启动失败"
        if [ "$AUTO_FIX" = "1" ]; then
            fix "尝试启动 oaf-traffic..."
            /etc/init.d/oaf-traffic start 2>/dev/null || true
            sleep 3
        fi
    fi
fi

echo ""

# ==========================================
# 6. 检查 UCI 配置
# ==========================================
echo "── 6. UCI 配置检查 ──"

if uci get appfilter.traffic >/dev/null 2>&1; then
    pass "appfilter.traffic 配置段存在"
else
    fail "appfilter.traffic 配置段不存在 — 请运行 uci-defaults 或手动创建"
    if [ "$AUTO_FIX" = "1" ]; then
        fix "创建默认配置..."
        if [ -f /usr/share/uci-defaults/99_oaf_traffic ]; then
            sh /usr/share/uci-defaults/99_oaf_traffic
            fix "已执行 uci-defaults 脚本"
        fi
    fi
fi

ENABLED=$(uci get appfilter.traffic.enabled 2>/dev/null || echo "0")
INTERVAL=$(uci get appfilter.traffic.collect_interval 2>/dev/null || echo "60")
PERSIST=$(uci get appfilter.traffic.persist_interval 2>/dev/null || echo "30")
RETAIN_DAYS=$(uci get appfilter.traffic.retain_days 2>/dev/null || echo "90")

echo "  enabled           = $ENABLED $([ "$ENABLED" = "1" ] && echo "${GREEN}✓${NC}" || echo "${RED}✗ 应为1${NC}")"
echo "  collect_interval  = ${INTERVAL}s"
echo "  persist_interval  = ${PERSIST}min"
echo "  retain_days       = $RETAIN_DAYS 天"

# 检查间隔是否合理
if [ "$INTERVAL" -lt 30 ] 2>/dev/null; then
    warn "采集间隔 < 30s，可能增加 CPU 负载"
fi
if [ "$INTERVAL" -gt 300 ] 2>/dev/null; then
    warn "采集间隔 > 300s，数据粒度较粗"
fi

echo ""

# ==========================================
# 7. 检查 SQLite 数据库
# ==========================================
echo "── 7. SQLite 数据库检查 ──"

DB_PATH="/tmp/oaf/traffic.db"
BAK_PATH="/etc/oaf/traffic.db.bak"

if [ -f "$DB_PATH" ]; then
    DB_SIZE=$(ls -lh "$DB_PATH" | awk '{print $5}')
    pass "数据库存在: $DB_PATH (大小: $DB_SIZE)"

    # 检查表是否存在
    TABLE_COUNT=$(sqlite3 "$DB_PATH" "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo 0)
    pass "数据库中包含 $TABLE_COUNT 张表"

    # 列出所有表
    info "表列表:"
    sqlite3 "$DB_PATH" ".tables" 2>/dev/null | while read line; do
        echo "    $line"
    done

    # 检查每张表的数据量
    echo ""
    info "各表数据量:"
    for table in traffic_daily traffic_monthly traffic_yearly traffic_minute traffic_ip_daily traffic_last_capture; do
        COUNT=$(sqlite3 "$DB_PATH" "SELECT count(*) FROM $table;" 2>/dev/null || echo "N/A")
        if [ "$COUNT" != "N/A" ] && [ "$COUNT" -gt 0 ] 2>/dev/null; then
            pass "$table: $COUNT 条记录"
        elif [ "$COUNT" = "0" ]; then
            warn "$table: 0 条记录 — 表存在但无数据"
        else
            warn "$table: 表不存在或无法访问"
        fi
    done

    # 检查最新记录时间
    LATEST=$(sqlite3 "$DB_PATH" "SELECT max(updated_at) FROM traffic_daily;" 2>/dev/null || echo "0")
    if [ "$LATEST" != "0" ] && [ -n "$LATEST" ]; then
        LATEST_TIME=$(date -d "@$LATEST" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "时间戳: $LATEST")
        NOW_TS=$(date +%s)
        DIFF=$((NOW_TS - LATEST))
        if [ "$DIFF" -lt 300 ]; then
            pass "最新记录: $LATEST_TIME (${DIFF}秒前) — 采集正常"
        elif [ "$DIFF" -lt 3600 ]; then
            warn "最新记录: $LATEST_TIME (${DIFF}秒前) — 可能采集间隔较长"
        else
            fail "最新记录: $LATEST_TIME (${DIFF}秒前) — 采集似乎已停止"
        fi
    else
        warn "traffic_daily 表中无更新时间记录"
    fi

    # 检查 WAL 模式
    JOURNAL=$(sqlite3 "$DB_PATH" "PRAGMA journal_mode;" 2>/dev/null || echo "unknown")
    if [ "$JOURNAL" = "wal" ]; then
        pass "WAL 模式已启用"
    else
        warn "日志模式: $JOURNAL (建议使用 WAL)"
    fi

else
    fail "数据库不存在: $DB_PATH"
    warn "可能原因:"
    warn "  1. 首次安装，采集尚未运行（重启后查看）"
    warn "  2. oaf-traffic 服务未启动"
    warn "  3. 采集脚本执行失败"
    warn "  4. /tmp 被清空（重启后如无备份则数据丢失）"

    if [ "$AUTO_FIX" = "1" ]; then
        if [ -x /etc/init.d/oaf-traffic ]; then
            fix "尝试启动 oaf-traffic 并等待第一次采集..."
            /etc/init.d/oaf-traffic start 2>/dev/null || true
            sleep 65
            if [ -f "$DB_PATH" ]; then
                pass "修复成功！数据库已创建"
            else
                fail "修复失败，数据库仍未创建"
            fi
        fi
    fi
fi

echo ""

# ==========================================
# 8. 检查备份
# ==========================================
echo "── 8. 备份状态检查 ──"

if [ -f "$BAK_PATH" ]; then
    BAK_SIZE=$(ls -lh "$BAK_PATH" | awk '{print $5}')
    BAK_MTIME=$(stat -c %Y "$BAK_PATH" 2>/dev/null || echo 0)
    BAK_TIME=$(date -d "@$BAK_MTIME" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "未知")
    pass "备份存在: $BAK_PATH (大小: $BAK_SIZE, 时间: $BAK_TIME)"

    # 检查备份是否比数据库旧
    if [ -f "$DB_PATH" ]; then
        DB_MTIME=$(stat -c %Y "$DB_PATH" 2>/dev/null || echo 0)
        DIFF=$((DB_MTIME - BAK_MTIME))
        if [ "$DIFF" -gt 3600 ]; then
            warn "备份比数据库旧 ${DIFF} 秒，建议手动备份"
        fi
    fi
else
    warn "备份不存在: $BAK_PATH"
    warn "备份将在首次 persist 后创建（默认每 30 分钟）"
fi

echo ""

# ==========================================
# 9. 检查日志
# ==========================================
echo "── 9. 采集日志检查 ──"

LOG_FILE="/tmp/oaf/traffic.log"
if [ -f "$LOG_FILE" ]; then
    LOG_SIZE=$(wc -c < "$LOG_FILE")
    pass "日志存在: $LOG_FILE ($LOG_SIZE 字节)"

    # 显示最近 5 条日志
    info "最近 5 条日志:"
    tail -n 5 "$LOG_FILE" | while read line; do
        echo "    $line"
    done

    # 检查是否有错误
    ERROR_COUNT=$(grep -c -i "error\|fail\|warning" "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$ERROR_COUNT" -gt 0 ]; then
        warn "日志中发现 $ERROR_COUNT 条错误/警告"
        info "最近的错误:"
        grep -i "error\|fail" "$LOG_FILE" 2>/dev/null | tail -n 3 | while read line; do
            echo "    ${RED}$line${NC}"
        done
    fi
else
    warn "日志文件不存在 — 采集脚本从未运行过"
fi

echo ""

# ==========================================
# 10. 手动测试采集
# ==========================================
echo "── 10. 手动采集测试 ──"

if [ -f /etc/oaf/ucode/traffic.uc ]; then
    info "手动运行一次采集（命令: ucode /etc/oaf/ucode/traffic.uc collect）..."
    RESULT=$(ucode /etc/oaf/ucode/traffic.uc collect 2>&1 || true)
    if echo "$RESULT" | grep -q "Collect OK"; then
        pass "手动采集成功: $RESULT"
    elif echo "$RESULT" | grep -q "skipping"; then
        warn "采集被跳过（可能锁未释放）: $RESULT"
        info "检查锁文件..."
        if [ -f /tmp/oaf/traffic.lock ]; then
            LOCK_PID=$(cat /tmp/oaf/traffic.lock 2>/dev/null || echo "?")
            if [ -d "/proc/$LOCK_PID" ]; then
                warn "锁文件存在且进程 $LOCK_PID 仍在运行（正常，说明上一次采集正在进行）"
            else
                warn "僵尸锁文件，进程 $LOCK_PID 已退出"
                if [ "$AUTO_FIX" = "1" ]; then
                    fix "清理僵尸锁..."
                    rm -f /tmp/oaf/traffic.lock
                    fix "重试采集..."
                    ucode /etc/oaf/ucode/traffic.uc collect 2>&1
                fi
            fi
        fi
    else
        fail "手动采集失败: $RESULT"
    fi
else
    warn "traffic.uc 不存在，跳过手动测试"
fi

echo ""
echo "========================================"
echo "  诊断完成"
echo "========================================"
echo ""
echo "  通过: $PASS  警告: $WARN  失败: $FAIL"
echo ""

if [ "$FAIL" -gt 0 ]; then
    echo "  ${RED}存在 $FAIL 个严重问题需要修复${NC}"
    echo "  建议执行: sh $0 --fix"
fi

if [ "$FAIL" -eq 0 ] && [ "$WARN" -gt 0 ]; then
    echo "  ${YELLOW}基本正常，有 $WARN 个警告需要关注${NC}"
fi

if [ "$FAIL" -eq 0 ] && [ "$WARN" -eq 0 ]; then
    echo "  ${GREEN}流量统计功能一切正常！${NC}"
fi

echo ""
echo "  排查建议："
echo "  1. 如果数据库为空，等待 60 秒后重新运行本脚本"
echo "  2. 如果有设备在线但流量为 0，检查设备是否正在上网"
echo "  3. 如果所有检查通过但前端无数据，检查浏览器控制台是否有 JS 错误"
echo "  4. 如果内核模块未加载，检查 dmesg | grep oaf"
echo ""
