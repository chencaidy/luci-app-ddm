#!/usr/bin/ucode
/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * luci-app-ddm - SFP/SFP+ DDM (Digital Diagnostic Monitoring) core library
 *
 * 本文件是一个 ucode 模块，被同目录下的 cli.uc（即 /usr/bin/ddm）
 * 通过 require('ddm') 使用。
 *
 * 注意：ucode 的 require() 只能按固定的“模块搜索路径模板”解析模块名
 * （不支持 require('/abs/path.uc') 这类写法），因此 /usr/bin/ddm
 * 会以 `ucode -L /usr/libexec/ddm /usr/libexec/ddm/cli.uc` 的方式启动。
 *
 * 取数方式只有一种：
 *   `ethtool -m <iface> raw on offset 0xN length 128`
 * `raw on` 时 stdout 就是请求的那一页 EEPROM 原始字节，
 * offset 相对 SFF-8472 的 512 字节扁平映射：
 *   0x000-0x0ff = A0h（厂商信息页）
 *   0x100-0x1ff = A2h（DDM 告警门限 + 实时诊断值）
 * 不再解析 hexdump 文本，也没有文本回退。
 *
 * 协议支持：仅解析 SFF-8472（SFP/SFP+/SFP28）。
 * 模块类型由 A0h 第 0 字节的 Identifier 标识（取值定义见 SFF-8024），
 * 若不是 SFP/SFP+/SFP28，只提示“协议不支持”，不做任何解析。
 */

'use strict';

const fs = require('fs');

/* ------------------------------------------------------------------ */
/* SFF-8024 标识符 / 连接器 / 编码 对照表                                */
/* ------------------------------------------------------------------ */

/*
 * 注意：ucode 的对象字面量只允许字符串 / 标识符作为 key
 * （数字字面量 key 会报 "Expecting label"），因此这里统一使用
 * '0xNN' 形式的字符串 key，并通过 lookup() 以相同格式查询。
 */
const IDENTIFIERS = {
	'0x00': 'Unknown',
	'0x01': 'GBIC',
	'0x02': 'Module soldered to motherboard',
	'0x03': 'SFP/SFP+/SFP28',
	'0x04': 'XFP',
	'0x05': 'XENPAK',
	'0x06': 'X2',
	'0x07': 'XPAK',
	'0x08': 'XFP-E',
	'0x0b': 'XFP',
	'0x0c': 'QSFP',
	'0x0d': 'QSFP+',
	'0x0e': 'CFP',
	'0x11': 'QSFP28',
	'0x12': 'CFP2',
	'0x13': 'CFP4',
	'0x18': 'OSFP',
	'0x1e': 'SFP-DD',
	'0x1f': 'DSFP'
};

const CONNECTORS = {
	'0x00': 'Unknown',
	'0x01': 'SC',
	'0x02': 'Fibre Channel Style 1 copper',
	'0x03': 'Fibre Channel Style 2 copper',
	'0x04': 'BNC/TNC',
	'0x05': 'Fibre Channel coaxial',
	'0x06': 'FiberJack',
	'0x07': 'LC',
	'0x08': 'MT-RJ',
	'0x09': 'MU',
	'0x0a': 'SG',
	'0x0b': 'Optical pigtail',
	'0x0c': 'MPO',
	'0x0d': 'Copper pigtail',
	'0x20': 'HSSDC II',
	'0x21': 'Copper',
	'0x22': 'RJ45',
	'0x23': 'No separable connector',
	'0x24': 'MXC 2x16',
	'0x25': 'CS optical connector',
	'0x26': 'SN',
	'0x27': 'MPO 2x12',
	'0x28': 'MPO 1x16'
};

const ENCODINGS = {
	'0x00': 'Unspecified',
	'0x01': '8B/10B',
	'0x02': '4B/5B',
	'0x03': 'NRZ',
	'0x04': 'Manchester',
	'0x05': 'SONET Scrambled',
	'0x06': '64B/66B',
	'0x07': '256B/257B'
};

/* 按 '0xNN' 查询对照表，未命中时返回格式化的原始值 */
function lookup(tbl, n) {
	let v = tbl[sprintf('0x%02x', n)];

	return (v != null) ? v : sprintf('0x%02x', n);
}

