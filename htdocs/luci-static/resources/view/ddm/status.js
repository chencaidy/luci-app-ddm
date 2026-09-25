'use strict';
'require view';
'require rpc';
'require poll';
'require dom';

var callStatus = rpc.declare({
	object: 'ddm',
	method: 'status',
	expect: {}
});

var POLL_INTERVAL = 5;

var STATE_COLORS = {
	ok: '#2e7d32',
	warning: '#ef6c00',
	alarm: '#c62828',
	na: '#9e9e9e'
};

function stateLabel(s) {
	return (s == 'alarm') ? _('Alarm') :
		(s == 'warning') ? _('Warning') :
		(s == 'ok') ? _('Normal') : _('N/A');
}

function metricLabel(k) {
	return (k == 'temperature') ? _('Temperature') :
		(k == 'voltage') ? _('Supply voltage') :
		(k == 'tx_bias') ? _('TX bias current') :
		(k == 'tx_power') ? _('TX optical power') :
		(k == 'rx_power') ? _('RX optical power') : k;
}

function dash(v) {
	return (v == null || v === '') ? '\u2013' : v;
}

function hex2(v) {
	if (v == null)
		return '';

	var s = Number(v).toString(16);

	return '0x' + ((s.length < 2) ? ('0' + s) : s);
}

function num(v, digits) {
	if (v == null || isNaN(v))
		return '\u2013';

	return Number(v).toFixed((digits == null) ? 2 : digits);
}

/* 每个指标的显示精度 */
var DIGITS = {
	temperature: 2,
	voltage: 3,
	tx_bias: 3,
	tx_power: 4,
	rx_power: 4
};

function fmtValue(m) {
	var u = m.unit || '';
	var d = (DIGITS[m.key] != null) ? DIGITS[m.key] : 2;

	if (m.dbm != null)
		return num(m.value, d) + ' ' + u + '  (' + num(m.dbm, 2) + ' dBm)';

	return num(m.value, d) + ' ' + u;
}

function stateBadge(s) {
	return E('span', {
		'class': 'ddm-badge ddm-badge-' + s,
		'style': 'background:' + (STATE_COLORS[s] || STATE_COLORS.na)
	}, [ stateLabel(s) ]);
}

/* ---------------- 阈值可视化 ---------------- */

function thresholdBar(m) {
	var t = m.thresholds || {};
	var la = t.low_alarm, lw = t.low_warning, hw = t.high_warning, ha = t.high_alarm;
	var lo = null, hi = null;

	if (la != null && ha != null) { lo = la; hi = ha; }
	else if (la != null && hw != null) { lo = la; hi = hw; }
	else if (lw != null && ha != null) { lo = lw; hi = ha; }
	else if (lw != null && hw != null) { lo = lw; hi = hw; }

	if (lo == null || hi == null || !(hi > lo))
		return E('div', { 'class': 'ddm-track ddm-track-plain' });

	function pct(v) {
		return Math.min(100, Math.max(0, (v - lo) / (hi - lo) * 100));
	}

	var safeLo = (lw != null) ? pct(lw) : null;
	var safeHi = (hw != null) ? pct(hw) : null;
	var pin = pct(m.value);

	var safe = E('div', { 'class': 'ddm-safe' });

	if (safeLo != null && safeHi != null && safeHi > safeLo) {
		safe.style.left = safeLo + '%';
		safe.style.width = (safeHi - safeLo) + '%';
	}
	else {
		safe.style.left = '0%';
		safe.style.width = '100%';
	}

	return E('div', {
		'class': 'ddm-track',
		'title': _('Lower alarm') + ': ' + num(t.low_alarm, 2) +
			'  ' + _('Lower warning') + ': ' + num(t.low_warning, 2) +
			'  ' + _('Upper warning') + ': ' + num(t.high_warning, 2) +
			'  ' + _('Upper alarm') + ': ' + num(t.high_alarm, 2)
	}, [
		safe,
		E('div', { 'class': 'ddm-pin ddm-pin-' + m.status, 'style': 'left:' + pin + '%' })
	]);
}

