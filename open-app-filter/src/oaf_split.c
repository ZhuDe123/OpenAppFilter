/*
 * oaf_split.c — 独立设备分时模式核心逻辑
 * 在原有的上网时长模式 (mode=2) 下，支持各设备独立计时、独立封锁
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>
#include "oaf_split.h"
#include "appfilter_user.h"

extern af_run_time_status_t g_af_status;
extern dev_node_t *dev_hash_table[MAX_DEV_NODE_HASH_SIZE];

/*
 * 独立模式检查：遍历所有 is_selected 设备
 * 逐设备比较 today_am/pm_active_time vs max_allowed_time
 * 超时 → node->period_blocked = 1
 * 未超时 → node->period_blocked = 0
 * 返回值：1=至少有一台设备超时, 0=全部未超时
 */
int af_split_check_period_limit(af_time_config_t *t_config)
{
    time_t now = time(NULL);
    struct tm *current_time = localtime(&now);
    int current_weekday = current_time->tm_wday;
    int current_hour = current_time->tm_hour;
    int is_morning = (current_hour < 12);
    int i, any_blocked = 0;

    LOG_DEBUG("split mode check: weekday=%d, hour=%d\n", current_weekday, current_hour);

    daily_limit_config_t *daily_limit = &t_config->daily_limit[current_weekday];

    if (!daily_limit->enable) {
        LOG_DEBUG("split mode: not enabled for weekday %d, unblock all\n", current_weekday);
        for (i = 0; i < MAX_DEV_NODE_HASH_SIZE; i++) {
            dev_node_t *node = dev_hash_table[i];
            while (node) {
                node->period_blocked = 0;
                node = node->next;
            }
        }
        g_af_status.period_blocked = 0;
        g_af_status.used_time = 0;
        g_af_status.remain_time = 0;
        af_split_sync_blocked_macs();
        return 0;
    }

    int max_allowed_time = is_morning ? daily_limit->am_time : daily_limit->pm_time;
    if (max_allowed_time <= 0) {
        LOG_DEBUG("split mode: current period not limited, unblock all\n");
        for (i = 0; i < MAX_DEV_NODE_HASH_SIZE; i++) {
            dev_node_t *node = dev_hash_table[i];
            while (node) {
                node->period_blocked = 0;
                node = node->next;
            }
        }
        g_af_status.period_blocked = 0;
        af_split_sync_blocked_macs();
        return 0;
    }

    // 先检查并重置跨天/跨午计时
    check_all_users_period_time();

    // 逐设备独立判断
    for (i = 0; i < MAX_DEV_NODE_HASH_SIZE; i++) {
        dev_node_t *node = dev_hash_table[i];
        while (node) {
            if (node->is_selected) {
                u_int32_t current_active = is_morning ? node->today_am_active_time : node->today_pm_active_time;
                int old_blocked = node->period_blocked;
                if (current_active >= (u_int32_t)max_allowed_time) {
                    node->period_blocked = 1;
                    any_blocked = 1;
                } else {
                    node->period_blocked = 0;
                }
                // 状态变化时记录日志
                if (old_blocked != node->period_blocked) {
                    LOG_INFO("device %s %s (blocked=%d, used=%dmin, limit=%dmin)\n",
                             node->mac,
                             node->period_blocked ? "BLOCKED" : "UNBLOCKED",
                             node->period_blocked, current_active, max_allowed_time);
                }
            }
            node = node->next;
        }
    }

    // 同步封锁状态到内核
    af_split_sync_blocked_macs();

    g_af_status.period_blocked = any_blocked;
    g_af_status.used_time = 0;
    g_af_status.remain_time = 0;
    g_af_status.match_time = 1;

    LOG_DEBUG("split check: any_blocked=%d\n", any_blocked);
    return any_blocked ? 1 : 0;
}

/*
 * Delta 同步：将用户态 dev_node_t 中的封锁状态同步到内核
 * 通过 /proc/sys/oaf/blocked_macs 通信
 *
 * 简化实现：先 clear 清空全部内核封锁状态
 *           再将所有 period_blocked==1 的设备逐个写入 "+MAC"
 * 可后续优化为真正的增量（只写状态变化的设备）
 */
void af_split_sync_blocked_macs(void)
{
    int i;
    FILE *fp;

    // 先清空内核全部封锁状态
    fp = fopen("/proc/sys/oaf/blocked_macs", "w");
    if (fp) {
        fprintf(fp, "clear");
        fclose(fp);
        LOG_DEBUG("split sync: clear done\n");
    } else {
        LOG_WARN("split sync: fopen blocked_macs failed for clear\n");
        return;  // proc 文件不可用，后续也必然失败
    }

    // 逐个设备写入
    for (i = 0; i < MAX_DEV_NODE_HASH_SIZE; i++) {
        dev_node_t *node = dev_hash_table[i];
        while (node) {
            if (node->is_selected && node->period_blocked) {
                fp = fopen("/proc/sys/oaf/blocked_macs", "w");
                if (fp) {
                    fprintf(fp, "+%s", node->mac);
                    fclose(fp);
                    LOG_DEBUG("split sync: blocked device %s\n", node->mac);
                } else {
                    LOG_WARN("split sync: fopen blocked_macs failed for +%s\n", node->mac);
                }
            }
            node = node->next;
        }
    }
}

/*
 * 按 MAC 清空单个设备的今日时长和封锁状态
 * 同时向内核发送解锁指令
 */
void reset_one_user_today_active_time(const char *mac)
{
    int i;

    if (!mac || strlen(mac) == 0)
        return;

    LOG_DEBUG("reset_one_user_today_active_time: mac=%s\n", mac);

    for (i = 0; i < MAX_DEV_NODE_HASH_SIZE; i++) {
        dev_node_t *node = dev_hash_table[i];
        while (node) {
            if (strcasecmp(node->mac, mac) == 0) {
                node->today_am_active_time = 0;
                node->today_pm_active_time = 0;

                if (node->period_blocked == 1) {
                    LOG_INFO("device %s UNBLOCKED (cleared by user)\n", node->mac);
                }
                node->period_blocked = 0;
                LOG_DEBUG("reset device %s active time to 0\n", mac);

                // 同步解锁内核
                FILE *fp = fopen("/proc/sys/oaf/blocked_macs", "w");
                if (fp) {
                    fprintf(fp, "-%s", mac);
                    fclose(fp);
                }
                return;
            }
            node = node->next;
        }
    }
    LOG_DEBUG("device %s not found in hash table\n", mac);
}
