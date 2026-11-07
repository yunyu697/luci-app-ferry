'use strict';
'require view';
'require rpc';
'require ui';

var callStatus = rpc.declare({ object: 'luci-ferry-panel', method: 'status', expect: {} });
var callEnable = rpc.declare({ object: 'luci-ferry-panel', method: 'enable', expect: {} });
var callDisable = rpc.declare({ object: 'luci-ferry-panel', method: 'disable', expect: {} });
var callRotate = rpc.declare({ object: 'luci-ferry-panel', method: 'rotate', expect: {} });

function notify(msg, type) {
	if (typeof ui.addNotification === 'function')
		ui.addNotification(null, E('p', {}, msg), type || 'info');
	else
		window.alert(msg);
}

function panelUrl(s) {
	if (!s || !s.bind) return '';
	return s.panel_base + '?hostname=' + encodeURIComponent(s.bind) +
		'&port=' + encodeURIComponent(String(s.port || 9090)) +
		'&secret=' + encodeURIComponent(s.secret || '') +
		'&type=clash' +
		'&kernel=' + (s.kernel === 'singbox' ? 'singbox' : 'mihomo') +
		'&label=' + encodeURIComponent('Ferry') +
		'&disableUpgradeCore=1&disableTunMode=1';
}

function capLabel(v) {
	if (v === 'available') return '可用';
	if (v === 'readonly') return '只读';
	return '不可用';
}

function capClass(v) {
	if (v === 'available') return 'label label-success';
	if (v === 'readonly') return 'label label-warning';
	return 'label label-danger';
}

