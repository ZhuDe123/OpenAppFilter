#!/usr/bin/ucode
// /etc/oaf/ucode/traffic.uc - OAF 流量统计采集脚本
// 功能：从 ubus get_all_users 获取设备流量 → 计算增量 → 写入 SQLite
// 数据源：ubus call appfilter get_all_users '{"flag":3,"page":0}'
// 单位：字节（全链路 int64）
// 设计：所有增量计算由 ucode 完成（原生 64 位整数），SQLite 只做累加
// 数据库：/tmp/oaf/traffic.db（内存盘），备份到 /etc/oaf/traffic.db.bak（闪存）

import { open, mkdir, chmod, stat, popen } from 'fs';
import { cursor } from 'uci';

const DB_PATH = '/tmp/oaf/traffic.db';
const PERSIST_DB = '/etc/oaf/traffic.db.bak';
const LOG_FILE = '/tmp/oaf/traffic.log';
const MAX_LOG_SIZE = 1024 * 100;  // 日志最大 100KB

const uci = cursor();

// ===== 工具函数 =====

// 日志：带时间戳，超 100KB 自动裁剪保留最后 50 行
function log(msg) {
    let t = localtime(time());
    let ts = sprintf('%d-%02d-%02d %02d:%02d:%02d', t.year, t.mon, t.mday, t.hour, t.min, t.sec);
    let line = sprintf("[%s] [OAF-Traffic] %s\n", ts, msg);

    if (stat(LOG_FILE)) {
        let st = stat(LOG_FILE);
        if (st && st.size > MAX_LOG_SIZE) {
            let lines = [];
            let f = open(LOG_FILE, 'r');
            if (f) {
                let l;
                while ((l = f.read('line')) != null) push(lines, l);
                f.close();
                if (length(lines) > 50) lines = slice(lines, length(lines) - 50);
                f = open(LOG_FILE, 'w');
                if (f) {
                    for (let i = 0; i < length(lines); i++) f.write(lines[i]);
                    f.close();
                }
            }
        }
    }

    let f = open(LOG_FILE, 'a');
    if (f) { f.write(line); f.close(); }
}

// Shell 参数转义
function sq(str) {
    return str ? "'" + replace(str, "'", "'\\''") + "'" : "''";
}

// 读取 UCI 配置，带默认值
function uci_get_int(section, option, def) {
    let v = uci.get('appfilter', section, option);
    return v ? int(v) : def;
}

