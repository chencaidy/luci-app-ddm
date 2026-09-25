'use strict';

const ddm = require('ddm');

function show(label, v) {
	printf('%-34s %s\n', label, v);
}

function fail(msg) {
	printf('FAIL: %s\n', msg);
	exit(1);
}

function eq(label, got, want) {
	if (got != want)
		fail(sprintf('%s = %s, expected %s', label, got, want));
}

printf('================ e2e: sfp0 (healthy) ================\n');
let c0 = ddm.collect('sfp0');

if (c0 == null)
	fail('collect(sfp0) returned null');

eq('sfp0 supported', c0.supported, true);
eq('sfp0 source', c0.source, 'eeprom');
eq('sfp0 status', c0.status, 'ok');
eq('sfp0 metrics count', length(c0.metrics), 5);

show('interface', c0.interface);
show('source', c0.source);
show('status', c0.status);
show('meta.vendor', c0.meta.vendor);
show('meta.part_number', c0.meta.part_number);
show('meta.serial', c0.meta.serial);
show('meta.connector_name', c0.meta.connector_name);
show('meta.wavelength_nm', c0.meta.wavelength_nm);
show('meta.bitrate_mbps', c0.meta.bitrate_mbps);
show('ddm.temperature_c', c0.ddm.temperature_c);
show('ddm.voltage_v', c0.ddm.voltage_v);
show('ddm.tx_bias_ma', c0.ddm.tx_bias_ma);
show('ddm.tx_power_mw', c0.ddm.tx_power_mw);
show('ddm.tx_power_dbm', c0.ddm.tx_power_dbm);
show('ddm.rx_power_mw', c0.ddm.rx_power_mw);
show('ddm.rx_power_dbm', c0.ddm.rx_power_dbm);
printf('\nmetrics:\n');

for (let m in c0.metrics)
	printf('  %-12s %-10s %-8s unit=%s dbm=%s\n', m.key, m.value, m.status, m.unit, m.dbm);

printf('\n================ e2e: sfp1 (hot + low rx) ================\n');
let c1 = ddm.collect('sfp1');

if (c1 == null)
	fail('collect(sfp1) returned null');

eq('sfp1 supported', c1.supported, true);
eq('sfp1 status', c1.status, 'alarm');
show('ddm.temperature_c', c1.ddm.temperature_c);
show('ddm.rx_power_mw', c1.ddm.rx_power_mw);
printf('\nmetrics:\n');

for (let m in c1.metrics) {
	printf('  %-12s %-10s %-8s unit=%s\n', m.key, m.value, m.status, m.unit);

	if (m.key == 'temperature')
		eq('sfp1 temperature status', m.status, 'warning');

	if (m.key == 'rx_power')
		eq('sfp1 rx_power status', m.status, 'alarm');
}

printf('\n======== e2e: sfp2 (非 SFF-8472，Identifier=0x0d) ========\n');
let c2 = ddm.collect('sfp2');

if (c2 == null)
	fail('collect(sfp2) returned null（应给出协议不支持的结果）');

eq('sfp2 supported', c2.supported, false);
eq('sfp2 identifier', c2.meta.identifier, 0x0d);
eq('sfp2 identifier_name', c2.meta.identifier_name, 'QSFP+');
eq('sfp2 status', c2.status, 'na');
eq('sfp2 metrics count', length(c2.metrics), 0);
show('meta.identifier_name', c2.meta.identifier_name);
printf('ok: 非 SFF-8472 模块只提示协议不支持，无解析结果\n');

printf('\n======== e2e: sfp3 (驱动忽略 offset，永远只给 A0h) ========\n');
let c3 = ddm.collect('sfp3');

if (c3 == null)
	fail('collect(sfp3) returned null（A0h 是可读的）');

eq('sfp3 supported', c3.supported, true);
eq('sfp3 source', c3.source, 'none');
eq('sfp3 metrics count', length(c3.metrics), 0);
show('interface', c3.interface);
show('meta.vendor', c3.meta.vendor);

if (c3.ddm.temperature_c != null)
	fail('sfp3: A0h 的数据被当成了 A2h（temperature_c 不应有值）');

printf('ok: sfp3 未把 A0h 当成 A2h（无 DDM 指标）\n');

printf('\n======== e2e: sfp4 (EEPROM 完全读不到) ========\n');

if (ddm.collect('sfp4') != null)
	fail('collect(sfp4) 应返回 null（取不到 EEPROM）');

printf('ok: sfp4 返回 null（不属于 SFP 或读不到 EEPROM）\n');

printf('\n======== e2e: sfp5 (raw on 却返回 hexdump 文本) ========\n');

if (ddm.collect('sfp5') != null)
	fail('collect(sfp5) 应返回 null（hexdump 文本不再被解析）');

printf('ok: sfp5 的 hexdump 文本未被解析\n');

printf('\n================ full JSON (sfp0) ================\n');
printf('%J\n', c0);

printf('\n================ done ================\n');
exit(0);