/* 需要跳过的虚拟/软件接口前缀 */
const VIRTUAL_PREFIX = /^(lo|br-|vlan|veth|docker|virbr|tun|tap|wg|bond|sit|gre|ip6tnl|pppoe|rmnet|dummy|erspan|ifb|macvlan|vxlan|nlmon|can|sit0|bro|ppp)/;

/* ------------------------------------------------------------------ */
/* 通用小工具                                                          */
/* ------------------------------------------------------------------ */

function is_iface_name(n) {
	return type(n) == 'string' && match(n, /^[A-Za-z0-9][A-Za-z0-9_.:@-]{0,31}$/) != null;
}

/*
 * 同 run()，但可以自定义重定向，例如只取 stderr：
 *     run_redir('ethtool -m eth0', ' 2>&1 1>/dev/null')
 */
function run_redir(cmd, redir) {
	let p = null;
	let out = '';

	try {
		p = fs.popen(cmd + redir, 'r');
	} catch (e) {
		return '';
	}

	if (!p)
		return '';

	try {
		out = p.read('all');
	} catch (e) {
		out = '';
	}

	try {
		p.close();
	} catch (e) { }

	return (out == null) ? '' : out;
}

/* 执行外部命令并返回 stdout（stderr 丢弃），失败返回空串 */
function run(cmd) {
	return run_redir(cmd, ' 2>/dev/null');
}

/*
 * 目录列举：ucode 的 fs 模块没有 readdir()，
 * 优先使用 fs.lsdir()（返回已排序的文件名列表，不含 . 和 ..），
 * 老版本 ucode 回退到 fs.opendir()。
 */
function listdir(path) {
	if (type(fs.lsdir) == 'function') {
		let r = null;

		try { r = fs.lsdir(path); } catch (e) { r = null; }

		if (r != null)
			return r;
	}

	if (type(fs.opendir) == 'function') {
		let d = null;
		let out = [];

		try { d = fs.opendir(path); } catch (e) { d = null; }

		if (d != null) {
			let ent;

			while ((ent = d.read()) != null) {
				if (type(ent) == 'string' && ent != '.' && ent != '..')
					push(out, ent);
			}

			try { d.close(); } catch (e) { }

			return out;
		}
	}

	return [];
}

function exists(path) {
	try {
		return fs.stat(path) != null;
	} catch (e) {
		return false;
	}
}

/*
 * ucode 的数学函数位于可选的 math 模块中，核心解释器并不提供
 * log()/abs()，为不引入额外依赖，这里用 atanh 级数自行实现自然对数。
 * 结果用于把 mW 换算成 dBm 供显示，精度完全够用。
 */
const LN10 = 2.302585092994046;

function ln(x) {
	if (x == null || x <= 0)
		return null;

	let e = 0;

	while (x >= 10) { x = x / 10.0; e++; }
	while (x < 1) { x = x * 10.0; e--; }

	let t = (x - 1) / (x + 1);
	let t2 = t * t;
	let sum = 0;
	let term = t;

	for (let i = 1; i <= 41; i += 2) {
		sum += term / i;
		term = term * t2;
	}

	return 2 * sum + e * LN10;
}

function log10(x) {
	let l = ln(x);

	return (l == null) ? null : l / LN10;
}

/* 毫瓦 -> dBm，0 或负值视为无光 */
function mw2dbm(mw) {
	if (mw == null || mw <= 0)
		return null;

	return 10 * log10(mw);
}

function round_to(v, digits) {
	if (v == null)
		return null;

	let f = 1.0;

	for (let i = 0; i < digits; i++)
		f = f * 10;

	return int(v * f + ((v >= 0) ? 0.5 : -0.5)) / f;
}

/* ------------------------------------------------------------------ */
/* ethtool 原始输出解析                                                */
/* ------------------------------------------------------------------ */

/* SFF-8472 的 512 字节扁平映射：0x000 为 A0h 页，0x100 为 A2h 页 */
const A2_OFFSET = 0x100;
const PAGE_BYTES = 128;

/*
 * 本应用只支持 SFF-8472（SFP/SFP+/SFP28）。
 * SFF-8024 的 Identifier 值 0x03 即代表这一类模块，
 * 其余取值（QSFP/QSFP28/OSFP/SFP-DD 等）一律提示“协议不支持”。
 */
