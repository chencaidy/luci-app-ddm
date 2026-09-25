#!/usr/bin/ucode
/*
 * SPDX-License-Identifier: Apache-2.0
 *
 * ddm CLI - SFP DDM command line utility
 *
 * 由 /usr/bin/ddm（shell 包装）通过
 *     ucode -L /usr/libexec/ddm /usr/libexec/ddm/cli.uc ...
 * 启动，因此可以 require('ddm') 使用同目录下的核心模块。
 *
 * 用法:
 *   ddm status [--json]          以 JSON 输出所有 SFP 接口的完整信息
 *   ddm text                     以人类可读形式输出
 *   ddm list                     仅列出检测到的 SFP 接口名
 *   ddm info <iface>             输出单个接口的 JSON
 *   ddm check [--quiet]          检查告警/警告，有问题时返回码为 1
 *   ddm raw <iface> [a0|a2]      打印 EEPROM 原始 hexdump（调试用）
 *
 * 取数只用 `ethtool -m <iface> raw on offset 0xN length 128`，
 * 且只解析 SFF-8472（SFP/SFP+/SFP28）；其他类型提示协议不支持。
 */

'use strict';

const ddm = require('ddm');

const UNITS = {
	temperature: '\u00b0C',
	voltage: 'V',
	tx_bias: 'mA',
	tx_power: 'mW',
	rx_power: 'mW'
};

const LABELS = {
	temperature: 'Temperature',
	voltage: 'Supply voltage',
	tx_bias: 'TX bias current',
	tx_power: 'TX optical power',
	rx_power: 'RX optical power'
};

function usage() {
	printf('Usage: ddm <command> [options]\n\n');
	printf('Commands:\n');
	printf('  status [--json]         Show all SFP DDM data (JSON)\n');
	printf('  text                    Show all SFP DDM data in a human readable form\n');
	printf('  list                    List detected SFP capable interfaces\n');
	printf('  info <iface>            Show DDM data of a single interface as JSON\n');
	printf('  check [--quiet]         Exit 1 when a metric is in warning/alarm state\n');
	printf('  raw <iface> [a0|a2]     Dump raw EEPROM page (debug)\n');
	printf('\n');
	printf('Only SFF-8472 (SFP/SFP+/SFP28) modules are supported; other types\n');
	printf('are reported as unsupported (identified per SFF-8024).\n');
	printf('\n');
}

function opt_present(flag) {
	for (let a in ARGV)
		if (a == flag)
			return true;

	return false;
}

function positional() {
	let out = [];

	for (let a in ARGV) {
		if (type(a) != 'string' || length(a) == 0)
			continue;

		if (substr(a, 0, 1) == '-')
			continue;

		push(out, a);
	}

	return out;
}

function fmt_dbm(v) {
	return (v == null) ? 'n/a' : sprintf('%.2f dBm', v);
}

function fmt_val(v, unit) {
	if (v == null)
		return 'n/a';

	if (unit == 'mW')
		return sprintf('%.4f %s', v, unit);

	if (unit == '\u00b0C' || unit == 'V' || unit == 'mA')
		return sprintf('%.2f %s', v, unit);

	return sprintf('%s %s', v, unit);
}

function status_badge(s) {
	return (s == 'alarm') ? '[ALARM]' : (s == 'warning') ? '[WARN ]' : (s == 'ok') ? '[ ok  ]' : '[ n/a ]';
}

