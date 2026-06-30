# split_time 独立设备上网时长控制 — 测试方案与开发踩坑记录

## 一、测试方案

### 前置条件

1. 开启 split_time：LuCI → 时间配置 → 选择「上网时长模式」→ 打开「独立设备时长模式」
2. 设置每日限额例如 2 分钟（便于快速触发）
3. 应用过滤模式选择「指定应用」，禁止抖音
4. 至少两台设备（如小米11 + 电视）被选中

### 测试用例 A：独立计时

| 步骤 | 操作 | 预期 |
|------|------|------|
| A1 | 小米11 上网 2 分钟 | 「已用完」⛔ |
| A2 | 电视未满 2 分钟 | 电视**可以**上网 |
| A3 | 小米11 看抖音 | 被拦截（应用过滤）|
| A4 | 小米11 看哔哩哔哩 | 被拦截（split 超时）|
| A5 | 电视看哔哩哔哩 | 可以看（没超时）|

**验证命令：**
```bash
cat /proc/sys/oaf/debug_blocked | grep <设备MAC>
# 超时设备: period_blocked=1 → DROP
# 未超时设备: period_blocked=0 → ACCEPT
cat /tmp/log/appfilter.log | grep "split"
# split check: any_blocked=1  (有设备超时)
# split sync: blocked device XX:XX:XX:XX:XX:XX
```

### 测试用例 B：清空单个设备

| 步骤 | 操作 | 预期 |
|------|------|------|
| B1 | 小米11 和电视都超时 | 两台都被⛔ |
| B2 | 点小米11 卡片上的 [Clear] | 仅小米11 解封 |
| B3 | 小米11 上网 | 可以上 |
| B4 | 电视上网 | 还是被⛔ |

**验证命令：**
```bash
cat /proc/sys/oaf/debug_blocked
# 小米11: period_blocked=0
# 电视:   period_blocked=1
```

### 测试用例 C：清空全部

| 步骤 | 操作 | 预期 |
|------|------|------|
| C1 | 所有设备超时 | 全部⛔ |
| C2 | 点标题栏 [Clear] 按钮 | 全部解封 |
| C3 | 所有设备上网 | 都可以上 |

**验证命令：**
```bash
cat /proc/sys/oaf/debug_blocked
# 全部: period_blocked=0
```

### 测试用例 D：app_filter_mode 组合

设置应用过滤模式为「全部拦截」：

| 步骤 | 操作 | 预期 |
|------|------|------|
| D1 | 未超时设备上网 | 可以上（split 模式下跳过全部拦截）|
| D2 | 超时设备上网 | 被⛔（period_blocked=1）|

设置应用过滤模式为「指定应用」禁止抖音：

| 步骤 | 操作 | 预期 |
|------|------|------|
| D3 | 未超时设备看抖音 | 被拦截（应用过滤生效）|
| D4 | 未超时设备看哔哩哔哩 | 可以看（应用过滤不拦）|
| D5 | 超时设备看哔哩哔哩 | 被⛔（period_blocked=1，不走 app filter）|

---

## 二、开发踩坑记录

### Bug 1：`MAX_AF_CLIENT_HASH_SIZE` 在定义前被引用

- **文件**：`oaf/src/af_client.h`
- **症状**：编译报错 `'MAX_AF_CLIENT_HASH_SIZE' undeclared`
- **原因**：extern 声明在 `#define` 之前
- **修复**：将 extern 移到 `#define MAX_AF_CLIENT_HASH_SIZE 64` 之后

### Bug 2：`af_log.c` 缺少网络头文件

- **文件**：`oaf/src/af_log.c`
- **症状**：编译报错 `field 'ipv6' has incomplete type`
- **原因**：新增 `#include "af_client.h"` 但缺少 `<linux/in6.h>`
- **修复**：添加 `#include <linux/in6.h>`

### Bug 3：LuCI Controller 缺少 `module` 声明

- **文件**：`luci-app-oaf/luasrc/controller/oaf_split.lua`
- **症状**：页面报错 `Invalid controller file found`
- **原因**：新 controller 文件缺少 `module(...)` 首行
- **修复**：首行添加 `module("luci.controller.oaf_split", package.seeall)`

### Bug 4：`today_am/pm_active_time` 单位误解（分钟 vs 秒）

- **文件**：`open-app-filter/src/oaf_split.c`
- **症状**：split 超时判断不准确
- **原因**：netlink 代码注释 `//min`，实际单位是**分钟**。但初始代码用了 `* 60` 当作秒处理
- **修复**：去掉 `* 60`，直接比较 `current_active >= max_allowed_time`（两边都是分钟）