const SUPPORTED_IDENTIFIER = 0x03;

function protocol_supported(id) {
	return id == SUPPORTED_IDENTIFIER;
}

/*
 * 原始二进制输出 -> 字节数组。
 * ucode 的字符串与 hexenc/ord 都按字节处理，因此 `raw on` 的
 * stdout 可以直接还原（见 /memories/ucode-pitfalls.md）。
 */
function bin_to_bytes(s) {
	let out = [];

	if (type(hexenc) == 'function') {
		let h = hexenc(s);

		for (let i = 0; i + 1 < length(h); i += 2)
			push(out, int(substr(h, i, 2), 16));

		return out;
	}

	/* 没有 hexenc 时逐字节取（ord 同样是按字节的） */
	for (let i = 0; i < length(s); i++)
		push(out, ord(substr(s, i, 1)));

	return out;
}

/* hex 串里是否含 0x00 字节（按字节对齐，避免跨字节误判） */
function has_null_byte(h) {
	for (let i = 0; i + 1 < length(h); i += 2)
		if (substr(h, i, 2) == '00')
			return true;

	return false;
}

/*
 * 判断 stdout 是否是请求长度的 EEPROM 原始二进制：
 *   - 长度必须完全等于请求值（ethtool 的报错文本要短得多）
 *   - 必须含 0x00 字节（EEPROM 页一般含 0x00，报错文本不含）
 * 这样命令失败时打印的错误信息不会被当成数据。
 */
function looks_like_binary(out, want_len) {
	if (type(out) != 'string' || length(out) != want_len)
		return false;

	return has_null_byte(hexenc(out));
}

/* 解析 `ethtool -m ... raw on ...` 的二进制 stdout，失败返回 null */
function parse_raw_page(out, want_len) {
	if (!looks_like_binary(out, want_len))
		return null;

	return bin_to_bytes(out);
}

/*
 * 粗判一段字节是否可能是 A2h 页：A2h 的 0x60-0x69 是实时测量值，
 * 其中温度（0x60-0x61）与电压（0x62-0x63）不可能同时为 0，
 * 而 A0h 在这个区间是厂商保留区（通常全 0）。
 * 精确的合法性判断在 parse_a2() 里，这里只用于在多个候选之间选择。
 */
function a2_page_ok(b) {
	if (length(b) < 106)
		return false;

	for (let i = 96; i <= 105; i++)
		if (b[i] != 0)
			return true;

	return false;
}

/* --------- 字节访问器 --------- */

function u16(b, o) {
	if (o < 0 || o + 1 >= length(b))
		return null;

	return b[o] * 256 + b[o + 1];
}

function s16(b, o) {
	let v = u16(b, o);

	if (v == null)
		return null;

	return (v >= 32768) ? (v - 65536) : v;
}

function ascii(b, o, n) {
	let s = '';

	for (let i = o; i < o + n && i < length(b); i++) {
		let c = b[i];

		if (c == 0)
			break;

		s += (c >= 0x20 && c <= 0x7e) ? chr(c) : '.';
	}

	return trim(s);
}

function hexcolon(b, o, n) {
	let s = '';

	for (let i = o; i < o + n && i < length(b); i++) {
		if (i > o)
			s += ':';

		s += sprintf('%02x', b[i]);
	}

	return s;
}

/* --------- A0h（基本信息页，SFF-8472 Table 8-1） --------- */

function parse_a0(b) {
	if (length(b) < 96)
		return null;

	/* 全 0x00 / 全 0xff 视为空模块 */
	let zero = true, ones = true;

	for (let i = 0; i < 32; i++) {
		if (b[i] != 0x00) zero = false;
		if (b[i] != 0xff) ones = false;
	}

	if (zero || ones)
		return null;

	let id = b[0];
	let id_name = IDENTIFIERS[sprintf('0x%02x', id)];

	return {
		identifier: id,
		identifier_name: (id_name != null) ? id_name : sprintf('Unknown (0x%02x)', id),
		ext_identifier: b[1],
		connector: b[2],
		connector_name: lookup(CONNECTORS, b[2]),
		encoding: b[11],
		encoding_name: lookup(ENCODINGS, b[11]),
		bitrate_mbps: b[12] * 100,
		length_smf_m: (b[14] > 0) ? b[14] * 1000 : b[15] * 100,
		length_om3_m: b[19] * 10,
		length_copper_m: b[18],
		vendor: ascii(b, 20, 16),
		vendor_oui: hexcolon(b, 37, 3),
		part_number: ascii(b, 40, 16),
		revision: ascii(b, 56, 4),
		wavelength_nm: u16(b, 60),
		serial: ascii(b, 68, 16),
		date_code: ascii(b, 84, 8),
		ddm_implemented: (b[92] & 0x40) != 0,
		ddm_internally_calibrated: (b[92] & 0x20) != 0,
		ddm_externally_calibrated: (b[92] & 0x10) != 0,
		rx_power_average: (b[92] & 0x08) != 0
	};
}

