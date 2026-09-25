# luci-app-ddm

OpenWrt LuCI 应用，用于**监控系统中的 SFP 网卡（光模块）并解析 DDM 数字诊断信息**。

DDM（Digital Diagnostic Monitoring，数字诊断监控）依据 **SFF-8472** 标准，在 SFP/SFP+/SFP28 光模块内部的 EEPROM（A2h 页）中保存实时测量值与告警/警告门限，本应用将其完整解析并以可视化界面呈现。

---

## 功能

- 自动发现系统中所有带 SFP 光模块的网卡接口（通过 `/sys/class/net` + `ethtool -m` 探测）
- 解析 **A0h 页** 静态信息
  - 模块类型（仅支持 SFP / SFP+ / SFP28；其他类型按 SFF-8024 的 Identifier 识别并提示「协议不支持」）
  - 厂商名称、厂商 OUI、型号（PN）、版本（Rev）、序列号（SN）、生产日期
  - 连接器类型（LC / MPO / RJ45 …）、编码方式（NRZ / 64B/66B …）
  - 标称速率（Mbps）、波长（nm）、传输距离
- 解析 **A2h 页** DDM 实时数据
  - 模块温度（°C）
  - 供电电压（V）
  - 发射偏置电流（mA）
  - 发射光功率（mW / dBm）
  - 接收光功率（mW / dBm）
- 解析并展示每项指标的 **低告警 / 低警告 / 高警告 / 高告警** 门限
- 自动判定 `正常 / 警告 / 告警` 状态，UI 中以颜色徽章 + 阈值区间条展示
- 支持自动刷新（5 秒）与手动刷新
- 提供 `ddm` 命令行工具，可用于脚本与状态检查
- 可选的后台守护进程，指标越限时写入 syslog

## 数据来源

`ddm` 只使用一种取数方式（`ethtool(8)`：`raw on` 时把 EEPROM 原始字节直接写到 stdout）：

```sh
ethtool -m <if> raw on offset 0xN length 128
```

`offset` 相对 SFF-8472 的 512 字节**扁平映射**（A0h / A2h 两页各读一次）：

| 扁平偏移 | 页 | 内容 |
| --- | --- | --- |
| `0x000 - 0x0ff` | A0h | 厂商信息、连接器、波长、速率 |
| `0x100 - 0x1ff` | A2h | DDM 告警/警告门限（0x00-0x27）+ 实时值（0x60-0x69） |

因此对每个接口只跑两条命令（A0h 一条、A2h 一条），不解析 hexdump 文本，也没有文本输出回退。

> **注意**：`ethtool -m` 需要网卡驱动实现 `get_module_eeprom`。
> 驱动未实现该回调时读不到 EEPROM，该接口直接视为不可用。

### 协议支持

只解析 **SFF-8472（SFP/SFP+/SFP28）**。

模块类型由 A0h 第 0 字节的 **Identifier** 判定，取值定义见 **SFF-8024**；
不是 SFP/SFP+/SFP28 的模块（QSFP / QSFP+ / QSFP28 / OSFP / SFP-DD / DSFP / XFP / CFP 等）只给出 **协议不支持** 的提示，不做任何解析。

### 排查取不到数据

```sh
ddm raw eth0 a0    # 看实际取到的 A0h 字节（第一字节即 SFF-8024 Identifier）
ddm raw eth0 a2    # 看实际取到的 A2h 字节
ddm info eth0      # 看解析后的 JSON
```

若 `ddm raw` 报 `no EEPROM data`，可手工执行
`ethtool -m <if> raw on offset 0x0 length 128` 确认网卡驱动是否实现了 `get_module_eeprom` 回调。

## 依赖

- `luci-base`
- `ucode`、`ucode-mod-fs`（核心解析使用 ucode 编写）
- `rpcd`、`rpcd-mod-ucode`（ubus 后端）
- `ethtool`（读取光模块 EEPROM）

## 编译安装

### 方式一：加入 OpenWrt 源码树（推荐）

```sh
# 将本目录放入 package/ 或 feeds 目录
cp -r luci-app-ddm <openwrt>/package/

cd <openwrt>
make menuconfig          # LuCI -> Applications -> luci-app-ddm
make package/luci-app-ddm/compile V=s
```

### 方式二：作为 feeds 使用

```sh
echo "src-link ddm /path/to/parent-of-luci-app-ddm" >> feeds.conf.default
./scripts/feeds update ddm
./scripts/feeds install luci-app-ddm
make menuconfig
```

## 命令行用法

```sh
ddm status              # 输出全部 SFP 接口的完整 JSON
ddm text                # 人类可读的报告
ddm list                # 仅列出检测到的 SFP 接口名
ddm info eth0           # 单个接口的 JSON
ddm check               # 检查告警，越限时退出码为 1（可配合 cron/monitor）
ddm check --quiet       # 只返回退出码，不输出
ddm raw eth0 a0         # 打印 A0h 页（SID）原始 hexdump
ddm raw eth0 a2         # 打印 A2h 页（DDM）原始 hexdump
```