### Bug 5：前端 JS 多余闭合括号

- **文件**：`luci-app-oaf/luasrc/view/admin_network/time.htm`
- **症状**：JS 报 `Unexpected token '}'`，模式切换失效
- **原因**：在 `renderTimeData` 中插入 split 进度条分支时留下多余 `}`
- **修复**：删除多余 `}`，保证大括号平衡

### Bug 6：`g_split_time` 未同步到内核

- **文件**：`open-app-filter/src/main.c` / `oaf/src/af_log.c`
- **症状**：split mode 不生效，`g_split_time` 始终为 0
- **原因**：内核 `g_split_time` 变量初始值为 0，但没有任何代码写入 `/proc/sys/oaf/split_time`
- **修复**：新增 `update_oaf_split_time_status()`，在配置变更时同步到内核

### Bug 7：`copy_from_user` 在内核 6.6 的 sysctl handler 中失败

- **文件**：`oaf/src/af_log.c`
- **症状**：`blocked_macs` 写入静默失败，`period_blocked` 始终为 0。`echo "clear" > /proc/...` 返回 `Bad address`。用户态 fopen/fprintf/fclose 也不报错
- **原因**：内核 6.6 的 sysctl handler 传递的是**内核缓冲区指针**，不是用户态指针。`copy_from_user` 校验地址范围失败返回 `-EFAULT`
- **修复**：改用 `memcpy` 替代 `copy_from_user`

### Bug 8：`-MAC` 写入带 `\n` 导致 handler 拒绝

- **文件**：`open-app-filter/src/oaf_split.c`
- **症状**：清空后设备不解锁，`debug_blocked` 仍显示 `period_blocked=1`
- **原因**：`reset_one_user_today_active_time` 写入 `"-%s\n"` 带换行。内核 handler 剥离换行后 `*lenp=17`，`if (*lenp < 18) return -EINVAL` 判断为真，静默失败
- **修复**：去掉末尾 `\n`，和 `af_split_sync_blocked_macs` 的 `+MAC` 写入格式一致

### Bug 9（未修复）：`check_and_reset_today_active_time` static 变量 bug

- **文件**：`open-app-filter/src/appfilter_user.c`
- **症状**：每天 12:00 AM 重置时，只有第一个设备被清空
- **原因**：`last_reset_hour` 和 `last_reset_min` 是 static 变量，在遍历哈希表时被第一个设备设置为 12:00，后续设备不再满足条件
- **当前状态**：不影响核心功能，后续可修复

### Bug 10：误删 `LogLevel` enum 导致编译失败

- **文件**：`open-app-filter/src/appfilter.h`
- **症状**：编译报错 `'LOG_LEVEL_WARN' undeclared`、`unknown type name 'LogLevel'`
- **原因**：在添加日志文件大小截断功能时，用整段替换把 `typedef enum { ... } LogLevel;` 和 `#define OAF_VERSION` 一起删除了
- **修复**：加回 `LogLevel` enum 定义和 `OAF_VERSION`，并确保 `static int log_level = LOG_LEVEL_WARN;` 放在 enum 之后

### Bug 11：`blocked device` 日志级别过高，每 10 秒刷屏

- **文件**：`open-app-filter/src/oaf_split.c`
- **症状**：`split sync: blocked device XX:XX:XX:XX:XX:XX` 每 10 秒打印一次
- **原因**：日志级别设为 `LOG_INFO`，正常运行时也会输出
- **修复**：改为 `LOG_DEBUG`，默认不输出。同时 `clear done` 和 `any_blocked` 也降为 `LOG_DEBUG`

### Bug 12：`UNBLOCKED` 日志未触发

- **文件**：`open-app-filter/src/oaf_split.c`
- **症状**：清空设备时长后，日志未打印 `UNBLOCKED`
- **原因**：状态变化日志检测放在 `af_split_check_period_limit` 中，但 `reset_one_user_today_active_time` 直接设 `period_blocked=0` 后再检查时已无变化
- **修复**：`UNBLOCKED` 日志移到 `reset_one_user_today_active_time` 中，在 `period_blocked` 从 1 变 0 前打印

### Bug 13：`period_blocked` 无条件 NF_DROP，导致指定应用模式也全部拦截

- **文件**：`oaf/src/app_filter.c`
- **症状**：指定应用模式下，时间用完→全部拦截，用户想看百度也不行
- **原因**：`if (split_blocked) return NF_DROP` 无条件执行，未检查当前过滤模式
- **修复**：改为 `if (split_active && split_blocked && g_app_filter_mode == 1) return NF_DROP`，指定应用模式继续走到 `match_app_filter_rule`

