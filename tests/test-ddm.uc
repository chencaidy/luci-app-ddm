#!/usr/bin/ucode
'use strict';

const ddm = require('ddm');

function put(buf, off, bytes) {
	for (let i = 0; i < length(bytes); i++)
		buf[off + i] = bytes[i];
}

function ascii_bytes(s, n) {
	let b = [];

	for (let i = 0; i < n; i++)
		push(b, (i < length(s)) ? ord(substr(s, i, 1)) : 0x20);

	return b;
}

/* ---------------- 构造 A0h 页 ---------------- */
let a0 = [];

for (let i = 0; i < 128; i++)
	push(a0, 0x00);

a0[0] = 0x03;      /* SFP/SFP+ */
a0[1] = 0x04;      /* ext identifier */
a0[2] = 0x07;      /* LC */
a0[11] = 0x03;     /* NRZ */
a0[12] = 103;      /* 10300 Mbps */
a0[14] = 0;        /* SMF 0 km */
a0[15] = 0;
put(a0, 20, ascii_bytes('FS', 16));
put(a0, 37, [ 0x00, 0x1b, 0x21 ]);
put(a0, 40, ascii_bytes('SFP-10G-SR', 16));
put(a0, 56, ascii_bytes('A', 4));
a0[60] = 0x03;     /* 850 nm */
a0[61] = 0x52;
put(a0, 68, ascii_bytes('G2306123456', 16));
put(a0, 84, ascii_bytes('230612', 8));
a0[92] = 0x68;     /* DDM + internally calibrated + average rx power */

/* ---------------- 构造 A2h 页 ---------------- */
let a2 = [];

for (let i = 0; i < 128; i++)
	push(a2, 0x00);

/* 阈值 */
put(a2, 0, [ 0x5a, 0x00 ]);    /* temp high alarm   = 90.00 °C */
put(a2, 2, [ 0xf6, 0x00 ]);    /* temp low alarm    = -10.00 °C */
put(a2, 4, [ 0x55, 0x00 ]);    /* temp high warning = 85.00 °C */
put(a2, 6, [ 0xfb, 0x00 ]);    /* temp low warning  = -5.00 °C */
put(a2, 8, [ 0x8c, 0xa0 ]);    /* vcc high alarm    = 3.6000 V */
put(a2, 10, [ 0x75, 0x30 ]);   /* vcc low alarm     = 3.0000 V */
put(a2, 12, [ 0x88, 0xb8 ]);   /* vcc high warning  = 3.5000 V */
put(a2, 14, [ 0x79, 0x18 ]);   /* vcc low warning   = 3.1000 V */
put(a2, 16, [ 0x17, 0x70 ]);   /* bias high alarm   = 12.000 mA */
put(a2, 18, [ 0x01, 0xf4 ]);   /* bias low alarm    = 1.000 mA */
put(a2, 20, [ 0x15, 0x7c ]);   /* bias high warning = 11.000 mA */
put(a2, 22, [ 0x03, 0xe8 ]);   /* bias low warning  = 2.000 mA */
put(a2, 24, [ 0x3d, 0xe9 ]);   /* txpwr high alarm  = 1.5849 mW */
put(a2, 26, [ 0x03, 0xe8 ]);   /* txpwr low alarm   = 0.1000 mW */
put(a2, 28, [ 0x31, 0x2d ]);   /* txpwr high warn   = 1.2589 mW */
put(a2, 30, [ 0x04, 0xeb ]);   /* txpwr low warn    = 0.1259 mW */
put(a2, 32, [ 0x3d, 0xe9 ]);   /* rxpwr high alarm  = 1.5849 mW */
put(a2, 34, [ 0x00, 0x64 ]);   /* rxpwr low alarm   = 0.0100 mW */
put(a2, 36, [ 0x31, 0x2d ]);   /* rxpwr high warn   = 1.2589 mW */
put(a2, 38, [ 0x00, 0x9e ]);   /* rxpwr low warn    = 0.0158 mW */

/* 实时值 */
put(a2, 96, [ 0x2b, 0x80 ]);   /* 43.5 °C */
put(a2, 98, [ 0x81, 0x00 ]);   /* 3.3024 V */
put(a2, 100, [ 0x0b, 0xe9 ]);  /* 6.098 mA */
put(a2, 102, [ 0x14, 0x03 ]);  /* 0.5123 mW */
put(a2, 104, [ 0x18, 0xa6 ]);  /* 0.6310 mW */

/* ---------------- 测试 ---------------- */
let fails = 0;

function check(label, got, want, tol) {
	let ok;

	if (tol == null) {
		ok = (got == want);
	} else {
		let d = (got == null) ? null : (got - want);

		if (d != null && d < 0)
			d = 0 - d;

		ok = (d != null) && (d <= tol);
	}

	if (!ok) {
		fails++;
		printf('FAIL %-28s got=%s want=%s\n', label, got, want);
	} else {
		printf('ok   %-28s %s\n', label, got);
	}
}

printf('--- parse_raw_page（raw on 原始二进制）---\n');

/* 用 chr() 构造二进制串（含高位字节），应逐字节还原 */
function binstr(bytes) {
	let s = '';

	for (let b in bytes)
		s += chr(b);

	return s;
}

let raw_a0 = ddm.parse_raw_page(binstr(a0), 128);
check('raw a0 length', length(raw_a0), 128);
check('raw a0[0]', raw_a0[0], 0x03);
check('raw a0[0x14]', raw_a0[0x14], 0x46);

/* 高位字节（>= 0x80）必须原样保留 */
let hi = [];

for (let i = 0; i < 128; i++)
	push(hi, (i == 4) ? 0x8c : (i == 5) ? 0xa0 : (i == 96) ? 0xce : 0x00);