// ===== 数据库初始化 =====
function init_db() {
    if (!stat('/tmp/oaf')) mkdir('/tmp/oaf', 0700);

    let init_flag = '/tmp/oaf/traffic.db.init';
    if (stat(DB_PATH) && stat(init_flag)) return;

    // WAL 模式提高并发性能
    popen(sprintf("sqlite3 %s 'PRAGMA journal_mode=WAL;'", sq(DB_PATH)))?.close();

    // 快照表：记录上次采样的累计值
    popen(sprintf("sqlite3 %s 'CREATE TABLE IF NOT EXISTS traffic_last_capture (key TEXT PRIMARY KEY, upload BIGINT, download BIGINT, last_seen INTEGER);'", sq(DB_PATH)))?.close();

    // 全局统计表
    popen(sprintf("sqlite3 %s 'CREATE TABLE IF NOT EXISTS traffic_daily (date TEXT PRIMARY KEY, upload BIGINT DEFAULT 0, download BIGINT DEFAULT 0, updated_at INTEGER);'", sq(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE TABLE IF NOT EXISTS traffic_monthly (month TEXT PRIMARY KEY, upload BIGINT DEFAULT 0, download BIGINT DEFAULT 0, updated_at INTEGER);'", sq(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE TABLE IF NOT EXISTS traffic_yearly (year TEXT PRIMARY KEY, upload BIGINT DEFAULT 0, download BIGINT DEFAULT 0, updated_at INTEGER);'", sq(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE TABLE IF NOT EXISTS traffic_minute (date TEXT NOT NULL, time TEXT NOT NULL, upload BIGINT DEFAULT 0, download BIGINT DEFAULT 0, PRIMARY KEY(date, time));'", sq(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE TABLE IF NOT EXISTS traffic_ip_daily (date TEXT NOT NULL, ip TEXT NOT NULL, mac TEXT, hostname TEXT, upload BIGINT DEFAULT 0, download BIGINT DEFAULT 0, PRIMARY KEY(date, ip));'", sq(DB_PATH)))?.close();

    // 索引
    popen(sprintf("sqlite3 %s 'CREATE INDEX IF NOT EXISTS idx_daily_date ON traffic_daily(date);'", sq(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE INDEX IF NOT EXISTS idx_monthly_month ON traffic_monthly(month);'", sq(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE INDEX IF NOT EXISTS idx_yearly_year ON traffic_yearly(year);'", sq(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE INDEX IF NOT EXISTS idx_minute_date ON traffic_minute(date, time);'", sq(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE INDEX IF NOT EXISTS idx_ip_daily_date ON traffic_ip_daily(date);'", sq(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE INDEX IF NOT EXISTS idx_ip_daily_ip ON traffic_ip_daily(ip);'", sq(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE INDEX IF NOT EXISTS idx_ip_daily_mac ON traffic_ip_daily(mac);'", sq(DB_PATH)))?.close();

    chmod(DB_PATH, 0600);

    let flag = open(init_flag, 'w');
    if (flag) { flag.write('1'); flag.close(); }
    log("Database initialized successfully");
}

// ===== Delta 计算：处理零点归零 =====
function compute_delta(current, last) {
    if (!last || last <= 0) return current;
    if (current >= last) return current - last;
    // current < last 说明已经零点归零，直接用 current 作为 delta
    return current;
}

// ===== 流量采集主函数 =====
function collect_traffic() {
    init_db();

    // --- 分布式锁 ---
    let lock_file = '/tmp/oaf/traffic.lock';
    if (stat(lock_file)) {
        let lp = open(lock_file, 'r');
        if (lp) {
            let lock_pid = trim(lp.read('all') || '');
            lp.close();
            if (lock_pid && stat('/proc/' + lock_pid)) {
                log("Warning: Another collection is running (pid=" + lock_pid + "), skipping");
                return;
            }
            system("rm -f " + lock_file);
        }
    }

    let my_pid_p = popen("cat /proc/self/stat 2>/dev/null | cut -d' ' -f1");
    let pid_str = my_pid_p ? trim(my_pid_p.read('all')) : '0';
    if (my_pid_p) my_pid_p.close();

    let lock = open(lock_file, 'w');
    if (lock) { lock.write(pid_str); lock.close(); }

    function release_lock() { system("rm -f " + lock_file); }

    try {
        // ===== Step 1: 从 ubus 获取数据 =====
        let p = popen("ubus call appfilter get_all_users '{\"flag\":3,\"page\":0}'");
        let raw = p ? p.read('all') : '{}';
        if (p) p.close();

        let resp = raw && match(raw, /^\s*\{/) ? json(raw) : {};
        let dev_list = resp?.data?.list;
        if (!dev_list || !length(dev_list)) {
            log("Warning: No devices returned from ubus");
            release_lock();
            return;
        }

        // ===== Step 2: 解析设备数据、计算全局总量 =====
        let devices = [];
        let global_up = 0, global_down = 0;

        for (let i = 0; i < length(dev_list); i++) {
            let d = dev_list[i];
            let ipv4 = d.ip || '';
            let ipv6 = d.ipv6 || '';

            // 收集该设备的所有有效 IP（IPv4 + IPv6）
            let ips = [];
            if (ipv4 && ipv4 != '0.0.0.0' && ipv4 != 'unknown') push(ips, ipv4);
            if (ipv6 && ipv6 != '::' && ipv6 != 'unknown') push(ips, ipv6);
            if (!length(ips)) continue;

            let mac = d.mac || ('unknown_' + ips[0]);
            let hostname = d.hostname || '';

            // today_up_flow / today_down_flow 现在是字节（已改为 int64）
            let up = int(d.today_up_flow || 0);
            let down = int(d.today_down_flow || 0);

            // 离线的无流量设备跳过（减少快照膨胀）
            if (up == 0 && down == 0 && int(d.online || 0) == 0) continue;

            global_up += up;
            global_down += down;
            push(devices, { ips: ips, mac: mac, hostname: hostname, up: up, down: down });
        }

        // ===== Step 3: 读取上次快照 =====
        let snapshot_cmd = sprintf("sqlite3 -separator '|' %s 'SELECT key, upload, download FROM traffic_last_capture;'", sq(DB_PATH));
        let sp = popen(snapshot_cmd);
        let old = {};
        if (sp) {
            let line;
            while ((line = sp.read('line')) != null) {
                let parts = split(trim(line), '|');
                if (length(parts) >= 3) {
                    old[parts[0]] = { up: int(parts[1]) || 0, down: int(parts[2]) || 0 };
                }
            }
            sp.close();
        }

        // ===== Step 4: 计算 delta =====
        let old_global_up = old['global']?.up || 0;
        let old_global_down = old['global']?.down || 0;
        let up_delta = compute_delta(global_up, old_global_up);
        let down_delta = compute_delta(global_down, old_global_down);

        let ip_deltas = {};
        for (let i = 0; i < length(devices); i++) {
            let d = devices[i];
            let primary_ip = d.ips[0];
            let key = 'ip:' + primary_ip;
            let old_ip = old[key];
            ip_deltas[primary_ip] = {
                up: compute_delta(d.up, old_ip?.up || 0),
                down: compute_delta(d.down, old_ip?.down || 0)
            };
        }

        // ===== Step 5: 构建批量 SQL =====
        let now = time();
        let t = localtime(now);
        let today = sprintf('%d-%02d-%02d', t.year, t.mon, t.mday);
        let month = sprintf('%d-%02d', t.year, t.mon);
        let year_str = sprintf('%d', t.year);
        let time_str = sprintf('%02d:%02d', t.hour, t.min);

        let sql = "BEGIN;\n";

        // 全局表
        sql += sprintf("INSERT INTO traffic_daily (date, upload, download, updated_at) VALUES ('%s', %d, %d, %d) ON CONFLICT(date) DO UPDATE SET upload=upload+%d, download=download+%d, updated_at=%d;\n",
            today, up_delta, down_delta, now, up_delta, down_delta, now);
        sql += sprintf("INSERT INTO traffic_monthly (month, upload, download, updated_at) VALUES ('%s', %d, %d, %d) ON CONFLICT(month) DO UPDATE SET upload=upload+%d, download=download+%d, updated_at=%d;\n",
            month, up_delta, down_delta, now, up_delta, down_delta, now);
        sql += sprintf("INSERT INTO traffic_yearly (year, upload, download, updated_at) VALUES ('%s', %d, %d, %d) ON CONFLICT(year) DO UPDATE SET upload=upload+%d, download=download+%d, updated_at=%d;\n",
            year_str, up_delta, down_delta, now, up_delta, down_delta, now);
        sql += sprintf("INSERT INTO traffic_minute (date, time, upload, download) VALUES ('%s', '%s', %d, %d) ON CONFLICT(date, time) DO UPDATE SET upload=upload+%d, download=download+%d;\n",
            today, time_str, up_delta, down_delta, up_delta, down_delta);

        // 每 IP 每日表 — 所有 IP 各一行，流量只计在主 IP（ips[0]）上
        for (let i = 0; i < length(devices); i++) {
            let d = devices[i];
            let primary_ip = d.ips[0];
            let delta = ip_deltas[primary_ip];
            let safe_mac = sq(d.mac);
            let safe_host = sq(d.hostname);
            for (let j = 0; j < length(d.ips); j++) {
                let sip = d.ips[j];
                let safe_ip = sq(sip);
                let d_up = (j == 0) ? delta.up : 0;
                let d_down = (j == 0) ? delta.down : 0;
                sql += sprintf("INSERT INTO traffic_ip_daily (date, ip, mac, hostname, upload, download) VALUES ('%s', %s, %s, %s, %d, %d) ON CONFLICT(date, ip) DO UPDATE SET upload=upload+%d, download=download+%d, mac=%s, hostname=%s;\n",
                    today, safe_ip, safe_mac, safe_host,
                    d_up, d_down, d_up, d_down,
                    safe_mac, safe_host);
            }
        }

        // 更新快照 — 只用主 IP
        sql += sprintf("INSERT OR REPLACE INTO traffic_last_capture (key, upload, download, last_seen) VALUES ('global', %d, %d, %d);\n",
            global_up, global_down, now);
        for (let i = 0; i < length(devices); i++) {
            let d = devices[i];
            let primary_ip = d.ips[0];
            let safe_key = sq('ip:' + primary_ip);
            sql += sprintf("INSERT OR REPLACE INTO traffic_last_capture (key, upload, download, last_seen) VALUES (%s, %d, %d, %d);\n",
                safe_key, d.up, d.down, now);
        }

        // 清理过期的 IP 快照（超过 10 分钟未见的 IP 删除）
        sql += sprintf("DELETE FROM traffic_last_capture WHERE key LIKE 'ip:%%' AND (last_seen < %d OR last_seen IS NULL);\n", now - 600);

        sql += "COMMIT;\n";

        // ===== Step 6: 执行 =====
        let cmd = sprintf("printf '%%s' %s | sqlite3 %s", sq(sql), sq(DB_PATH));
        popen(cmd)?.close();

        log(sprintf("Collect OK | Global UP=%d DOWN=%d | Devices=%d", up_delta, down_delta, length(devices)));
        print("Collect OK\n");

        // ===== 自动清理旧数据 =====
        let last_clean = uci_get_int('traffic', 'last_cleanup', 0);
        if (now - last_clean > 86400) {
            let retain_days = uci_get_int('traffic', 'retain_days', 90);
            let retain_months = uci_get_int('traffic', 'retain_months', 12);
            let retain_years = uci_get_int('traffic', 'retain_years', 5);
            let retain_minutes = uci_get_int('traffic', 'retain_minutes', 1);

            let clean_sql = "BEGIN;\n";
            clean_sql += sprintf("DELETE FROM traffic_daily WHERE date < date('now','-%d days');\n", retain_days);
            clean_sql += sprintf("DELETE FROM traffic_ip_daily WHERE date < date('now','-%d days');\n", retain_days);
            clean_sql += sprintf("DELETE FROM traffic_monthly WHERE month < strftime('%%Y-%%m', 'now','-%d months');\n", retain_months);
            clean_sql += sprintf("DELETE FROM traffic_yearly WHERE year < strftime('%%Y', 'now','-%d years');\n", retain_years);
            clean_sql += sprintf("DELETE FROM traffic_minute WHERE date < date('now','-%d days');\n", retain_minutes);
            clean_sql += "COMMIT;";
            popen(sprintf("sqlite3 %s %s", sq(DB_PATH), sq(clean_sql)))?.close();

            uci.set('appfilter', 'traffic', 'last_cleanup', now);
            uci.commit('appfilter');
            log("Auto-cleanup completed");
        }

    } catch (e) {
        log("Error during collection: " + e);
    }

    release_lock();
}

// ===== 持久化备份 =====
function persist() {
    if (!stat(DB_PATH)) { log("Error: No database to backup"); return; }
    mkdir('/etc/oaf', 0755);
    popen(sprintf("sqlite3 %s '.backup %s'", sq(DB_PATH), sq(PERSIST_DB)))?.close();
    chmod(PERSIST_DB, 0600);
    system("touch " + sq(PERSIST_DB));
    log("Backup to flash successful");
}

// ===== 从备份恢复 =====
function restore() {
    if (!stat(PERSIST_DB)) {
        log("No backup found, starting fresh");
        return;
    }

    log("Restoring database from backup...");

    // 校验备份完整性
    let check = popen(sprintf("sqlite3 %s 'PRAGMA integrity_check;'", sq(PERSIST_DB)));
    let check_result = check ? trim(check.read('all') || '') : '';
    if (check) check.close();
    if (check_result != 'ok') {
        log("Backup corrupted (integrity check failed: " + check_result + "), starting fresh");
        system("rm -f " + sq(PERSIST_DB));
        return;
    }

    if (stat(DB_PATH)) system("rm -f " + sq(DB_PATH));

    popen(sprintf("sqlite3 %s '.restore %s'", sq(DB_PATH), sq(PERSIST_DB)))?.close();

    // 重建索引（恢复可能丢失索引）
    popen(sprintf("sqlite3 %s 'CREATE INDEX IF NOT EXISTS idx_daily_date ON traffic_daily(date);'", sq(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE INDEX IF NOT EXISTS idx_monthly_month ON traffic_monthly(month);'", sq(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE INDEX IF NOT EXISTS idx_yearly_year ON traffic_yearly(year);'", sq(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE INDEX IF NOT EXISTS idx_minute_date ON traffic_minute(date, time);'", sq(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE INDEX IF NOT EXISTS idx_ip_daily_date ON traffic_ip_daily(date);'", sq(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE INDEX IF NOT EXISTS idx_ip_daily_ip ON traffic_ip_daily(ip);'", sq(DB_PATH)))?.close();
    popen(sprintf("sqlite3 %s 'CREATE INDEX IF NOT EXISTS idx_ip_daily_mac ON traffic_ip_daily(mac);'", sq(DB_PATH)))?.close();

    chmod(DB_PATH, 0600);
    log("Database restored successfully");
}

// ===== 查询函数（供前端 RPC 使用）=====
function query_stats(period, date_val) {
    let t = localtime(time());
    if (!date_val) {
        date_val = period == 'year' ? sprintf('%d', t.year) :
                   period == 'month' ? sprintf('%d-%02d', t.year, t.mon) :
                   sprintf('%d-%02d-%02d', t.year, t.mon, t.mday);
    }

    let db = DB_PATH;
    if (!stat(db)) return '{}';

    if (period == 'year') {
        let mon = '[]', yea = '[]', ip = '[]';
        let m = popen(sprintf("sqlite3 -json %s 'SELECT month, upload, download FROM traffic_monthly WHERE month LIKE \"%s-%%\" ORDER BY month;'", sq(db), date_val));
        if (m) { let r = m.read('all'); m.close(); if (r && match(r, /^\s*\[/)) mon = trim(r); }
        let y = popen(sprintf("sqlite3 -json %s 'SELECT * FROM traffic_yearly WHERE year=\"%s\";'", sq(db), date_val));
        if (y) { let r = y.read('all'); y.close(); if (r && match(r, /^\s*\[/)) yea = trim(r); }
        let i = popen(sprintf("sqlite3 -json %s 'SELECT ip, mac, hostname, SUM(upload) as upload, SUM(download) as download FROM traffic_ip_daily WHERE date LIKE \"%s-%%\" GROUP BY ip ORDER BY (upload+download) DESC LIMIT 200;'", sq(db), date_val));
        if (i) { let r = i.read('all'); i.close(); if (r && match(r, /^\s*\[/)) ip = trim(r); }
        return sprintf('{"monthly":%s,"yearly":%s,"ip":%s}', mon, yea, ip);
    }

    if (period == 'month') {
        let dly = '[]', mon = '[]', ip = '[]';
        let d = popen(sprintf("sqlite3 -json %s 'SELECT date, upload, download FROM traffic_daily WHERE date LIKE \"%s-%%\" ORDER BY date;'", sq(db), date_val));
        if (d) { let r = d.read('all'); d.close(); if (r && match(r, /^\s*\[/)) dly = trim(r); }
        let m = popen(sprintf("sqlite3 -json %s 'SELECT month, upload, download FROM traffic_monthly WHERE month=\"%s\";'", sq(db), date_val));
        if (m) { let r = m.read('all'); m.close(); if (r && match(r, /^\s*\[/)) mon = trim(r); }
        let i = popen(sprintf("sqlite3 -json %s 'SELECT ip, mac, hostname, SUM(upload) as upload, SUM(download) as download FROM traffic_ip_daily WHERE date LIKE \"%s-%%\" GROUP BY ip ORDER BY (upload+download) DESC LIMIT 200;'", sq(db), date_val));
        if (i) { let r = i.read('all'); i.close(); if (r && match(r, /^\s*\[/)) ip = trim(r); }
        return sprintf('{"daily":%s,"monthly":%s,"ip":%s}', dly, mon, ip);
    }

    // period == 'day'
    let now_time = sprintf('%02d:%02d', t.hour, t.min);
    let min = '[]', glo = '[]', ip = '[]';
    let mi = popen(sprintf("sqlite3 -json %s 'SELECT time, upload, download FROM traffic_minute WHERE date=\"%s\" AND time <= \"%s\" ORDER BY time;'", sq(db), date_val, now_time));
    if (mi) { let r = mi.read('all'); mi.close(); if (r && match(r, /^\s*\[/)) min = trim(r); }
    let g = popen(sprintf("sqlite3 -json %s 'SELECT date, upload, download, updated_at FROM traffic_daily WHERE date=\"%s\";'", sq(db), date_val));
    if (g) { let r = g.read('all'); g.close(); if (r && match(r, /^\s*\[/)) glo = trim(r); }
    let i = popen(sprintf("sqlite3 -json %s 'SELECT ip, mac, hostname, upload, download FROM traffic_ip_daily WHERE date=\"%s\" ORDER BY (upload+download) DESC LIMIT 200;'", sq(db), date_val));
    if (i) { let r = i.read('all'); i.close(); if (r && match(r, /^\s*\[/)) ip = trim(r); }
    return sprintf('{"minute":%s,"global":%s,"ip":%s}', min, glo, ip);
}

// ===== 手动清理 =====
function cleanup(retain_days) {
    retain_days = retain_days || 90;
    let sql = sprintf("BEGIN; DELETE FROM traffic_daily WHERE date < date('now','-%d days'); DELETE FROM traffic_ip_daily WHERE date < date('now','-%d days'); DELETE FROM traffic_minute WHERE date < date('now','-1 day'); COMMIT;", retain_days, retain_days);
    popen(sprintf("sqlite3 %s %s", sq(DB_PATH), sq(sql)))?.close();
    log("Manual cleanup completed: " + retain_days + " days");
}

// ===== 清除备份 =====
function clear_backup() {
    if (stat(PERSIST_DB)) {
        system("rm -f " + sq(PERSIST_DB));
        log("Backup cleared successfully");
    } else {
        log("No backup found");
    }
}

// ===== CLI 入口 =====
let action = ARGV[0];
if (action == 'collect') collect_traffic();
else if (action == 'persist') persist();
else if (action == 'restore') restore();
else if (action == 'clear_backup') clear_backup();
else if (action == 'stats') print(query_stats(ARGV[1], ARGV[2]));
else if (action == 'cleanup') cleanup(int(ARGV[1]) || 90);
else {
    print('Usage: traffic.uc collect|persist|restore|clear_backup|stats|cleanup\n');
}