/* --------- A2h（DDM 页，SFF-8472 Table 9-11） --------- */

/*
 * 阈值：raw 0x0000 / 0xffff 代表模块未编程该阈值，返回 null。
 *
 * 注意 ucode 的算术陷阱：两个整数相除会按 C 语义截断
 * （如 36000 / 10000 == 3），因此所有换算都必须让除数带上
 * 小数部分（10000.0），否则浮点结果会被抹掉。
 */

function th_temp(b, o) {
	let v = s16(b, o);

	if (v == null || v == 0 || v == -1)
		return null;

	return v / 256.0;
}

function th_volt(b, o) {
	let v = u16(b, o);

	if (v == null || v == 0 || v == 0xffff)
		return null;

	return v / 10000.0;
}

function th_bias(b, o) {
	let v = u16(b, o);

	if (v == null || v == 0 || v == 0xffff)
		return null;

	return v * 2.0 / 1000.0;
}

function th_power(b, o) {
	let v = u16(b, o);

	if (v == null || v == 0 || v == 0xffff)
		return null;

	return v / 10000.0;
}

function parse_a2(b) {
	if (length(b) < 106)
		return null;

	/* 实时值区全为 0x00 说明这一页是空的（供电电压不可能为 0） */
	let empty = true;

	for (let i = 96; i <= 105; i++) {
		if (b[i] != 0x00) {
			empty = false;
			break;
		}
	}

	if (empty)
		return null;

	/*
	 * 实时值（A2h 0x60-0x69）不做“0 表示未编程”的过滤，
	 * 因为 0 °C / 0 mW 都是合法的测量结果。
	 */
	let t_raw = s16(b, 96);
	let v_raw = u16(b, 98);
	let c_raw = u16(b, 100);
	let tx_raw = u16(b, 102);
	let rx_raw = u16(b, 104);

	let d = {
		temperature_c: (t_raw != null) ? round_to(t_raw / 256.0, 2) : null,
		voltage_v: (v_raw != null) ? round_to(v_raw / 10000.0, 4) : null,
		tx_bias_ma: (c_raw != null) ? round_to(c_raw * 2.0 / 1000.0, 3) : null,
		tx_power_mw: (tx_raw != null) ? tx_raw / 10000.0 : null,
		rx_power_mw: (rx_raw != null) ? rx_raw / 10000.0 : null
	};

	d.tx_power_dbm = round_to(mw2dbm(d.tx_power_mw), 2);
	d.rx_power_dbm = round_to(mw2dbm(d.rx_power_mw), 2);

	d.thresholds = {
		temperature: {
			high_alarm: th_temp(b, 0),
			low_alarm: th_temp(b, 2),
			high_warning: th_temp(b, 4),
			low_warning: th_temp(b, 6)
		},
		voltage: {
			high_alarm: th_volt(b, 8),
			low_alarm: th_volt(b, 10),
			high_warning: th_volt(b, 12),
			low_warning: th_volt(b, 14)
		},
		tx_bias: {
			high_alarm: th_bias(b, 16),
			low_alarm: th_bias(b, 18),
			high_warning: th_bias(b, 20),
			low_warning: th_bias(b, 22)
		},
		tx_power: {
			high_alarm: th_power(b, 24),
			low_alarm: th_power(b, 26),
			high_warning: th_power(b, 28),
			low_warning: th_power(b, 30)
		},
		rx_power: {
			high_alarm: th_power(b, 32),
			low_alarm: th_power(b, 34),
			high_warning: th_power(b, 36),
			low_warning: th_power(b, 38)
		}
	};

	return d;
}

