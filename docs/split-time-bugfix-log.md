# split_time 独立上网时长功能 — Bug 修复记录

## 编译错误

### Bug 1：`MAX_AF_CLIENT_HASH_SIZE` 在定义前被引用

**错误信息：**
```
error: 'MAX_AF_CLIENT_HASH_SIZE' undeclared here (not in a function)
    extern struct list_head af_client_list_table[MAX_AF_CLIENT_HASH_SIZE];
```

**原因：** 在 `oaf/src/af_client.h` 第 7 行添加了 `extern af_client_list_table` 声明，
但使用的宏 `MAX_AF_CLIENT_HASH_SIZE` 在第 11 行才定义。C 语言的 `#define` 在出现位置立即生效，
不能引用后面定义的值。

**修复：** 将 extern 声明移到 `#define MAX_AF_CLIENT_HASH_SIZE 64` 之后。

---

### Bug 2：`af_log.c` 缺少网络头文件导致 `struct in6_addr` 不完整

**错误信息：**
```
error: field 'ipv6' has incomplete type
    struct in6_addr ipv6;
```

**原因：** `af_log.c` 新增了 `#include "af_client.h"`，但 `af_client.h` 中使用了 `struct in6_addr`，
该结构体需要 `#include <linux/in6.h>` 定义。原来只有 `app_filter.c` 在包含 `af_client.h` 之前
包含了这些网络头文件，`af_log.c` 没有。

**修复：** 在 `af_log.c` 的 `#include "af_client.h"` 之前添加 `#include <linux/in6.h>`。

---

## 运行时错误

### Bug 3：LuCI Controller 缺少 `module` 声明

**错误信息：**
```
Invalid controller file found
The file '/usr/lib/lua/luci/controller/oaf_split.lua' contains an invalid module line.
Please verify whether the module name is set to 'luci.controller.oaf_split'
```

**原因：** 新建的 `luci-app-oaf/luasrc/controller/oaf_split.lua` 缺少首行的
`module("luci.controller.oaf_split", package.seeall)` 声明。LuCI/ucodebridge 要求
controller 文件必须显式声明模块名，且模块名必须与文件路径对应。

**修复：** 在文件首行添加 `module("luci.controller.oaf_split", package.seeall)`。

**检查方法：** 创建新 LuCI controller 文件时，务必检查：
1. 文件名必须唯一（如 `oaf_split.lua`）
2. 首行 `module("luci.controller.<文件名不含后缀>", package.seeall)`
3. `function index()` 中使用 `entry()` 注册路由

---

## Code Review 修复

### 修复 1：`app_filter.c` — period_blocked 移入读锁内读取

**问题：** hook 函数中 `client->period_blocked` 在 `AF_CLIENT_UNLOCK_R()` 之后读取，
可能与其他 CPU 核的写锁（`AF_CLIENT_LOCK_W()`）并发。

**修复：** 在解锁前用局部变量快照，解锁后再判断。

### 修复 2：`oaf_split.c` — `system()` → `fopen/fprintf`

**问题：** 使用 `system("echo ... >/proc/...")` 存在两份隐患：
- MAC 地址拼接 shell 命令有注入风险（虽然实际 MAC 来自硬件）
- 每轮同步多次 fork() 子进程，路由器上开销大

**修复：** 改用 `fopen("/proc/sys/oaf/blocked_macs", "w")` + `fprintf()` 直接写入。

### 修复 3：补全 `#include` 头文件

- `oaf/src/af_log.c`: 添加 `#include <linux/uaccess.h>`（`copy_from_user` 所需）
- `open-app-filter/src/oaf_split.c`: 添加 `#include <strings.h>`（`strcasecmp` 所需）
- `oaf/src/af_log.c`: 添加 `#include <linux/in6.h>`（`struct in6_addr` 所需）
