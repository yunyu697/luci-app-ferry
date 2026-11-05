'use strict';
'require view';
'require ui';
'require ferry.store as store';
'require ferry.links as links';

var TYPES = [
	[ 'vmess', 'VMess' ], [ 'vless', 'VLESS' ], [ 'ss', 'Shadowsocks' ],
	[ 'ssr', 'ShadowsocksR' ], [ 'trojan', 'Trojan' ],
	[ 'hysteria2', 'Hysteria2' ], [ 'tuic', 'TUIC' ]
];

var NODE_FIELDS = {
	vmess: [ 'uuid', 'alterId', 'scy', 'network', 'path', 'host', 'serviceName', 'tls', 'sni', 'alpn', 'fingerprint', 'insecure' ],
	vless: [ 'uuid', 'flow', 'network', 'path', 'host', 'serviceName', 'tls', 'sni', 'publicKey', 'shortId', 'fingerprint', 'alpn', 'insecure' ],
	ss: [ 'cipher', 'password', 'plugin', 'pluginOpts' ],
	ssr: [ 'cipher', 'password', 'ssrProtocol', 'ssrObfs', 'ssrProtocolParam', 'ssrObfsParam' ],
	trojan: [ 'password', 'network', 'path', 'host', 'serviceName', 'sni', 'alpn', 'fingerprint', 'insecure' ],
	hysteria2: [ 'password', 'sni', 'hyObfs', 'hyObfsPassword', 'alpn', 'insecure' ],
	tuic: [ 'uuid', 'password', 'sni', 'alpn', 'tuicCC', 'tuicUdpMode', 'insecure' ]
};

var LABELS = {
	name: '名称', server: '服务器', port: '端口', uuid: 'UUID', password: '密码',
	cipher: '加密方式', alterId: 'alterId', scy: 'VMess 加密(auto/none/zero)',
	flow: 'flow(如 xtls-rprx-vision)', network: '传输(tcp/ws/grpc)',
	path: 'ws path', host: 'ws Host', serviceName: 'grpc serviceName',
	tls: '启用 TLS', sni: 'SNI', alpn: 'ALPN（逗号分隔）', fingerprint: 'uTLS 指纹',
	publicKey: 'Reality public key', shortId: 'Reality short id', insecure: '跳过证书校验',
	plugin: 'SS 插件(obfs-local/v2ray-plugin)', pluginOpts: '插件参数(原始 SIP003 串)',
	ssrProtocol: 'SSR protocol', ssrObfs: 'SSR obfs',
	ssrProtocolParam: 'protocol-param', ssrObfsParam: 'obfs-param',
	hyObfs: 'Hysteria2 obfs(salamander)', hyObfsPassword: 'obfs 密码',
	tuicCC: 'TUIC congestion_control', tuicUdpMode: 'TUIC udp_relay_mode'
};

function mkInput(key, value) {
	var v = value == null ? '' : value;
	if (key === 'tls' || key === 'insecure') {
		var cb = E('input', { type: 'checkbox', class: 'cbi-checkbox-input' });
		cb.checked = !!value;
		return cb;
	}
	return E('input', {
		type: 'text', class: 'cbi-input-text', value: v,
		placeholder: key === 'server' ? 'example.com' : ''
	});
}

function notify(msg) {
	if (typeof ui.addNotification === 'function')
		ui.addNotification(null, E('p', {}, msg), 'info');
}

function fail(msg) {
	if (typeof ui.addNotification === 'function')
		ui.addNotification(null, E('p', {}, msg), 'error');
	else
		window.alert(msg);
}

// 较新的 LuCI 提供 ui.showModal；老版本没有该 API 时退化为内联区块，
// 避免编辑节点时整页报错（保存/取消按钮仍可用）。
function openModal(title, content, buttons) {
	if (typeof ui.showModal === 'function')
		return ui.showModal(title, content, buttons);

	var box = E('div', { class: 'cbi-section' }, [
		E('h3', {}, title),
		content,
		E('div', { class: 'cbi-button-row' }, (buttons || []).map(function(b) {
			return E('button', {
				class: 'cbi-button ' + (b.class || ''),
				click: function() {
					if (b.callback && b.callback() === false)
						return;
					if (box.parentNode)
						box.parentNode.removeChild(box);
				}
			}, b.label);
		}))
	]);
	var host = document.querySelector('.main-content') || document.body;
	host.appendChild(box);
}