/* ------------------------------------------------------------------ */
/* EEPROM 读取（ethtool 命令组合与页选择）                              */
/* ------------------------------------------------------------------ */

/*
 * 页数据是否合理：A0h 必须能被 parse_a0() 接受，A2h 的实时值区
 * （0x60-0x69）不能全为 0。
 *
 * 校验的作用：驱动忽略 offset、无论怎么请求都返回同一页时，
 * A0h 的数据不会被当成 A2h 用（这种情况下 A2h 应判定为「读不到」）。
 */
function page_ok(page, b) {
	if (length(b) < 96)
		return false;

	return (page == 0xa0) ? (parse_a0(b) != null) : a2_page_ok(b);
}

/*
 * 读取一页原始字节：只使用
 *   `ethtool -m <if> raw on offset 0xN length 128`
 * `raw on` 时 stdout 就是 EEPROM 字节本身（长度 = 请求的 length），
 * offset 相对 SFF-8472 的 512 字节扁平映射（0x000 = A0h，0x100 = A2h）。
 *
 * 返回 { bytes, source }，取不到数据时 bytes 为空。
 */
function read_page_raw(iface, page) {
	let off = (page == 0xa0) ? 0 : A2_OFFSET;
	let cmd = 'ethtool -m ' + iface + ' raw on offset ' + sprintf('0x%x', off) +
		' length ' + PAGE_BYTES;
	let b = parse_raw_page(run(cmd), PAGE_BYTES);

	if (b == null)
		return { bytes: [], source: 'none' };

	return { bytes: b, source: cmd };
}

/* 读取一页并做合法性校验（见 page_ok），非法时长度为 0 */
function read_page_ex(iface, page) {
	let r = read_page_raw(iface, page);

	if (length(r.bytes) == 0 || page_ok(page, r.bytes))
		return r;

	return { bytes: [], source: r.source };
}

function read_page(iface, page) {
	return read_page_ex(iface, page).bytes;
}

/* ------------------------------------------------------------------ */
/* 指标状态判定                                                        */
/* ------------------------------------------------------------------ */

function metric_status(val, t) {
	if (val == null || t == null || type(t) != 'object')
		return 'na';

	if (t.high_alarm != null && val >= t.high_alarm) return 'alarm';
	if (t.low_alarm != null && val <= t.low_alarm) return 'alarm';
	if (t.high_warning != null && val >= t.high_warning) return 'warning';
	if (t.low_warning != null && val <= t.low_warning) return 'warning';

	return 'ok';
}

/* 对外暴露的指标定义：key -> ddm 字段 + 单位 + dBm 字段 */
const METRIC_KEYS = ['temperature', 'voltage', 'tx_bias', 'tx_power', 'rx_power'];
const METRIC_FIELDS = {
	temperature: 'temperature_c',
	voltage: 'voltage_v',
	tx_bias: 'tx_bias_ma',
	tx_power: 'tx_power_mw',
	rx_power: 'rx_power_mw'
};
const METRIC_UNITS = {
	temperature: '\u00b0C',
	voltage: 'V',
	tx_bias: 'mA',
	tx_power: 'mW',
	rx_power: 'mW'
};
const METRIC_DBM = {
	tx_power: 'tx_power_dbm',
	rx_power: 'rx_power_dbm'
};
const METRIC_ROUND = {
	temperature: 2,
	voltage: 3,
	tx_bias: 3,
	tx_power: 4,
	rx_power: 4
};

function build_metrics(ddm) {
	let metrics = [];

	for (let k in METRIC_KEYS) {
		let field = METRIC_FIELDS[k];
		let val = ddm[field];

		if (val == null)
			continue;

		let th = (ddm.thresholds != null) ? ddm.thresholds[k] : null;

		push(metrics, {
			key: k,
			field: field,
			unit: METRIC_UNITS[k],
			value: round_to(val, METRIC_ROUND[k]),
			dbm: (METRIC_DBM[k] != null) ? ddm[METRIC_DBM[k]] : null,
			status: metric_status(val, th),
			thresholds: (th != null) ? th : {}
		});
	}

	return metrics;
}