示例：

```json
{
  "interface": "eth0",
  "source": "eeprom",
  "status": "ok",
  "meta": {
    "identifier_name": "SFP/SFP+/SFP28",
    "vendor": "FS",
    "part_number": "SFP-10G-SR",
    "serial": "G2306123456",
    "connector_name": "LC",
    "wavelength_nm": 850,
    "bitrate_mbps": 10300
  },
  "ddm": {
    "temperature_c": 43.52,
    "voltage_v": 3.3024,
    "tx_bias_ma": 6.098,
    "tx_power_mw": 0.5123,
    "tx_power_dbm": -2.9,
    "rx_power_mw": 0.631,
    "rx_power_dbm": -2.0
  },
  "metrics": [
    {
      "key": "temperature",
      "value": 43.52,
      "unit": "°C",
      "status": "ok",
      "thresholds": {
        "high_alarm": 90,
        "low_alarm": -10,
        "high_warning": 85,
        "low_warning": 0
      }
    }
  ]
}
```

## UCI 配置

`/etc/config/ddm`：

```sh
config ddm 'main'
    option enabled '0'            # 是否启用后台告警守护进程
    option interval '60'          # 采集周期（秒）
    option log_changes_only '1'   # 仅在状态变化时写 syslog
```

启用后台守护：

```sh
uci set ddm.main.enabled='1'
uci commit ddm
/etc/init.d/ddm enable
/etc/init.d/ddm start
```

日志示例（`logread -e ddm`）：

```text
ddm: eth0: temperature is warning (78.5 °C, limit 75)
ddm: SFP DDM alarm/warning cleared
```

## 目录结构

```sh
luci-app-ddm/
├── Makefile
├── htdocs/luci-static/resources/view/ddm/status.js   # LuCI 前端视图
├── po/
│   ├── templates/luci-app-ddm.pot
│   └── zh_Hans/luci-app-ddm.po                       # 简体中文翻译
├── tests/                                            # 单元测试 / 端到端测试
└── root/
    ├── etc/
    │   ├── config/ddm                                # UCI 配置
    │   └── init.d/ddm                                # procd 服务
    └── usr/
        ├── bin/ddm                                   # 命令行入口（shell 包装）
        ├── libexec/ddm/
        │   ├── ddm.uc                                # SFF-8472 解析核心（ucode 模块）
        │   ├── cli.uc                                # CLI 实现，require('ddm')
        │   └── ddm-daemon.sh                         # 告警守护循环
        └── share/
            ├── luci/menu.d/luci-app-ddm.json         # 菜单项
            └── rpcd/
                ├── acl.d/luci-app-ddm.json           # 访问控制
                └── ucode/ddm                         # ubus 后端（ddm.status / list / info）
```

> **关于 `-L` 参数**：ucode 的 `require()` 只会按固定的“模块搜索路径模板”
> 解析模块名，不支持 `require('/abs/path.uc')` 这类写法。因此 `/usr/bin/ddm`
> 实际执行的是 `ucode -L /usr/libexec/ddm /usr/libexec/ddm/cli.uc "$@"`，
> 而 rpcd 插件则通过调用 `/usr/bin/ddm` 复用同一份解析实现。

## ubus 接口

```sh
ubus call ddm status
ubus call ddm list
ubus call ddm info '{"interface":"eth0"}'
```

## 测试

`tests/` 下提供了不依赖真实光模块的测试（伪造 `ethtool` 输出）：

```sh
# 单元测试：字节解析 / 门限换算 / 文本解析
ucode -L ./root/usr/libexec/ddm tests/test-ddm.uc

# 端到端测试：完整采集链路 + 告警判定
PATH="$PWD/tests/e2e:$PATH" ucode -L ./root/usr/libexec/ddm tests/e2e.uc
```

详见 `tests/README.md`。

## 已知限制

- 只支持 **SFP/SFP+/SFP28（SFF-8472）** 的字节级解析。
  QSFP / QSFP+ / QSFP28 / OSFP / SFP-DD / DSFP / XFP / CFP 等其他类型（类型名按 **SFF-8024** 的 Identifier 判定）只给出「协议不支持」的提示，
  不解析 SFF-8636 / CMIS 数据，也不做逐通道（lane）解析。
- 光功率计算采用模块内部的线性换算（`0.1 µW` 单位）。
  少数使用外部校准（external calibration）系数的模块可能略有偏差。
- 未经编程（raw 为 `0x0000` / `0xffff`）的告警门限会被视为“无限制”，不参与状态判定。

## 许可证

Apache License 2.0