function print_text(res) {
	printf('SFP DDM report - %d interface(s), ethtool: %s\n', res.count, res.ethtool ? 'yes' : 'no');

	for (let itf in res.interfaces) {
		let m = itf.meta;
		let d = itf.ddm;

		printf('\n%s  %s  [%s]  source=%s\n', itf.interface, m.identifier_name, itf.status, itf.source);

		if (itf.supported === false) {
			printf('  Unsupported protocol: not an SFF-8472 (SFP/SFP+/SFP28) module, DDM data is not available.\n');
			continue;
		}

		printf('  Vendor      : %s\n', m.vendor);
		printf('  Part number : %s\n', m.part_number);
		printf('  Serial      : %s\n', m.serial);
		printf('  Revision    : %s\n', m.revision);
		printf('  Date code   : %s\n', m.date_code);
		printf('  Connector   : %s\n', m.connector_name);
		printf('  Encoding    : %s\n', m.encoding_name);
		printf('  Bit rate    : %s Mbps\n', m.bitrate_mbps);
		printf('  Wavelength  : %s nm\n', m.wavelength_nm);

		for (let mt in itf.metrics) {
			let extra = '';

			if (mt.key == 'tx_power') extra = ' / ' + fmt_dbm(d.tx_power_dbm);
			if (mt.key == 'rx_power') extra = ' / ' + fmt_dbm(d.rx_power_dbm);

			printf('  %-14s: %-24s %s\n', LABELS[mt.key],
				fmt_val(mt.value, mt.unit) + extra, status_badge(mt.status));
		}
	}

	if (res.count == 0)
		printf('\nNo SFP transceiver with DDM data was detected.\n');
}

function cmd_check(quiet) {
	let a = ddm.alerts();
	let lines = [];

	for (let e in a) {
		let th = e.thresholds;
		let limit = null;

		if (e.status == 'alarm')
			limit = (th.high_alarm != null && e.value >= th.high_alarm) ? th.high_alarm : th.low_alarm;
		else
			limit = (th.high_warning != null && e.value >= th.high_warning) ? th.high_warning : th.low_warning;

		push(lines, sprintf('%s: %s is %s (%s %s, limit %s)',
			e.interface, e.metric, e.status, e.value, UNITS[e.metric],
			(limit != null) ? limit : 'n/a'));
	}

	if (!quiet)
		for (let l in lines)
			printf('%s\n', l);

	return (length(lines) > 0) ? 1 : 0;
}

let plain = positional();
let cmd = (length(plain) > 0) ? plain[0] : 'status';

if (cmd == 'help' || opt_present('-h') || opt_present('--help')) {
	usage();
	exit(0);
}

if (cmd == 'list') {
	for (let n in ddm.interfaces())
		printf('%s\n', n);

	exit(0);
}

if (cmd == 'info') {
	if (length(plain) < 2) {
		printf('error: info requires an interface name\n');
		exit(2);
	}

	let c = ddm.collect(plain[1]);

	if (c == null) {
		printf('error: %s is not an SFP interface or has no EEPROM data\n', plain[1]);
		exit(3);
	}

	printf('%J\n', c);
	exit(0);
}

if (cmd == 'raw') {
	if (length(plain) < 2) {
		printf('error: raw requires an interface name\n');
		exit(2);
	}

	if (!ddm.is_iface_name(plain[1])) {
		printf('error: invalid interface name\n');
		exit(2);
	}

	let page = (length(plain) > 2 && lc(plain[2]) == 'a2') ? 0xa2 : 0xa0;
	let b = ddm.read_page(plain[1], page);

	if (length(b) == 0) {
		printf('error: no EEPROM data for %s (try: ddm raw %s a0)\n', plain[1], plain[1]);
		exit(3);
	}

	for (let i = 0; i < length(b); i += 16) {
		let hexs = '', asc = '';

		for (let j = i; j < i + 16 && j < length(b); j++) {
			hexs += sprintf('%02x ', b[j]);
			asc += (b[j] >= 0x20 && b[j] <= 0x7e) ? chr(b[j]) : '.';
		}

		printf('%04x: %-48s %s\n', i, hexs, asc);
	}

	exit(0);
}

if (cmd == 'check') {
	exit(cmd_check(opt_present('--quiet') || opt_present('-q')));
}

/* status / text / json */
let res = ddm.status();

if (cmd == 'text' || opt_present('--text') || opt_present('-t'))
	print_text(res);
else
	printf('%J\n', res);

exit(0);