function worst_status(metrics) {
	let worst = 'ok';

	for (let m in metrics) {
		if (m.status == 'alarm')
			worst = 'alarm';
		else if (m.status == 'warning' && worst != 'alarm')
			worst = 'warning';
	}

	return worst;
}

/* ------------------------------------------------------------------ */
/* 接口发现与采集                                                      */
/* ------------------------------------------------------------------ */

function interfaces() {
	let names = listdir('/sys/class/net');
	let out = [];

	names = sort(names);

	for (let n in names) {
		if (type(n) != 'string' || length(n) == 0)
			continue;

		if (match(n, VIRTUAL_PREFIX))
			continue;

		if (!exists('/sys/class/net/' + n))
			continue;

		push(out, n);
	}

	return out;
}

/*
 * 模块不是 SFF-8472（SFP/SFP+/SFP28）时的返回结构：
 * 只给出“协议不支持”的提示，不做任何 DDM 解析。
 * 类型名取自 SFF-8024 的 Identifier 对照表。
 */
function unsupported_result(iface, id) {
	let name = IDENTIFIERS[sprintf('0x%02x', id)];

	if (name == null)
		name = sprintf('Unknown (0x%02x)', id);

	return {
		interface: iface,
		present: true,
		supported: false,
		source: 'none',
		status: 'na',
		identifier: id,
		identifier_name: name,
		meta: {
			identifier: id,
			identifier_name: name
		},
		ddm: { thresholds: {} },
		metrics: [],
		time: time()
	};
}

function collect(iface) {
	if (!is_iface_name(iface))
		return null;

	/* 先读 A0h：第 0 字节是 SFF-8024 的 Identifier */
	let a0r = read_page_raw(iface, 0xa0);

	if (length(a0r.bytes) == 0)
		return null;

	let id = a0r.bytes[0];

	/* 只支持 SFF-8472；其他类型只提示协议不支持 */
	if (!protocol_supported(id))
		return unsupported_result(iface, id);

	let meta = parse_a0(a0r.bytes);

	if (meta == null)
		return null;

	/* A2h 读不到时仍上报静态信息，只是没有 DDM 指标 */
	let a2 = parse_a2(read_page_raw(iface, 0xa2).bytes);
	let ddm = (a2 != null) ? a2 : { thresholds: {} };
	let source = (a2 != null) ? 'eeprom' : 'none';

	if (ddm.thresholds == null)
		ddm.thresholds = {};

	let metrics = build_metrics(ddm);

	return {
		interface: iface,
		present: true,
		supported: true,
		source: source,
		status: worst_status(metrics),
		meta: meta,
		ddm: ddm,
		metrics: metrics,
		time: time()
	};
}

function status() {
	let res = {
		time: time(),
		count: 0,
		ethtool: length(trim(run('command -v ethtool'))) > 0,
		interfaces: []
	};

	for (let n in interfaces()) {
		let c = collect(n);

		if (c != null)
			push(res.interfaces, c);
	}

	res.count = length(res.interfaces);

	return res;
}

function alerts() {
	let res = status();
	let out = [];

	for (let itf in res.interfaces) {
		for (let m in itf.metrics) {
			if (m.status == 'alarm' || m.status == 'warning')
				push(out, {
					interface: itf.interface,
					metric: m.key,
					status: m.status,
					value: m.value,
					unit: m.unit,
					thresholds: m.thresholds
				});
		}
	}

	return out;
}

/* ------------------------------------------------------------------ */

return {
	IDENTIFIERS: IDENTIFIERS,
	CONNECTORS: CONNECTORS,
	ENCODINGS: ENCODINGS,
	METRIC_KEYS: METRIC_KEYS,
	SUPPORTED_IDENTIFIER: SUPPORTED_IDENTIFIER,
	is_iface_name: is_iface_name,
	protocol_supported: protocol_supported,
	interfaces: interfaces,
	collect: collect,
	status: status,
	alerts: alerts,
	parse_raw_page: parse_raw_page,
	parse_a0: parse_a0,
	parse_a2: parse_a2,
	a2_page_ok: a2_page_ok,
	read_page_raw: read_page_raw,
	read_page: read_page,
	read_page_ex: read_page_ex,
	run: run,
	run_redir: run_redir
};