return view.extend({
	load: function() {
		return Promise.all([
			store.loadNodes(),
			store.activeProfile().catch(function() { return { profile: null }; }),
			store.status()
		]);
	},

	render: function(data) {
		var self = this;
		this.nodes = data[0] || [];
		this.profile = (data[1] && data[1].profile) || null;
		this.status = data[2] || null;

		var table = E('div', {}, []);
		this.table = table;

		var importBox = E('textarea', {
			class: 'cbi-input-textarea',
			rows: 5,
			placeholder: '粘贴分享链接，一行一个：vmess:// vless:// ss:// ssr:// trojan:// hysteria2:// tuic://',
			style: 'width:100%'
		});

		function refresh() {
			var rows = [];
			self.nodes.forEach(function(n, idx) {
				rows.push(E('tr', {}, [
					E('td', {}, n.enabled !== false ? '启用' : '停用'),
					E('td', {}, n.name || '-'),
					E('td', {}, n.type),
					E('td', {}, (n.server || '') + ':' + (n.port || '')),
					E('td', {}, n.type === 'ss' ? (n.cipher || '') : (n.uuid || n.password || '')),
					E('td', { class: 'cbi-button-cell' }, [
						E('button', { class: 'cbi-button cbi-button-apply', click: function() { self.toggle(n); } }, n.enabled !== false ? '停用' : '启用'),
						E('button', { class: 'cbi-button', click: function() { self.move(n, -1); } }, '上移'),
						E('button', { class: 'cbi-button', click: function() { self.move(n, 1); } }, '下移'),
						E('button', { class: 'cbi-button', click: function() { self.edit(n, refresh); } }, '编辑'),
						E('button', { class: 'cbi-button cbi-button-reset', click: function() { self.remove(n, refresh); } }, '删除')
					])
				]));
			});
			if (!rows.length)
				rows.push(E('tr', {}, [ E('td', { colspan: 6 }, '还没有节点，先粘贴分享链接或手工添加。') ]));

			while (table.firstChild)
				table.removeChild(table.firstChild);
			table.appendChild(E('table', { class: 'cbi-section-table' }, [
				E('tr', { class: 'cbi-section-table-titles' }, [
					E('th', {}, '状态'), E('th', {}, '名称'), E('th', {}, '类型'),
					E('th', {}, '地址'), E('th', {}, '凭据'), E('th', {}, '操作')
				])
			].concat(rows)));
		}
		this.refresh = refresh;

		var warning = (this.status && this.status.warnings && this.status.warnings.length)
			? E('div', { class: 'cbi-section cbi-section-error' }, [
				E('p', {}, '最近一次生成告警：'),
				E('ul', {}, this.status.warnings.map(function(w) { return E('li', {}, w); }))
			])
			: '';

		refresh();

		return E('div', {}, [
			E('h2', {}, '节点管理'),
			E('p', { class: 'cbi-section-descr' },
				'节点保存在 /etc/ferry/nodes.json，与 UCI 分离；停用/排序/改名后立即生效。' +
				'当前激活档案：' + (this.profile ? this.profile.name : '（无）')),
			warning,
			E('div', { class: 'cbi-section' }, [
				E('h3', {}, '批量导入分享链接'),
				importBox,
				E('div', { class: 'cbi-button-row' }, [
					E('button', { class: 'cbi-button cbi-button-apply', click: function() {
						var r = links.parse(importBox.value);
						if (!r.nodes.length) {
							fail('没有解析出任何节点' + (r.errors.length ? '：' + r.errors.join('；') : ''));
							return;
						}
						if (r.errors.length)
							notify('部分链接解析失败：' + r.errors.join('；'));
						self.nodes = self.nodes.concat(r.nodes);
						importBox.value = '';
						self.persist('已导入 ' + r.nodes.length + ' 个节点');
					} }, '解析并导入'),
					E('button', { class: 'cbi-button', click: function() { self.edit(null, refresh); } }, '手工添加节点')
				])
			]),
			E('div', { class: 'cbi-section' }, [ E('h3', {}, '节点列表'), table ])
		]);
	},

	persist: function(msg) {
		var self = this;
		return store.saveNodes(this.nodes).then(function(saved) {
			self.nodes = saved;
			self.refresh();
			return store.setActiveNodes(saved.map(function(n) { return n.id; }));
		}).then(function() {
			if (msg)
				notify(msg + '，已重新生成配置');
		}).catch(function(e) {
			fail('保存失败：' + e.message);
		});
	},

	toggle: function(n) {
		n.enabled = n.enabled === false;
		this.persist((n.enabled === false ? '已停用 ' : '已启用 ') + n.name);
	},

	move: function(n, dir) {
		var i = this.nodes.indexOf(n);
		var j = i + dir;
		if (j < 0 || j >= this.nodes.length)
			return;
		var t = this.nodes[i];
		this.nodes[i] = this.nodes[j];
		this.nodes[j] = t;
		this.persist('已调整顺序');
	},

	remove: function(n, refresh) {
		var self = this;
		if (!window.confirm('删除节点「' + n.name + '」？'))
			return;
		this.nodes = this.nodes.filter(function(x) { return x !== n; });
		this.persist('已删除节点').then(function() { refresh(); });
	},

	edit: function(n, refresh) {
		var self = this;
		var isNew = !n;
		var node = n ? JSON.parse(JSON.stringify(n)) : {
			id: '', type: 'vmess', name: '', enabled: true, server: '', port: 443,
			uuid: '', password: '', cipher: '', alterId: 0, scy: '', flow: '', network: 'tcp',
			path: '', host: '', serviceName: '', tls: true, sni: '', alpn: [], fingerprint: '',
			publicKey: '', shortId: '', insecure: false, plugin: '', pluginOpts: '',
			ssrProtocol: 'origin', ssrObfs: 'plain', ssrProtocolParam: '', ssrObfsParam: '',
			hyObfs: '', hyObfsPassword: '', hyUp: '', hyDown: '', tuicCC: '', tuicUdpMode: ''
		};

		var fieldsBox = E('div', {}, []);
		var inputs = {};

		function buildFields() {
			while (fieldsBox.firstChild)
				fieldsBox.removeChild(fieldsBox.firstChild);
			inputs = {};

			[ 'name', 'server', 'port' ].forEach(function(k) {
				fieldsBox.appendChild(E('div', { class: 'cbi-value' }, [
					E('label', { class: 'cbi-value-title' }, LABELS[k]), mkInput(k, node[k])
				]));
				inputs[k] = fieldsBox.lastChild.lastChild;
			});

			var t = node.type;
			(NODE_FIELDS[t] || []).forEach(function(k) {
				var inp = mkInput(k, k === 'alpn' ? (node.alpn || []).join(',') : node[k]);
				inputs[k] = inp;
				fieldsBox.appendChild(E('div', { class: 'cbi-value' }, [
					E('label', { class: 'cbi-value-title' }, LABELS[k] || k), inp
				]));
			});
		}

		var typeSel = E('select', { class: 'cbi-input-select', change: function(ev) {
			node.type = ev.target.value;
			buildFields();
		} }, TYPES.map(function(t) {
			return E('option', { value: t[0], selected: node.type === t[0] }, t[1]);
		}));

		var content = E('div', { class: 'cbi-section' }, [
			E('div', { class: 'cbi-value' }, [
				E('label', { class: 'cbi-value-title' }, '类型'), typeSel
			]),
			fieldsBox
		]);
		buildFields();

		openModal(isNew ? '添加节点' : '编辑节点', content, [
			{
				label: '取消', class: 'cbi-button',
				callback: function() { return true; }
			},
			{
				label: isNew ? '添加' : '保存', class: 'cbi-button cbi-button-apply',
				callback: function() {
					[ 'name', 'server', 'port' ].concat(NODE_FIELDS[node.type] || []).forEach(function(k) {
						var inp = inputs[k];
						if (!inp)
							return;
						if (k === 'tls' || k === 'insecure')
							node[k] = !!inp.checked;
						else if (k === 'port' || k === 'alterId')
							node[k] = parseInt(inp.value, 10) || 0;
						else if (k === 'alpn')
							node[k] = String(inp.value || '').split(',').map(function(s) { return s.trim(); }).filter(function(s) { return s; });
						else
							node[k] = inp.value;
					});
					if (!node.server || !node.port) {
						fail('服务器和端口不能为空');
						return false;
					}
					if (isNew)
						self.nodes.push(node);
					else {
						var i = self.nodes.indexOf(n);
						if (i >= 0)
							self.nodes[i] = node;
					}
					self.persist(isNew ? '已添加节点' : '已更新节点');
					return true;
				}
			}
		]);
	}
});
