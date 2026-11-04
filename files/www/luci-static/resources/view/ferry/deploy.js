'use strict';
'require view';
'require ui';
'require uci';
'require ferry.store as store';

function notify(msg, type) {
	if (typeof ui.addNotification === 'function')
		ui.addNotification(null, E('p', {}, msg), type || 'info');
	else
		window.alert(msg);
}

var DEPLOYS = [
	{
		id: 'router', name: '主路由（接管全部 LAN 流量）',
		desc: '本机就是出口网关：内核监听 TPROXY/TUN，nftables 接管 br-lan 的转发流量并劫持 DNS。',
		steps: [
			'确保「接管实现」为 auto/nft，且已安装 kmod-nft-tproxy（TPROXY 模式）。',
			'路由器自身作为网关，局域网设备无需任何额外设置。',
			'如需局域网 DNS 走代理，保持「劫持局域网 DNS」与「路由器自身 DNS 走内核」开启。'
		]
	},
	{
		id: 'bypass', name: '旁路由（透明网关）',
		desc: '不接管本机转发，只对本机收到的流量做代理；由上游主路由把网关和 DNS 指过来。',
		steps: [
			'主路由 DHCP 的「网关」和「DNS」都填旁路由的 LAN IP（两者必须一致，否则部分系统会绕过代理）。',
			'在旁路由上关闭 DHCP 服务（或在主路由上停用 DHCP），避免两台设备争抢分配。',
			'上游主路由的防火墙需放行到旁路由的转发流量；若主路由开启了 DNS 劫持/DoH，应先关闭。',
			'TUN 模式下本机 auto-route 被强制为 false，避免抢走主路由的转发；推荐使用 TPROXY。',
			'旁路由自身出口默认不经过代理，如需让旁路由本机应用走代理，请使用 mixed 端口。'
		]
	},
	{
		id: 'client', name: '客户端（只生成配置）',
		desc: '不开启透明代理、不安装任何 netfilter 规则，只生成可导入的 mihomo YAML / sing-box JSON，并监听 mixed 端口。',
		steps: [
			'把生成的配置文件导入到你的客户端（mihomo / Clash Verge / sing-box 等）。',
			'本机或局域网手工指定代理地址：http://<本机IP>:<mixed 端口>（同时支持 SOCKS5）。',
			'本形态不会改写 dnsmasq，也不会接管任何流量；混合端口为 0 时自动按 7891 生成。',
			'若只需要一份配置、不希望影响路由器网络，这是最安全的形态。'
		]
	}
];