return view.extend({
	load: function() {
		return callStatus().catch(function() { return { ok: false }; });
	},

	render: function(status) {
		var self = this;
		var root = E('div', { class: 'cbi-section' });
		var body = E('div', {});
		var iframeBox = E('div', {});
		var timer = null;
		var polling = 0;

		function btn(label, cls, fn, disabled) {
			return E('button', {
				class: 'cbi-button ' + (cls || ''),
				disabled: disabled ? 'disabled' : null,
				click: function(ev) {
					ev.preventDefault();
					if (!disabled) fn();
				}
			}, label);
		}

		function refresh() {
			return callStatus().then(function(s) {
				status = s || {};
				renderBody();
				schedulePoll();
			}).catch(function(e) {
				notify('状态读取失败：' + (e.message || e), 'error');
			});
		}

		function schedulePoll() {
			if (timer) { window.clearInterval(timer); timer = null; }
			if (!status || !status.applying) { polling = 0; return; }
			polling = 0;
			timer = window.setInterval(function() {
				polling++;
				if (polling > 60 || !document.body.contains(root)) {
					window.clearInterval(timer);
					timer = null;
					return;
				}
				refresh();
			}, 3000);
		}

		function action(fn, okMsg) {
			fn().then(function(r) {
				if (r && r.ok === false) {
					notify('操作失败：' + (r.error || '未知错误'), 'error');
					return;
				}
				notify(okMsg);
				return refresh();
			}).catch(function(e) {
				notify('操作失败：' + (e.message || e), 'error');
			});
		}

		function openPanel(target) {
			var url = panelUrl(status);
			if (!url) { notify('还没有可用的监听地址', 'error'); return; }
			if (target === 'self') window.open(url, '_blank', 'noopener');
			else {
				while (iframeBox.firstChild) iframeBox.removeChild(iframeBox.firstChild);
				iframeBox.appendChild(E('iframe', {
					src: url,
					style: 'width:100%;height:72vh;border:1px solid var(--border-color,#ddd);border-radius:8px;background:#fff;'
				}));
			}
		}

		function copyUrl() {
			var url = panelUrl(status);
			if (!url) return;
			if (navigator.clipboard && navigator.clipboard.writeText) {
				navigator.clipboard.writeText(url).then(function() {
					notify('已复制面板地址（含 secret，请勿外传）');
				}).catch(function() { window.prompt('复制面板地址', url); });
			} else {
				window.prompt('复制面板地址', url);
			}
		}

		function warnings(s) {
			var list = [];
			if (s.reason === 'disabled') list.push('面板未启用。启用后会生成 secret、注入内核配置，并重启一次内核。');
			if (s.reason === 'no_secret') list.push('secret 文件缺失或格式不合法：面板不会注入。点「启用」会重新生成。');
			if (s.reason === 'no_bind') list.push('找不到 LAN 接口的 IPv4 地址：无法绑定，面板不会注入。');
			if (s.reason === 'self_config') list.push('当前是自备配置（config_path）：ferry 不会修改它，需要你自己在配置里加入面板监听与 secret。');
			if (s.reason === 'sub_config') list.push('sing-box 正在使用订阅配置（原样运行）：订阅内容没有 clash_api，面板连不上。请改用节点导入模式，或手工在订阅里加 experimental.clash_api。');
			if (s.reason === 'not_injected') list.push('配置里没有面板端点：可能内核还没重启，或生成失败。点「应用」或重新启用。');
			if (s.conflict && s.conflict.both) list.push('mihomo 与 sing-box 同时在运行：同一端口会 EADDRINUSE。请先停掉不用的内核。');
			if (s.enabled && !s.service_enabled) list.push('ferry 主服务未启用（ferry.main.enabled=0）：面板设置已保存，但内核不会启动。');
			if (s.applying) list.push('正在重启内核以应用面板设置（约 5–30 秒）…');
			if (!s.bind && s.enabled) list.push('监听地址为空：无法生成面板地址。');
			return list;
		}

		function renderBody() {
			while (body.firstChild) body.removeChild(body.firstChild);
			if (!status || status.ok === false) {
				body.appendChild(E('p', {}, '面板后端不可用（luci-ferry-panel 未注册或 rpcd 未重载）。'));
				return;
			}

			var s = status;
			var caps = s.caps || {};

			var st = E('div', { class: 'cbi-section-node' }, [
				E('h3', {}, '状态'),
				E('table', { class: 'table' }, [
					E('tr', { class: 'tr' }, [ E('td', { class: 'td', width: '30%' }, '面板'), E('td', { class: 'td' }, s.enabled ? '已启用' : '未启用') ]),
					E('tr', { class: 'tr' }, [ E('td', { class: 'td' }, '内核'), E('td', { class: 'td' }, (s.kernel === 'singbox' ? 'sing-box' : 'mihomo') + ' · ' + (s.type === 'singbox' ? 'sing-box 兼容模式' : 'Clash API')) ]),
					E('tr', { class: 'tr' }, [ E('td', { class: 'td' }, '监听地址'), E('td', { class: 'td' }, s.bind ? (s.bind + ':' + s.port + '（仅 LAN）') : '未确定') ]),
					E('tr', { class: 'tr' }, [ E('td', { class: 'td' }, '端点注入'), E('td', { class: 'td' }, s.injected ? '已注入' : '未注入（' + (s.reason || '') + '）') ]),
					E('tr', { class: 'tr' }, [ E('td', { class: 'td' }, '密钥'), E('td', { class: 'td' }, s.secret ? '已生成（0600，仅注入内核配置）' : '无') ]),
					E('tr', { class: 'tr' }, [ E('td', { class: 'td' }, '进程'), E('td', { class: 'td' }, (s.running ? '运行中' : '未运行') +
						(s.conflict && s.conflict.both ? '；检测到两个内核同时在运行' : '')) ])
				])
			]);

			var wl = warnings(s);
			var warnBox = null;
			if (wl.length) {
				warnBox = E('div', { class: 'cbi-section', style: 'padding:8px 12px;border-left:4px solid #f0ad4e;background:rgba(240,173,78,.08);' },
					wl.map(function(w) { return E('p', { style: 'margin:4px 0' }, w); }));
			}

			var actions = E('div', { class: 'cbi-section', style: 'display:flex;flex-wrap:wrap;gap:8px;align-items:center;' }, [
				s.enabled
					? btn('禁用面板', 'cbi-button-reset', function() { action(callDisable, '已禁用面板，正在重启内核移除端点'); })
					: btn('启用面板', 'cbi-button-apply', function() { action(callEnable, '已启用面板，正在重启内核注入端点'); }),
				btn('打开面板', 'cbi-button-action', function() { openPanel('self'); }, !s.enabled || !s.bind || !s.secret),
				btn('页内打开', 'cbi-button', function() { openPanel('frame'); }, !s.enabled || !s.bind || !s.secret),
				btn('复制地址', 'cbi-button', copyUrl, !s.enabled || !s.bind || !s.secret),
				btn('轮换密钥', 'cbi-button', function() {
					if (!window.confirm('轮换后旧 secret 立即失效，需要重新打开面板。继续？')) return;
					action(callRotate, '密钥已轮换，正在重启内核');
				}, !s.enabled)
			]);

			var capRows = [
				['规则页', caps.rules, 'sing-box 不提供 /rules；mihomo 可查看'],
				['配置页', caps.config, '只读查看；写入由 ferry 负责'],
				['延迟明细', caps.delay_detail, 'sing-box 的延迟探测返回通用错误'],
				['重启 / 升级内核', caps.restart, '由 ferry 的内核页管理'],
				['切换节点', caps.proxy_switch, '只允许 PUT /proxies/{group}']
			];
			var capTable = E('table', { class: 'table' }, [
				E('tr', { class: 'tr' }, [ E('th', {}, '功能'), E('th', {}, '当前内核'), E('th', {}, '说明') ])
			].concat(capRows.map(function(r) {
				// restart 与 upgrade 分开显示时取较差者
				var v = (r[0] === '重启 / 升级内核' && caps.restart !== 'unavailable') ? caps.upgrade : r[1];
				return E('tr', { class: 'tr' }, [
					E('td', { class: 'td' }, r[0]),
					E('td', { class: 'td' }, E('span', { class: capClass(v) }, capLabel(v))),
					E('td', { class: 'td' }, r[2])
				]);
			})));
			var capBox = E('div', { class: 'cbi-section' }, [
				E('h3', {}, '能力探测（当前内核）'),
				capTable,
				E('p', { class: 'cbi-section-descr' }, caps.note || '面板为只读模式：只允许切换节点，配置写入/重载/重启/升级已禁用。')
			]);

			var hint = E('div', { class: 'cbi-section' }, [
				E('p', { class: 'cbi-section-descr' }, '安全约束：监听地址固定为 LAN 接口的 IPv4 地址（不是 0.0.0.0）；secret 由面板包随机生成并存于 0600 文件；防火墙只放行 LAN 接口与 LAN 网段，其余来源对该端口明确 drop；同一时刻只允许一个内核占用该端口。'),
				E('p', { class: 'cbi-section-descr' }, '卸载本面板包会删除 secret、撤销防火墙规则、删除本包的 UCI 配置，并重启内核把 external-controller / experimental.clash_api 从生成配置里移除（端口释放）。')
			]);

			body.appendChild(st);
			if (warnBox) body.appendChild(warnBox);
			body.appendChild(actions);
			body.appendChild(capBox);
			body.appendChild(hint);
			body.appendChild(iframeBox);
		}

		renderBody();
		schedulePoll();

		root.appendChild(E('h2', {}, 'Ferry 面板（Dashboard）'));
		root.appendChild(E('p', { class: 'cbi-section-descr' }, '独立可选包：内嵌 zashboard 3.22.0（只读补丁，版本锁死）。zashboard 3.23.0 起移除 sing-box 支持，禁止跟随升级。'));
		root.appendChild(body);
		return root;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
