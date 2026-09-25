# 测试

这里的测试通过 `ucode` 直接加载 `root/usr/libexec/ddm/ddm.uc` 运行，既可以在开发机上执行，也可以复制到 OpenWrt 设备上执行。

## 前提

- `ucode`（含 `fs` 模块）。OpenWrt 上为 `ucode` + `ucode-mod-fs` 两个包；也可以从上游自行编译：<https://github.com/jow-/ucode>
- 需要把核心模块所在目录加入 ucode 的模块搜索路径（ucode 的 `require()` 只按搜索路径模板解析模块名，不支持绝对路径）：`-L <repo>/root/usr/libexec/ddm`

## 单元测试

覆盖 SFF-8472 字节解析、阈值换算、未编程阈值处理，以及取数输出的解析（`raw on` 原始二进制的逐字节还原、长度校验、报错文本不被误判）与 SFF-8024 Identifier 的协议支持判定：

```sh
ucode -L ./root/usr/libexec/ddm tests/test-ddm.uc
```

输出末尾为 `ALL TESTS PASSED` 即表示全部通过（失败时退出码为 1）。

## 端到端测试

用一个模拟的 `ethtool` 伪造若干模块，覆盖 `collect()` 采集 → 门限判定 → 指标输出整条链路。取数只使用 `raw on offset X length 128`：

- `sfp0`：正常 SFF-8472 模块（数据来自 `tests/e2e/data/map.bin`），整体状态应为 `ok`
- `sfp1`：温度 88 °C（落在 85–90 的警告区间）、收光功率等于低告警门限，整体状态应为 `alarm`
- `sfp2`：非 SFF-8472 模块（Identifier = `0x0d` QSFP+），应返回 `supported=false` 且提示协议不支持，无任何指标
- `sfp3`：驱动忽略 `offset`，无论请求哪一页都只返回 A0h，应当能读到 A0h 的静态信息，但**不能**把 A0h 当成 A2h，即没有 DDM 指标（`source=none`）
- `sfp4`：完全读不到 EEPROM，`collect()` 应返回 `null`
- `sfp5`：请求 `raw on` 却返回 hexdump 文本，不应被解析（`collect()` 返回 `null`）

> `tests/e2e/data/map.bin` 是 512 字节的 SFF-8472 扁平映射二进制，其中 `0x000` 起为 A0h、`0x100` 起为 A2h。夹具会 `dd` 出对应页，`sfp1` 的实时值由夹具用 `printf` 打补丁生成。

```sh
PATH="$PWD/tests/e2e:$PATH" \
ucode -L ./root/usr/libexec/ddm tests/e2e.uc
```

## 说明

这些测试不依赖真实光模块，因此在普通 PC 上也能运行。
若要针对真实硬件验证，可直接使用命令行工具：

```sh
ddm text
ddm raw eth0 a2      # 查看 A2h 页原始字节
ddm probe eth0       # 跑取数命令，定位取不到数据的原因
```
