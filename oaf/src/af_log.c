#include <linux/init.h>
#include <linux/fs.h>
#include <linux/version.h>
#include <linux/seq_file.h>
#include <linux/list.h>
#include <linux/string.h>
#include <linux/sysctl.h>
#include <linux/uaccess.h>
#include <linux/slab.h>
#include <linux/in6.h>
#include "app_filter.h"
#include "af_log.h"
#include "af_client.h"
int af_log_lvl = 1;
int af_test_mode = 0;
// todo: rename af_log.c
int g_oaf_filter_enable __read_mostly = 0;
int g_oaf_record_enable __read_mostly = 0;
int g_by_pass_accl = 1;
int g_user_mode = 0;
int af_work_mode = AF_MODE_GATEWAY;
unsigned int af_lan_ip = 0;
unsigned int af_lan_mask = 0;
char g_lan_ifname[64] = "br-lan";
int g_tcp_rst = 1;
int g_feature_init = 0;
char g_oaf_version[64] = AF_VERSION;
int g_disable_quic = 0;
int g_app_filter_mode = 0; // 0 = specified apps, 1 = all apps
int g_split_time = 0;   // 新增：独立设备分时模式（0=共享, 1=独立）
/* 
	自定义 proc handler：解析用户态写入的封锁/解锁 MAC 指令
	格式: "+AA:BB:CC:DD:EE:FF" 封锁, "-AA:BB:CC:DD:EE:FF" 解锁, "clear" 全部解锁
*/
static int oaf_blocked_macs_handler(struct ctl_table *table, int write,
                                    void __user *buffer, size_t *lenp, loff_t *ppos)
{
	char kbuf[256];
	int i;
	unsigned char mac[MAC_ADDR_LEN];
	
	if (!write)
		return 0;

	if (*lenp >= sizeof(kbuf))
		return -EINVAL;
	
	memcpy(kbuf, buffer, *lenp);

	// 去除尾部换行/回车
	while (*lenp > 0 && (kbuf[*lenp-1] == '\n' || kbuf[*lenp-1] == '\r'))
		kbuf[--(*lenp)] = '\0';
	kbuf[*lenp] = '\0';

	if (strcmp(kbuf, "clear") == 0) {
		AF_CLIENT_LOCK_W();
		for (i = 0; i < MAX_AF_CLIENT_HASH_SIZE; i++) {
			struct list_head *pos;
			list_for_each(pos, &af_client_list_table[i]) {
				af_client_info_t *c = list_entry(pos, af_client_info_t, hlist);
				c->period_blocked = 0;
			}
		}
		AF_CLIENT_UNLOCK_W();
		return 0;
	}

	if (*lenp < 18) return -EINVAL;

	char op = kbuf[0];
	if (op != '+' && op != '-') return -EINVAL;

	if (sscanf(kbuf + 1, "%hhx:%hhx:%hhx:%hhx:%hhx:%hhx",
	           &mac[0], &mac[1], &mac[2], &mac[3], &mac[4], &mac[5]) != 6)
		return -EINVAL;

	AF_CLIENT_LOCK_W();
	for (i = 0; i < MAX_AF_CLIENT_HASH_SIZE; i++) {
		struct list_head *pos;
		list_for_each(pos, &af_client_list_table[i]) {
			af_client_info_t *c = list_entry(pos, af_client_info_t, hlist);
			if (memcmp(c->mac, mac, MAC_ADDR_LEN) == 0) {
				c->period_blocked = (op == '+') ? 1 : 0;
				AF_CLIENT_UNLOCK_W();
				return 0;
			}
		}
	}
	AF_CLIENT_UNLOCK_W();
	return 0;
}

/*
 * debug_blocked handler — 读取时输出所有设备的封锁状态
 */
static char g_debug_blocked_buf[2048];

static int oaf_debug_blocked_handler(struct ctl_table *table, int write,
                                     void __user *buffer, size_t *lenp, loff_t *ppos)
{
	int pos = 0, i;

	if (write)
		return 0;

	if (*ppos == 0) {
		memset(g_debug_blocked_buf, 0, sizeof(g_debug_blocked_buf));
		pos += snprintf(g_debug_blocked_buf + pos, sizeof(g_debug_blocked_buf) - pos,
		                "split_time=%d  enable=%d  app_filter_mode=%d\n\n",
		                g_split_time, g_oaf_filter_enable, g_app_filter_mode);

		AF_CLIENT_LOCK_R();
		for (i = 0; i < MAX_AF_CLIENT_HASH_SIZE; i++) {
			struct list_head *p;
			list_for_each(p, &af_client_list_table[i]) {
				af_client_info_t *c = list_entry(p, af_client_info_t, hlist);
				pos += snprintf(g_debug_blocked_buf + pos, sizeof(g_debug_blocked_buf) - pos,
				                "MAC:" MAC_FMT "  period_blocked=%d  -> %s\n",
				                MAC_ARRAY(c->mac), c->period_blocked,
				                c->period_blocked ? "DROP" : "ACCEPT");
			}
		}
		AF_CLIENT_UNLOCK_R();
	}

	return proc_dostring(table, write, buffer, lenp, ppos);
}