function limitText(m) {
	var t = m.thresholds || {};

	if (t.low_alarm == null && t.high_alarm == null)
		return '\u2013';

	return num(t.low_alarm, 2) + ' \u2013 ' + num(t.high_alarm, 2) + ' ' + (m.unit || '');
}

/* ---------------- 卡片渲染 ---------------- */

function metricsTable(itf) {
	var rows = [];

	for (var i = 0; i < (itf.metrics || []).length; i++) {
		var m = itf.metrics[i];

		rows.push(E('tr', { 'class': 'ddm-row ddm-row-' + m.status }, [
			E('td', { 'class': 'ddm-col-name' }, [ metricLabel(m.key) ]),
			E('td', { 'class': 'ddm-col-value' }, [ fmtValue(m) ]),
			E('td', { 'class': 'ddm-col-limit' }, [ limitText(m) ]),
			E('td', { 'class': 'ddm-col-bar' }, [ thresholdBar(m) ]),
			E('td', { 'class': 'ddm-col-state' }, [ stateBadge(m.status) ])
		]));
	}

	if (rows.length === 0)
		rows.push(E('tr', {}, [
			E('td', { 'colspan': 5, 'class': 'ddm-empty-cell' },
				[ _('This transceiver does not report digital diagnostic data.') ])
		]));

	return E('table', { 'class': 'ddm-table' }, [
		E('thead', {}, [
			E('tr', {}, [
				E('th', {}, [ _('Parameter') ]),
				E('th', {}, [ _('Current value') ]),
				E('th', {}, [ _('Alarm limits') ]),
				E('th', { 'class': 'ddm-col-bar' }, [ _('Range') ]),
				E('th', {}, [ _('Status') ])
			])
		]),
		E('tbody', {}, rows)
	]);
}

function metaGrid(itf) {
	var m = itf.meta || {};

	var items = [
		[ _('Vendor'), dash(m.vendor) ],
		[ _('Part number'), dash(m.part_number) ],
		[ _('Serial number'), dash(m.serial) ],
		[ _('Revision'), dash(m.revision) ],
		[ _('Date code'), dash(m.date_code) ],
		[ _('Connector'), dash(m.connector_name) ],
		[ _('Encoding'), dash(m.encoding_name) ],
		[ _('Bit rate'), (m.bitrate_mbps != null) ? m.bitrate_mbps + ' Mbps' : '\u2013' ],
		[ _('Wavelength'), (m.wavelength_nm != null && m.wavelength_nm > 0) ? m.wavelength_nm + ' nm' : '\u2013' ],
		[ _('Vendor OUI'), dash(m.vendor_oui) ]
	];

	var cells = [];

	for (var i = 0; i < items.length; i++)
		cells.push(E('div', { 'class': 'ddm-meta-item' }, [
			E('span', { 'class': 'ddm-meta-label' }, [ items[i][0] ]),
			E('span', { 'class': 'ddm-meta-value' }, [ String(items[i][1]) ])
		]));

	return E('div', { 'class': 'ddm-meta' }, cells);
}

/*
 * 非 SFF-8472 模块：不解析数据，只给出协议不支持的提示。
 * 类型名来自 SFF-8024，ddm 后端通过 meta.identifier_name / identifier 给出。
 */
function unsupportedNotice(itf) {
	var m = itf.meta || {};

	return E('div', { 'class': 'ddm-msg', 'style': 'margin:0' }, [
		_('Unsupported transceiver type: %s (%s). Only SFF-8472 (SFP/SFP+/SFP28) modules are supported.')
			.format(dash(m.identifier_name), hex2(m.identifier))
	]);
}

function sourceLabel(s) {
	return (s == 'eeprom') ? _('EEPROM (A2h)') : _('unavailable');
}

