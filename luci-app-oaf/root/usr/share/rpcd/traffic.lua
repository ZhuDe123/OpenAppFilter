#!/usr/bin/lua
-- LuCI RPC API for OAF traffic statistics
-- 直接查询 SQLite 数据库，支持日/月/年视图

local util = require "luci.util"
local http = require "luci.http"
local json = require "luci.jsonc"

module("luci.rpc.traffic", package.seeall)

local DB_PATH = '/tmp/oaf/traffic.db'

-- 执行 sqlite3 查询并返回解析后的 JSON 数组
local function sqlite_query(sql)
    local cmd = string.format("sqlite3 -json %s %s 2>/dev/null",
        util.shellquote(DB_PATH),
        util.shellquote(sql))
    local result = util.exec(cmd)
    if result and result ~= "" and result ~= "[]" then
        local parsed = json.parse(result)
        if parsed then
            return parsed
        end
    end
    return {}
end

function traffic_stats()
    local period = http.formvalue("period") or "day"
    local date_val = http.formvalue("date") or ""

    -- 验证 period 参数
    if period ~= "day" and period ~= "month" and period ~= "year" then
        period = "day"
    end

    -- 默认日期
    if date_val == "" then
        if period == "day" then
            date_val = os.date("%Y-%m-%d")
        elseif period == "month" then
            date_val = os.date("%Y-%m")
        else
            date_val = os.date("%Y")
        end
    end

    local result = {}

    if period == "year" then
        -- 年度视图：12 个月走势
        result.monthly = sqlite_query(
            string.format("SELECT month, upload, download FROM traffic_monthly WHERE month LIKE '%s-%%' ORDER BY month;",
                date_val))
        result.yearly = sqlite_query(
            string.format("SELECT year, upload, download FROM traffic_yearly WHERE year = '%s';",
                date_val))
        -- 年度视图：按 IP 聚合全年数据
        result.ip = sqlite_query(
            string.format("SELECT ip, mac, hostname, SUM(upload) as upload, SUM(download) as download FROM traffic_ip_daily WHERE date LIKE '%s-%%' GROUP BY ip ORDER BY (upload+download) DESC LIMIT 200;",
                date_val))

    elseif period == "month" then
        -- 月份视图：每天走势
        result.daily = sqlite_query(
            string.format("SELECT date, upload, download FROM traffic_daily WHERE date LIKE '%s-%%' ORDER BY date;",
                date_val))
        result.monthly = sqlite_query(
            string.format("SELECT month, upload, download FROM traffic_monthly WHERE month = '%s';",
                date_val))
        -- 月份视图：按 IP 聚合当月数据
        result.ip = sqlite_query(
            string.format("SELECT ip, mac, hostname, SUM(upload) as upload, SUM(download) as download FROM traffic_ip_daily WHERE date LIKE '%s-%%' GROUP BY ip ORDER BY (upload+download) DESC LIMIT 200;",
                date_val))

    else -- period == "day"
        -- 日视图：分钟级走势
        local now_time = os.date("%H:%M")
        result.minute = sqlite_query(
            string.format("SELECT time, upload, download FROM traffic_minute WHERE date = '%s' AND time <= '%s' ORDER BY time;",
                date_val, now_time))
        result.global = sqlite_query(
            string.format("SELECT date, upload, download, updated_at FROM traffic_daily WHERE date = '%s';",
                date_val))
        -- 日视图：当天每个 IP 的流量
        result.ip = sqlite_query(
            string.format("SELECT ip, mac, hostname, upload, download FROM traffic_ip_daily WHERE date = '%s' ORDER BY (upload+download) DESC LIMIT 200;",
                date_val))
    end

    http.prepare_content("application/json")
    http.write(json.stringify(result))
end