return view.extend({
	load: function() {
		return Promise.all([
			store.activeProfile().catch(function() { return { profile: null }; }),
			store.status(),
			uci.load('ferry'),
			store.readKernelConfig()
		]);
	},

	render: function(data) {
		var self = this;
		this.profile = (data[0] && data[0].profile) || null;
		this.status = data[1] || null;
		this.cfg = data[3] || { path: '', text: '' };

		if (!this.profile)
			return E('div', {}, [
				E('h2', {}, '部署形态'),
				E('p', { class: 'cbi-section-error' }, '还没有激活的配置档案，请先到「配置档案」页创建并激活一个。')
			]);

		var p = JSON.parse(JSON.stringify(this.profile));
		store.syncUci(p);
		var cur = p.deploy || 'router';

		var blocks = {};
		var radios = DEPLOYS.map(function(d) {
			blocks[d.id] = E('div', { class: 'cbi-section', style: cur === d.id ? '' : 'display:none' }, [
				E('p', {}, d.desc),
				E('ol', {}, d.steps.map(function(s) { return E('li', {}, s); }))
			]);
			var rb = E('input', { type: 'radio', name: 'pm-deploy', value: d.id, class: 'cbi-radio-input' });
			rb.checked = cur === d.id;
			rb.addEventListener('change', function() {
				if (!rb.checked)
					return;
				cur = d.id;
				DEPLOYS.forEach(function(x) { blocks[x.id].style.display = x.id === d.id ? '' : 'none'; });
			});
			return E('div', { class: 'cbi-value' }, [
				E('label', { class: 'cbi-value-title' }, d.name),
				E('div', { class: 'cbi-value-field' }, [
					E('label', {}, [ rb, E('span', {}, ' 选择') ])
				])
			]);
		});

		var finalSel = E('select', { class: 'cbi-input-select' }, [
			[ 'proxy', '默认走代理' ], [ 'direct', '默认直连' ]
		].map(function(t) {
			return E('option', { value: t[0], selected: (p.final_policy || 'proxy') === t[0] }, t[1]);
		}));
		finalSel.value = p.final_policy || 'proxy';

		var cfgName = this.cfg.path.match(/\.json$/) ? 'ferry-config.json' : 'ferry-config.yaml';
		var preview = E('pre', { style: 'max-height:320px;overflow:auto;white-space:pre-wrap;font-size:12px' },
			this.cfg.text || '（还没有生成配置：请先保存并启用服务）');

		var warn = (this.status && this.status.warnings && this.status.warnings.length)
			? E('div', { class: 'cbi-section cbi-section-error' }, [
				E('p', {}, '最近一次生成告警：'),
				E('ul', {}, this.status.warnings.map(function(w) { return E('li', {}, w); }))
			])
			: '';

		return E('div', {}, [
			E('h2', {}, '部署形态'),
			E('p', { class: 'cbi-section-descr' },
				'当前档案：' + p.name + '　内核：' + (p.kernel || 'mihomo') + '　运行模式：' + (p.mode || 'tproxy') +
				'。部署形态决定生成的配置内容、是否安装 netfilter 规则以及 init 脚本的启动行为。'),
			warn,

			E('div', { class: 'cbi-section' }, [ E('h3', {}, '选择形态') ].concat(radios)),
			E('div', {}, DEPLOYS.map(function(d) { return blocks[d.id]; })),

			E('div', { class: 'cbi-section' }, [
				E('h3', {}, '默认策略'),
				E('div', { class: 'cbi-value' }, [
					E('label', { class: 'cbi-value-title' }, '未被任何规则命中时'),
					E('div', { class: 'cbi-value-field' }, [ finalSel ])
				]),
				E('div', { class: 'cbi-button-row' }, [
					E('button', { class: 'cbi-button cbi-button-apply', click: function() {
						p.deploy = cur;
						p.final_policy = finalSel.value;
						notify('正在保存部署形态并重新生成配置…');
						store.saveActiveProfile(p).then(function() {
							notify('已保存，服务正在 reload');
							window.setTimeout(function() { location.reload(); }, 800);
						}).catch(function(e) {
							notify('保存失败：' + e.message, 'error');
						});
					} }, '保存并应用')
				])
			]),

			E('div', { class: 'cbi-section' }, [
				E('h3', {}, '当前生成的配置'),
				E('p', { class: 'cbi-section-descr' }, this.cfg.path || '（未知路径）'),
				preview,
				E('div', { class: 'cbi-button-row' }, [
					E('button', { class: 'cbi-button', click: function() {
						store.readKernelConfig().then(function(c) {
							preview.textContent = c.text || '（还没有生成配置）';
						});
					} }, '刷新预览'),
					E('button', { class: 'cbi-button cbi-button-apply', click: function() {
						var text = preview.textContent;
						try {
							var blob = new Blob([ text ], { type: 'text/plain' });
							var url = URL.createObjectURL(blob);
							var a = document.createElement('a');
							a.href = url;
							a.download = cfgName;
							document.body.appendChild(a);
							a.click();
							document.body.removeChild(a);
							URL.revokeObjectURL(url);
						} catch (e) {
							window.alert('浏览器不支持直接下载，请复制下方配置内容');
						}
					} }, '下载配置')
				])
			])
		]);
	}
});