### Bug 14：未超时设备未跳过过滤，app filter 仍生效

- **文件**：`oaf/src/app_filter.c`
- **症状**：指定应用模式下，时间未用完但抖音仍被 app filter 拦截
- **原因**：用户设计是 app filter 仅在时间用完后生效，但之前实现是未超时设备仍走到 `match_app_filter_rule`
- **修复**：新增 `if (split_active && !split_blocked) goto EXIT`，时间未用完时跳过所有过滤

### Bug 15：切换模式后仍被封锁

- **文件**：`open-app-filter/src/main.c`
- **症状**：从上网时长模式切换到固定时间模式后，之前超时的设备仍被封锁
- **原因**：切换模式后内核 `g_split_time` 未重置，`period_blocked` 也未清空
- **修复**：`update_oaf_split_time_status()` 改为非 mode=2 时写 `split_time=0` 并 `clear blocked_macs`

### Bug 12：`UNBLOCKED` 日志未触发

- **文件**：`open-app-filter/src/oaf_split.c`
- **症状**：清空设备时长后，日志未打印 `UNBLOCKED`
- **原因**：状态变化日志检测放在 `af_split_check_period_limit` 中，但 `reset_one_user_today_active_time` 直接设 `period_blocked=0` 后再检查时已无变化
- **修复**：`UNBLOCKED` 日志移到 `reset_one_user_today_active_time` 中，在 `period_blocked` 从 1 变 0 前打印

---

## 三、文件改动总览

| 层 | 文件 | 改动 |
|----|------|------|
| 内核模块 | `oaf/src/af_client.h` | +period_blocked 字段，+extern af_client_list_table |
| 内核模块 | `oaf/src/af_log.h` | +extern g_split_time |
| 内核模块 | `oaf/src/af_log.c` | +g_split_time、oaf_blocked_macs_handler、oaf_debug_blocked_handler、split_time/debug_blocked sysctl |
| 内核模块 | `oaf/src/app_filter.c` | hook 中 split_blocked/split_active 双变量检查，app_filter_mode 跳过逻辑 |
| 用户态C | `open-app-filter/src/appfilter.h` | +split_time 字段 |
| 用户态C | `open-app-filter/src/appfilter_user.h` | +period_blocked 字段 |
| 用户态C | `open-app-filter/src/oaf_split.h` | [新建] 函数声明 |
| 用户态C | `open-app-filter/src/oaf_split.c` | [新建] 独立模式全部业务逻辑 |
| 用户态C | `open-app-filter/src/main.c` | +if-else 分支、split_time 加载/保存/同步 |
| 用户态C | `open-app-filter/src/appfilter_ubus.c` | handle_cmd 支持单设备清空、get 返回 dev_time_list |
| 用户态C | `open-app-filter/src/Makefile` | +oaf_split.o |
| LuCI | `luci-app-oaf/luasrc/controller/oaf_split.lua` | [新建] 清空接口路由 |
| LuCI | `luci-app-oaf/luasrc/view/admin_network/time.htm` | split_time 开关、各设备进度条、清除按钮改造 |
| LuCI | `luci-app-oaf/luasrc/view/admin_network/app_filter.htm` | 各设备进度条卡片、清空按钮、状态显示 |
| 配置 | `open-app-filter/files/appfilter.config` | +option split_time '0' |
| 配置 | `luci-app-oaf/root/etc/uci-defaults/95_time_daily_limit` | +split_time='0' |

---

## 四、最终日志行为

| 日志内容 | 级别 | 触发条件 |
|----------|------|----------|
| `device XX BLOCKED (blocked=1, used=2min, limit=2min)` | `LOG_INFO` | 设备超时，period_blocked 0→1 | 
| `device XX UNBLOCKED (cleared by user)` | `LOG_INFO` | 用户手动清空该设备时长 |
| `device XX UNBLOCKED (blocked=0, used=0min, limit=2min)` | `LOG_INFO` | 天切换/跨午，自动解封 |
| `split sync: blocked device XX:XX:XX:XX:XX:XX` | `LOG_DEBUG` | 每 10 秒同步时（调试才可见） |
| `split sync: clear done` | `LOG_DEBUG` | 同步时（调试才可见） |
| `split check: any_blocked=0/1` | `LOG_DEBUG` | 每 10 秒检查时（调试才可见） |
| `split sync: fopen blocked_macs failed` | `LOG_WARN` | 写入 proc 失败（= 故障） |

### 开启/关闭调试日志

```bash
echo 3 > /proc/sys/oaf/debug   # 开启 DEBUG（含 split sync 等）
echo 2 > /proc/sys/oaf/debug   # 恢复 INFO（默认状态）
```