/* 
	cat /proc/sys/oaf/debug
*/
static struct ctl_table oaf_table[] = {
	{
		.procname	= "debug",
		.data		= &af_log_lvl,
		.maxlen 	= sizeof(int),
		.mode		= 0666,
		.proc_handler	= proc_dointvec,
	},
	{
		.procname	= "feature_init",
		.data		= &g_feature_init,
		.maxlen 	= sizeof(int),
		.mode		= 0666,
		.proc_handler	= proc_dointvec,
	},
	{
		.procname	= "version",
		.data		= g_oaf_version,
		.maxlen 	= 64,
		.mode		= 0444,
		.proc_handler = proc_dostring,
	},
	{
		.procname	= "test_mode",
		.data		= &af_test_mode,
		.maxlen 	= sizeof(int),
		.mode		= 0666,
		.proc_handler	= proc_dointvec,
	},
	{
		.procname	= "enable",
		.data		= &g_oaf_filter_enable,
		.maxlen 	= sizeof(int),
		.mode		= 0666,
		.proc_handler	= proc_dointvec,
	},
	{
		.procname	= "by_pass_accl",
		.data		= &g_by_pass_accl,
		.maxlen 	= sizeof(int),
		.mode		= 0666,
		.proc_handler	= proc_dointvec,
	},
	{
		.procname	= "tcp_rst",
		.data		= &g_tcp_rst,
		.maxlen 	= sizeof(int),
		.mode		= 0666,
		.proc_handler	= proc_dointvec,
	},
	{
		.procname	= "lan_ifname",
		.data		= g_lan_ifname,
		.maxlen 	= 64,
		.mode		= 0666,
		.proc_handler = proc_dostring,
	},
	{
		.procname	= "record_enable",
		.data		= &g_oaf_record_enable,
		.maxlen 	= sizeof(int),
		.mode		= 0666,
		.proc_handler	= proc_dointvec,
	},
	{
		.procname	= "user_mode",
		.data		= &g_user_mode,
		.maxlen 	= sizeof(int),
		.mode		= 0666,
		.proc_handler	= proc_dointvec,
	},
	{
		.procname	= "work_mode",
		.data		= &af_work_mode,
		.maxlen 	= sizeof(int),
		.mode		= 0666,
		.proc_handler	= proc_dointvec,
	},
	{
		.procname	= "lan_ip",
		.data		= &af_lan_ip,
		.maxlen = 	sizeof(unsigned int),
		.mode		= 0666,
		.proc_handler	= proc_douintvec,
	},
	{
		.procname = "lan_mask",
		.data = &af_lan_mask,
		.maxlen = sizeof(unsigned int),
		.mode = 0666,
		.proc_handler = proc_douintvec,
	},
	{
		.procname	= "disable_quic",
		.data		= &g_disable_quic,
		.maxlen 	= sizeof(int),
		.mode		= 0666,
		.proc_handler	= proc_dointvec,
	},
	{
		.procname	= "app_filter_mode",
		.data		= &g_app_filter_mode,
		.maxlen 	= sizeof(int),
		.mode		= 0666,
		.proc_handler	= proc_dointvec,
	},
	{
		.procname	= "split_time",
		.data		= &g_split_time,
		.maxlen 	= sizeof(int),
		.mode		= 0666,
		.proc_handler	= proc_dointvec,
	},
	{
		.procname	= "blocked_macs",
		.data		= NULL,
		.maxlen 	= 256,
		.mode		= 0222,
		.proc_handler	= oaf_blocked_macs_handler,
	},
	{
		.procname	= "debug_blocked",
		.data		= g_debug_blocked_buf,
		.maxlen 	= sizeof(g_debug_blocked_buf),
		.mode		= 0444,
		.proc_handler	= oaf_debug_blocked_handler,
	},
#if (LINUX_VERSION_CODE < KERNEL_VERSION(6, 12, 0))
	{
	}
#endif
};
#define OAF_SYS_PROC_DIR "oaf"

static struct ctl_table oaf_root_table[] = {
	{
		.procname	= OAF_SYS_PROC_DIR,
		.mode		= 0555,
#if (LINUX_VERSION_CODE < KERNEL_VERSION(6, 4, 0))
		.child		= oaf_table,
#endif
	},
	{}
};
static struct ctl_table_header *oaf_table_header;


static int af_init_log_sysctl(void)
{
#if (LINUX_VERSION_CODE < KERNEL_VERSION(6, 4, 0))
	oaf_table_header = register_sysctl_table(oaf_root_table);
#else
	oaf_table_header = register_sysctl(OAF_SYS_PROC_DIR, oaf_table);
#endif
	if (oaf_table_header == NULL){
		printk("init log sysctl...failed\n");
		return -ENOMEM;
	}
	return 0;
}

static int af_fini_log_sysctl(void)
{
	if (oaf_table_header)
		unregister_sysctl_table(oaf_table_header);
	return 0;
}

int af_log_init(void){
	af_init_log_sysctl();
	return 0;
}

int af_log_exit(void){
	af_fini_log_sysctl();
	return 0;
}