function interfaceCard(itf) {
	var children = [
		E('div', { 'class': 'ddm-card-head' }, [
			E('div', { 'class': 'ddm-card-title' }, [
				E('span', { 'class': 'ddm-iface' }, [ itf.interface ]),
				E('span', { 'class': 'ddm-type' }, [ dash((itf.meta || {}).identifier_name) ])
			]),
			E('div', { 'class': 'ddm-card-state' }, [
				E('span', { 'class': 'ddm-src' }, [ sourceLabel(itf.source) ]),
				stateBadge(itf.status)
			])
		])
	];

	if (itf.supported === false)
		children.push(E('div', { 'class': 'ddm-card-body' }, [ unsupportedNotice(itf) ]));
	else {
		children.push(metaGrid(itf));
		children.push(metricsTable(itf));
	}

	return E('div', { 'class': 'ddm-card ddm-card-' + itf.status }, children);
}

/* ---------------- 样式 ---------------- */

var CSS = [
	'.ddm-root{--ddm-card-bg:#fff;--ddm-border:#e0e0e0;--ddm-fg:#212121;--ddm-sub:#757575;--ddm-track:#eceff1;}',
	'@media (prefers-color-scheme:dark){.ddm-root{--ddm-card-bg:#1c1c1c;--ddm-border:#333;--ddm-fg:#e0e0e0;--ddm-sub:#9e9e9e;--ddm-track:#333;}}',
	'html[data-darkmode="true"] .ddm-root{--ddm-card-bg:#1c1c1c;--ddm-border:#333;--ddm-fg:#e0e0e0;--ddm-sub:#9e9e9e;--ddm-track:#333;}',
	'.ddm-root{color:var(--ddm-fg);}',
	'.ddm-header{margin-bottom:16px;}',
	'.ddm-toolbar{display:flex;align-items:center;gap:12px;flex-wrap:wrap;margin-bottom:16px;}',
	'.ddm-stamp{color:var(--ddm-sub);font-size:90%;}',
	'.ddm-msg{padding:12px 16px;border-radius:8px;background:#fff8e1;border:1px solid #ffe082;color:#795548;margin-bottom:16px;}',
	'.ddm-card-body{padding:12px 16px;}',
	'.ddm-card{background:var(--ddm-card-bg);border:1px solid var(--ddm-border);border-radius:10px;margin-bottom:18px;overflow:hidden;box-shadow:0 1px 3px rgba(0,0,0,.08);}',
	'.ddm-card-alarm{border-left:5px solid #c62828;}',
	'.ddm-card-warning{border-left:5px solid #ef6c00;}',
	'.ddm-card-ok{border-left:5px solid #2e7d32;}',
	'.ddm-card-head{display:flex;justify-content:space-between;align-items:center;flex-wrap:wrap;gap:8px;padding:12px 16px;border-bottom:1px solid var(--ddm-border);}',
	'.ddm-card-title{display:flex;align-items:center;gap:10px;}',
	'.ddm-iface{font-size:120%;font-weight:600;font-family:monospace;}',
	'.ddm-type{color:var(--ddm-sub);font-size:90%;}',
	'.ddm-card-state{display:flex;align-items:center;gap:10px;}',
	'.ddm-src{color:var(--ddm-sub);font-size:80%;}',
	'.ddm-badge{color:#fff;border-radius:10px;padding:2px 10px;font-size:80%;font-weight:600;letter-spacing:.3px;}',
	'.ddm-meta{display:grid;grid-template-columns:repeat(auto-fill,minmax(180px,1fr));gap:6px 18px;padding:12px 16px;border-bottom:1px solid var(--ddm-border);}',
	'.ddm-meta-item{display:flex;justify-content:space-between;gap:8px;font-size:90%;}',
	'.ddm-meta-label{color:var(--ddm-sub);}',
	'.ddm-meta-value{font-family:monospace;text-align:right;word-break:break-all;}',
	'.ddm-table{width:100%;border-collapse:collapse;font-size:92%;}',
	'.ddm-table th{text-align:left;padding:8px 14px;color:var(--ddm-sub);font-weight:600;border-bottom:1px solid var(--ddm-border);white-space:nowrap;}',
	'.ddm-table td{padding:8px 14px;border-bottom:1px solid var(--ddm-border);vertical-align:middle;}',
	'.ddm-table tr:last-child td{border-bottom:none;}',
	'.ddm-row-alarm{background:rgba(198,40,40,.07);}',
	'.ddm-row-warning{background:rgba(239,108,0,.07);}',
	'.ddm-col-value{font-family:monospace;white-space:nowrap;}',
	'.ddm-col-limit{font-family:monospace;color:var(--ddm-sub);white-space:nowrap;}',
	'.ddm-col-bar{width:32%;min-width:120px;}',
	'.ddm-col-state{text-align:right;white-space:nowrap;}',
	'.ddm-empty-cell{color:var(--ddm-sub);font-style:italic;text-align:center;padding:18px;}',
	'.ddm-track{position:relative;height:10px;background:var(--ddm-track);border-radius:5px;overflow:visible;}',
	'.ddm-track-plain{opacity:.4;}',
	'.ddm-safe{position:absolute;top:0;height:100%;background:rgba(46,125,50,.35);border-radius:5px;}',
	'.ddm-pin{position:absolute;top:-3px;width:4px;height:16px;border-radius:2px;transform:translateX(-2px);background:#555;}',
	'.ddm-pin-ok{background:#2e7d32;}',
	'.ddm-pin-warning{background:#ef6c00;}',
	'.ddm-pin-alarm{background:#c62828;}',
	'.ddm-pin-na{background:#9e9e9e;}'
].join('\n');