let raw_hi = ddm.parse_raw_page(binstr(hi), 128);
check('raw high byte', raw_hi[4], 0x8c);
check('raw high byte 2', raw_hi[5], 0xa0);
check('raw high byte 3', raw_hi[96], 0xce);

let ffp = [];

for (let i = 0; i < 128; i++)
	push(ffp, 0xff);

printf('\n--- parse_raw_page：不该被误判的内容 ---\n');
check('text error', ddm.parse_raw_page('Cannot get module EEPROM information: Operation not supported\n', 128), null);
check('empty', ddm.parse_raw_page('', 128), null);
check('长度不符（多）', ddm.parse_raw_page(binstr(a0) + binstr(a0), 128), null);
check('期望长度不符', ddm.parse_raw_page(binstr(a0), 0), null);
check('全 0xff（无 NUL）', ddm.parse_raw_page(binstr(ffp), 128), null);

printf('\n--- protocol_supported（SFF-8024 Identifier）---\n');
check('0x03 支持', ddm.protocol_supported(0x03), true);
check('0x0d 不支持', ddm.protocol_supported(0x0d), false);
check('0x1e 不支持', ddm.protocol_supported(0x1e), false);

printf('\n--- a2_page_ok / 页校验 ---\n');
check('a2_page_ok(a2)', ddm.a2_page_ok(a2), true);
check('a2_page_ok(a0)', ddm.a2_page_ok(a0), false);
check('a2_page_ok(short)', ddm.a2_page_ok([ 1, 2, 3 ]), false);

let a2zero = [];

for (let i = 0; i < 128; i++)
	push(a2zero, 0x00);

check('a2_page_ok(全 0)', ddm.a2_page_ok(a2zero), false);

printf('\n--- parse_a0 ---\n');
let m = ddm.parse_a0(a0);
check('identifier_name', m.identifier_name, 'SFP/SFP+/SFP28');
check('connector_name', m.connector_name, 'LC');
check('encoding_name', m.encoding_name, 'NRZ');
check('vendor', m.vendor, 'FS');
check('vendor_oui', m.vendor_oui, '00:1b:21');
check('part_number', m.part_number, 'SFP-10G-SR');
check('revision', m.revision, 'A');
check('serial', m.serial, 'G2306123456');
check('date_code', m.date_code, '230612');
check('wavelength_nm', m.wavelength_nm, 850);
check('bitrate_mbps', m.bitrate_mbps, 10300);
check('ddm_implemented', m.ddm_implemented, true);
check('ddm_internally_cal', m.ddm_internally_calibrated, true);
check('rx_power_average', m.rx_power_average, true);

printf('\n--- parse_a2 ---\n');
let d = ddm.parse_a2(a2);
check('temperature_c', d.temperature_c, 43.5, 0.001);
check('voltage_v', d.voltage_v, 3.3024, 0.0001);
check('tx_bias_ma', d.tx_bias_ma, 6.098, 0.001);
check('tx_power_mw', d.tx_power_mw, 0.5123, 0.0001);
check('tx_power_dbm', d.tx_power_dbm, -2.9, 0.001);
check('rx_power_mw', d.rx_power_mw, 0.631, 0.0001);
check('rx_power_dbm', d.rx_power_dbm, -2.0, 0.01);
check('th.temp.high_alarm', d.thresholds.temperature.high_alarm, 90, 0.01);
check('th.temp.low_alarm', d.thresholds.temperature.low_alarm, -10, 0.01);
check('th.temp.high_warning', d.thresholds.temperature.high_warning, 85, 0.01);
check('th.temp.low_warning', d.thresholds.temperature.low_warning, -5, 0.01);
check('th.volt.high_alarm', d.thresholds.voltage.high_alarm, 3.6, 0.0001);
check('th.volt.low_warning', d.thresholds.voltage.low_warning, 3.1, 0.0001);
check('th.bias.high_alarm', d.thresholds.tx_bias.high_alarm, 12, 0.001);
check('th.txpwr.high_alarm', d.thresholds.tx_power.high_alarm, 1.5849, 0.0001);
check('th.txpwr.low_alarm', d.thresholds.tx_power.low_alarm, 0.1, 0.0001);
check('th.rxpwr.low_alarm', d.thresholds.rx_power.low_alarm, 0.01, 0.0001);

printf('\n--- 未编程阈值（全 0 / 0xff）---\n');
let blank = [];

for (let i = 0; i < 128; i++)
	push(blank, 0x00);

/* 阈值区与实时区全 0 => 空页，判定为无效 */
check('parse_a2(blank) => null', ddm.parse_a2(blank), null);

let d3 = ddm.parse_a2(ffp);
check('0xff temp high_alarm', d3.thresholds.temperature.high_alarm, null);
check('0xff vcc high_alarm', d3.thresholds.voltage.high_alarm, null);
check('0xff temp value (round to 0)', d3.temperature_c, 0, 0.0001);

printf('\n--- 空/无效数据 ---\n');
check('parse_a0(0x00 x128)', ddm.parse_a0(blank), null);
check('parse_a0(0xff x128)', ddm.parse_a0(ffp), null);
check('parse_a2(short)', ddm.parse_a2([ 1, 2, 3 ]), null);

printf('\n--- interfaces() ---\n');
let ifs = ddm.interfaces();
printf('detected: %J\n', ifs);

printf('\n--- status() ---\n');
let st = ddm.status();
printf('count=%d ethtool=%s\n', st.count, st.ethtool);
printf('%J\n', st);

printf('\n=====================\n');
if (fails > 0)
	printf('%d test(s) FAILED\n', fails);
else
	printf('ALL TESTS PASSED\n');

exit(fails > 0 ? 1 : 0);
