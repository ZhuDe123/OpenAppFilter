#ifndef _OAF_SPLIT_H_
#define _OAF_SPLIT_H_

#include "appfilter.h"
#include "appfilter_user.h"

/*
 * 独立模式检查：逐设备比较 today_am/pm_active_time → 超时设 period_blocked=1
 * 返回值：1=至少有一台超时, 0=全部未超时
 */
int af_split_check_period_limit(af_time_config_t *t_config);

/*
 * 将用户态 dev_hash_table 中的封锁状态同步到内核
 * 通过 /proc/sys/oaf/blocked_macs 通信
 */
void af_split_sync_blocked_macs(void);

/*
 * 按 MAC 精确清空单个设备的今日时长和封锁状态
 */
void reset_one_user_today_active_time(const char *mac);

#endif
