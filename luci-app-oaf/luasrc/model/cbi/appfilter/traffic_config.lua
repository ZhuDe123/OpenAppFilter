-- OAF 流量统计配置页面

local m, s

m = Map("appfilter", translate("Traffic Statistics Settings"))

-- 流量采集设置
s = m:section(NamedSection, "traffic", "traffic", translate("Collection Settings"))
s.addremove = false

s:option(Flag, "enabled", translate("Enable Traffic Collection"),
    translate("Enable or disable the traffic collection daemon. When disabled, no historical data will be saved."))
s:option(Value, "collect_interval", translate("Collection Interval (seconds)"),
    translate("How often to sample traffic data from the kernel. Recommended: 60 seconds (matches the kernel reporting interval)."))
    .datatype = "range(30,300)"

s:option(Value, "persist_interval", translate("Backup Interval (minutes)"),
    translate("How often to backup the database to flash storage. Set to 0 to disable automatic backup."))
    .datatype = "range(0,1440)"

-- 数据保留设置
s = m:section(NamedSection, "traffic", "traffic", translate("Data Retention"))
s.addremove = false

s:option(Value, "retain_minutes", translate("Minute Data Retention (days)"),
    translate("How many days to keep per-minute traffic data. Used for the daily chart view."))
    .datatype = "range(1,30)"

s:option(Value, "retain_days", translate("Daily Data Retention (days)"),
    translate("How many days to keep daily traffic data."))
    .datatype = "range(7,730)"

s:option(Value, "retain_months", translate("Monthly Data Retention (months)"),
    translate("How many months to keep monthly traffic data."))
    .datatype = "range(1,120)"

s:option(Value, "retain_years", translate("Yearly Data Retention (years)"),
    translate("How many years to keep yearly traffic data."))
    .datatype = "range(1,100)"

return m