function injectStyle() {
	if (document.getElementById('ddm-style'))
		return;

	document.head.appendChild(E('style', { 'id': 'ddm-style' }, [ CSS ]));
}

/* ---------------- 视图 ---------------- */

return view.extend({
	load: function() {
		return callStatus();
	},

	render: function(data) {
		var body = E('div');
		var stamp = E('span', { 'class': 'ddm-stamp' }, [ _('loading...') ]);

		injectStyle();

		function update(res) {
			res = res || {};
			var children = [];

			if (res.ethtool === false)
				children.push(E('div', { 'class': 'ddm-msg' }, [
					_('The ethtool utility was not found. Transceiver data cannot be read.')
				]));

			if (!res.interfaces || res.interfaces.length === 0) {
				children.push(E('div', { 'class': 'ddm-msg' }, [
					_('No SFP transceiver with digital diagnostic monitoring was detected.')
				]));
			}
			else {
				for (var i = 0; i < res.interfaces.length; i++)
					children.push(interfaceCard(res.interfaces[i]));
			}

			dom.content(body, children);

			stamp.textContent = _('Updated at %s').format(new Date().toLocaleTimeString());
		}

		update(data || {});

		poll.add(function() {
			return callStatus().then(update);
		}, POLL_INTERVAL);

		return E('div', { 'class': 'ddm-root' }, [
			E('div', { 'class': 'ddm-header' }, [
				E('h2', [ _('SFP Diagnostics') ]),
				E('p', [
					_('Shows the digital diagnostic monitoring (DDM) data of the SFP/SFP+ transceivers installed in this device, as defined by SFF-8472. Each interface reports its identity, real-time measurements and alarm thresholds.')
				])
			]),
			E('div', { 'class': 'ddm-toolbar' }, [
				E('button', {
					'class': 'btn cbi-button cbi-button-action',
					'click': function() { callStatus().then(update); }
				}, [ _('Refresh') ]),
				E('span', { 'class': 'ddm-stamp' }, [ _('auto refresh every %d s').format(POLL_INTERVAL) ]),
				stamp
			]),
			body
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
