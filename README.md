

## Introduction
OAF is a parental control software based on OpenWrt. It supports popular applications across gaming, video streaming, instant messaging, such as TikTok, YouTube, Facebook. Currently, it supports hundreds of different applications.   
For a detailed introduction, please visit [www.openappfilter.com](http://www.openappfilter.com).

## Features
- DPI-based protocol identification: Supports Layer 7 protocol parsing and HTTPS domain resolution, and operates independently of DNS.
- Industry-standard architecture:  Flow-based identification for high efficiency, with extremely low hardware requirements.
- Supports custom protocol signatures: Offers a high degree of flexibility and customization.
- Supports installation as a plugin on OpenWrt systems: Compatible with all OpenWrt-enabled devices.You can download the plugin package corresponding to your architecture from the releases page.
- **Traffic Statistics** (v6.2.0+): Complete traffic collection pipeline based on kernel netfilter hooks. Tracks per-device (IP/MAC) upload/download traffic, persists data to SQLite, and provides daily/monthly/yearly historical views with charts and device rankings.

## Traffic Statistics

Since v6.2.0, OAF includes a built-in traffic statistics feature:

```
Packets → kernel netfilter FORWARD hook → real-time counters → ubus API
                                                                    ↓
                                                    traffic.uc samples every 60s
                                                                    ↓
                                                    SQLite database (WAL mode)
                                                                    ↓
                                                    LuCI web UI (ECharts + IP ranking)
```

### Highlights
- **Data source**: Leverages the kernel module's existing traffic counters (`today_up_bytes` / `today_down_bytes`) — no additional hooks required.
- **Storage**: SQLite database at `/tmp/oaf/traffic.db` (tmpfs), auto-backed up to `/etc/oaf/traffic.db.bak` (flash), restored on reboot.
- **Granularity**: Per-minute samples (for daily line chart), daily/monthly/yearly roll-ups.
- **Device view**: Tracked by IP with MAC and hostname; frontend aggregates by MAC. Both IPv4 and IPv6 are supported.
- **Retention**: Configurable — defaults are 90 days (daily), 12 months, 5 years.
- **Performance**: Sampling every 60 seconds with negligible CPU/memory impact.

### Getting Started
1. Install `luci-app-oaf` and `appfilter` — traffic collection is enabled by default.
2. Navigate to **Services → App Filter → Traffic Statistics** in LuCI to view charts and device rankings.
3. Go to **Services → App Filter → Traffic Config** to adjust sampling interval, backup frequency, and retention periods.
4. To disable, uncheck "Enable Traffic Collection" on the config page.

### Configuration Options

| Option | Default | Description |
|---|---|---|
| Enable Traffic Collection | on | When off, SQLite writes stop but kernel counters still work |
| Collection Interval | 60s | Recommended to match the kernel reporting cycle |
| Backup Interval | 30 min | Set to 0 to disable auto-backup |
| Minute Data Retention | 1 day | For the daily line chart |
| Daily Data Retention | 90 days | Per-device daily summaries |
| Monthly Data Retention | 12 months | Monthly trends |
| Yearly Data Retention | 5 years | Yearly trends |

### Compatibility with Transparent Proxies
If some devices route through a transparent proxy (e.g. mihomo), ensure their **default gateway is the main router** (running OAF). The main router should forward marked traffic to the proxy via policy routing. If devices use the proxy as their default gateway, the main router cannot see their original traffic for accounting.

## How to Compile
1. Prepare a set of OpenWrt source code that has already been successfully compiled into firmware.
(Instructions for compiling OpenWrt source code can be found via independent tutorials and will not be covered here.)
2. Clone the OAF source code.
Navigate to the root directory of your OpenWrt source code and execute the following command:
```
git clone https://github.com/destan19/OpenAppFilter.git package/OpenAppFilter
```
3. Enable the OAF compilation options.
Application Filtering consists of three distinct source packages, corresponding to the LuCI App, the service daemon, and the kernel module.
Before compiling, you must enable the build options for these three packages. You can do this by selecting `luci-app-oaf` via the `make menuconfig` graphical interface.
Alternatively, you can enable them by executing the following commands (run from the source code root directory):
```
echo "CONFIG_PACKAGE_luci-app-oaf=y" >>.config
make defconfig
```
This will automatically enable the compilation options for all three modules.

4. Begin compiling OAF.
If you have previously successfully compiled your OpenWrt source code, you can choose to compile only the individual packages:
```
make package/luci-app-oaf/compile V=s
make package/open-app-filter/compile V=s
make package/oaf/compile V=s
```
Alternatively, you can recompile the entire firmware image; this will integrate the plug-in directly into the firmware build:
```
make V=s
```

## Discussion Group

[https://t.me/openappfilter](https://t.me/openappfilter) (Telegram)

If you encounter some issues during installation or usage, you can join the group for discussion(The group was created only recently).

## License
- Individuals can use this software completely free of charge, and are also permitted to develop upon and redistribute it.
- If you undertake derivative development based on OAF, you must adhere to the GPL 2.0 license and retain references to the OAF repository or website information.
- If a company wishes to use this software, please contact the author for authorization.

## Star
If you find this project helpful, please give it a star.  
[![Stargazers over time](https://starchart.cc/destan19/OpenAppFilter.svg?variant=adaptive)](https://starchart.cc/destan19/OpenAppFilter)

