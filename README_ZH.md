
## 简介
OAF（Open Application Filter）是一款基于 OpenWrt 的上网行为管理软件。支持市面上热门的游戏、视频、即时通讯等上百种应用的识别与控制，如抖音、YouTube、Facebook 等。
详细介绍请访问 [www.openappfilter.com](http://www.openappfilter.com)。

## 功能特性
- **DPI 深度包检测**：支持七层协议解析及 HTTPS 域名解析，不依赖 DNS，识别准确率高。
- **流式识别架构**：基于连接流的识别方式，效率极高，对硬件要求极低（最低可运行在 64MB 内存设备上）。
- **自定义协议签名**：支持用户自定义应用协议特征库，灵活度高，可扩展性强。
- **插件式安装**：以 OpenWrt 插件包形式发布，兼容所有 OpenWrt 设备。可在 Releases 页面下载对应架构的安装包。
- **流量统计**（v6.2.0+）：基于内核 netfilter 的完整流量采集链路，支持按设备（IP/MAC）统计上行/下行流量，数据持久化到 SQLite 数据库，可按日/月/年查看历史流量趋势，支持图表展示和设备排行。

## 流量统计功能

OAF 从 v6.2.0 起内置了流量统计功能，架构如下：

```
数据包 → 内核 netfilter FORWARD hook → 实时流量计数 → ubus 接口
                                                          ↓
                                              traffic.uc 定期采样（默认 60s）
                                                          ↓
                                              SQLite 数据库（WAL 模式）
                                                          ↓
                                              LuCI 前端（ECharts 图表 + IP 排行）
```

### 功能要点
- **数据来源**：内核模块已内置的流量计数器（`today_up_bytes` / `today_down_bytes`），无需额外 hook。
- **存储引擎**：SQLite 数据库，默认存放在 `/tmp/oaf/traffic.db`（内存盘），定期备份到 `/etc/oaf/traffic.db.bak`（闪存），重启后自动恢复。
- **统计粒度**：每分钟采样（日视图折线图）、每日汇总、每月汇总、每年汇总。
- **设备维度**：以 MAC 为主键聚合流量，所有 IP（IPv4 + IPv6）存储在 `ip_list` 字段中。前端按设备展示，多个 IP 可折叠展开。快照基于 MAC 追踪，从根本上解决了因 IP 漂移（DHCP 变更、IPv6 地址出现/消失）导致的流量重复计算问题。
- **数据保留**：可配置，默认保留 90 天日数据、12 个月数据、5 年年数据。
- **性能**：采集频率 60 秒一次，对 CPU 和内存几乎无影响。

### 启用方式
1. 安装 `luci-app-oaf` 和 `appfilter` 包后，流量统计默认启用。
2. 在 LuCI 中进入「服务 → App Filter → 流量统计」查看流量图表和设备排行。
3. 在「服务 → App Filter → 流量配置」中可调整采集间隔、备份频率、数据保留天数等参数。
4. 如需关闭，在配置页将「启用流量采集」取消勾选即可。

### 配置项说明

| 配置项 | 默认值 | 说明 |
|---|---|---|
| 启用流量采集 | 开启 | 关闭后不再写入 SQLite，但内核计数器仍正常工作 |
| 采集间隔 | 60 秒 | 建议保持默认（与内核报告周期匹配） |
| 备份间隔 | 30 分钟 | 设为 0 可禁用自动备份 |
| 分钟数据保留 | 1 天 | 用于日视图折线图 |
| 每日数据保留 | 90 天 | 设备流量日汇总 |
| 每月数据保留 | 12 个月 | 月度趋势 |
| 每年数据保留 | 5 年 | 年度趋势 |

### 与旁路由的兼容性
如果部分设备通过旁路由（如 mihomo）上网，需要确保这些设备的**默认网关是主路由**（运行 OAF 的设备），主路由再通过策略路由将流量转发到旁路由。这样 OAF 才能在主路由的 FORWARD 链上看到设备的原始流量。如果设备网关直接指向旁路由，主路由将无法统计该设备的流量。

## 编译方法
1. 准备一套已经成功编译出固件的 OpenWrt 源码。（OpenWrt 源码的编译方法请参考独立教程，这里不作详述。）
2. 克隆 OAF 源码。进入 OpenWrt 源码根目录，执行：
```
git clone https://github.com/destan19/OpenAppFilter.git package/OpenAppFilter
```
3. 开启 OAF 编译选项。
应用过滤包含三个独立源码包，分别对应 LuCI 界面、服务守护进程、内核模块。
编译前需开启这三个包的编译选项。可通过 `make menuconfig` 图形界面勾选 `luci-app-oaf`。
也可通过命令开启（在源码根目录执行）：
```
echo "CONFIG_PACKAGE_luci-app-oaf=y" >>.config
make defconfig
```
此操作会自动将三个模块的编译选项全部开启。

4. 开始编译 OAF。
如果你之前已经成功编译过 OpenWrt 源码，可以选择单独编译这几个包：
```
make package/luci-app-oaf/compile V=s
make package/open-app-filter/compile V=s
make package/oaf/compile V=s
```
也可以重新编译整个固件，会将插件直接集成到固件中：
```
make V=s
```

## 交流群
[https://t.me/openappfilter](https://t.me/openappfilter) (Telegram)

如果在安装或使用过程中遇到问题，可以加群讨论（群刚建不久）。

## 许可证
- 个人可完全免费使用本软件，并允许在此基础上进行二次开发和发布。
- 如果在 OAF 基础上进行衍生开发，需遵守 GPL 2.0 协议，并保留 OAF 仓库或网址信息的引用。
- 如果公司想使用本软件，请联系作者进行授权。

## Star
如果你觉得这个项目对你有帮助，欢迎给一个 star。
[![Stargazers over time](https://starchart.cc/destan19/OpenAppFilter.svg?variant=adaptive)](https://starchart.cc/destan19/OpenAppFilter)
