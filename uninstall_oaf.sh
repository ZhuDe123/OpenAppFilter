#!/bin/sh
# ============================================================
# OAF 完整卸载脚本
# 适用于 immortalwrt / OpenWrt
# 用法: sh uninstall_oaf.sh
# ============================================================

set -e

echo "========================================"
echo "  OAF (OpenAppFilter) 卸载脚本"
echo "========================================"
echo ""

# 1. 停止相关服务
echo "[1/6] 停止服务..."
if [ -x /etc/init.d/oaf-traffic ]; then
    /etc/init.d/oaf-traffic stop 2>/dev/null || true
    /etc/init.d/oaf-traffic disable 2>/dev/null || true
    echo "  - oaf-traffic 已停止"
fi

if [ -x /etc/init.d/appfilter ]; then
    /etc/init.d/appfilter stop 2>/dev/null || true
    /etc/init.d/appfilter disable 2>/dev/null || true
    echo "  - appfilter (oafd) 已停止"
fi

# 2. 卸载内核模块
echo "[2/6] 卸载内核模块..."
if lsmod | grep -q oaf; then
    rmmod oaf 2>/dev/null || true
    echo "  - oaf 内核模块已卸载"
else
    echo "  - oaf 内核模块未加载，跳过"
fi

# 如果有 hnat 相关设置，恢复
if [ -f /usr/bin/hnat.sh ]; then
    # hnat.sh 可能被 OAF 修改过，尝试恢复（如存在原始备份）
    echo "  - 注意：/usr/bin/hnat.sh 如果被 OAF 修改过，请手动检查恢复"
fi

# 3. 清理数据文件
echo "[3/6] 清理数据文件..."

# 流量统计数据库
if [ -f /tmp/oaf/traffic.db ]; then
    rm -f /tmp/oaf/traffic.db
    echo "  - 已删除 /tmp/oaf/traffic.db"
fi
if [ -f /etc/oaf/traffic.db.bak ]; then
    rm -f /etc/oaf/traffic.db.bak
    echo "  - 已删除 /etc/oaf/traffic.db.bak"
fi

# 日志
rm -f /tmp/oaf/traffic.log /tmp/log/appfilter.log 2>/dev/null || true
echo "  - 已删除日志文件"

# 临时文件
rm -rf /tmp/oaf/ 2>/dev/null || true
rm -f /tmp/feature.cfg /tmp/visit_list /tmp/dev_list 2>/dev/null || true
echo "  - 已删除临时文件"

# 4. 使用 opkg 卸载包（按依赖顺序：先卸载上层，再卸载底层）
echo "[4/6] 卸载软件包..."

# 先卸载翻译包
if opkg list-installed | grep -q "luci-i18n-oaf-zh-cn"; then
    opkg remove luci-i18n-oaf-zh-cn --force-removal-of-dependent-packages 2>/dev/null || true
    echo "  - luci-i18n-oaf-zh-cn 已卸载"
fi

# 卸载 LuCI 界面
if opkg list-installed | grep -q "luci-app-oaf"; then
    opkg remove luci-app-oaf --force-removal-of-dependent-packages 2>/dev/null || true
    echo "  - luci-app-oaf 已卸载"
fi

# 卸载服务守护进程
if opkg list-installed | grep -q "^appfilter "; then
    opkg remove appfilter --force-removal-of-dependent-packages 2>/dev/null || true
    echo "  - appfilter 已卸载"
fi

# 卸载内核模块
if opkg list-installed | grep -q "kmod-oaf"; then
    opkg remove kmod-oaf --force-removal-of-dependent-packages 2>/dev/null || true
    echo "  - kmod-oaf 已卸载"
fi

# 5. 清理残留配置文件
echo "[5/6] 清理配置文件..."

# UCI 配置
if [ -f /etc/config/appfilter ]; then
    rm -f /etc/config/appfilter
    echo "  - 已删除 /etc/config/appfilter"
fi
if [ -f /etc/config/user_info ]; then
    rm -f /etc/config/user_info
    echo "  - 已删除 /etc/config/user_info"
fi

# 应用过滤相关目录
rm -rf /etc/appfilter/ 2>/dev/null || true
rm -rf /etc/oaf/ 2>/dev/null || true
echo "  - 已删除 /etc/appfilter/ 和 /etc/oaf/"

# 二进制文件
rm -f /usr/bin/oafd /usr/bin/oaf_rule /usr/bin/gen_class.sh /usr/bin/hnat.sh 2>/dev/null || true
echo "  - 已删除二进制文件"

# init 脚本
rm -f /etc/init.d/appfilter /etc/init.d/oaf-traffic 2>/dev/null || true
echo "  - 已删除 init 脚本"

# LuCI 相关
rm -f /usr/lib/lua/luci/controller/appfilter.lua 2>/dev/null || true
rm -rf /usr/lib/lua/luci/model/cbi/appfilter/ 2>/dev/null || true
rm -rf /usr/lib/lua/luci/view/admin_network/*.htm 2>/dev/null || true
rm -f /usr/share/rpcd/traffic.lua 2>/dev/null || true
rm -f /usr/share/rpcd/acl.d/luci-app-oaf.json 2>/dev/null || true
rm -f /usr/share/uci-defaults/99_oaf_traffic 2>/dev/null || true
rm -rf /www/luci-static/resources/app_icons/ 2>/dev/null || true
echo "  - 已删除 LuCI 相关文件"

# 6. 用户自定义配置文件（保留，手动删除）
echo "[6/6] 检查残留..."
echo ""
echo "========================================"
echo "  卸载完成！"
echo "========================================"
echo ""
echo "以下文件如果存在，请手动确认是否删除："
echo "  /etc/user_list.dat    (用户列表数据)"
echo ""
echo "建议重启路由器使所有更改生效："
echo "  reboot"
echo ""
