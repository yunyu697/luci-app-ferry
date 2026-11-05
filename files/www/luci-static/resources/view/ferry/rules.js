'use strict';
'require view';
'require ui';
'require uci';
'require ferry.store as store';
'require ferry.preset-defs as presets';

var TARGETS = [
	[ 'proxy', '走节点组（PROXY）' ],
	[ 'direct', '直连（DIRECT）' ],
	[ 'reject', '拒绝（REJECT）' ]
];

var MIRRORS = [
	[ 'github', 'GitHub raw 直连' ],
	[ 'ghproxy', 'ghproxy 类代理（ghproxy.net）' ],
	[ 'jsdelivr', 'jsDelivr CDN' ],
	[ 'custom', '自建地址（填前缀）' ]
];

function notify(msg, type) {
	if (typeof ui.addNotification === 'function')
		ui.addNotification(null, E('p', {}, msg), type || 'info');
	else
		window.alert(msg);
}

function fail(msg) {
	notify(msg, 'error');
}

/* 补齐缺失分类，保留已有顺序与设置 */
function normalizeRules(rules) {
	var cur = (rules || []).filter(function(r) { return r && r.cat; });
	var have = {};
	cur.forEach(function(r) { have[r.cat] = 1; });
	presets.CATEGORIES.forEach(function(c) {
		if (!have[c.id])
			cur.push({ cat: c.id, target: c.defaultTarget, enabled: true });
	});
	return cur;
}

return view.extend({
	load: function() {
		return Promise.all([
			store.activeProfile().catch(function() { return { profile: null, db: null }; }),
			store.status(),
			uci.load('ferry')
		]);
	},

	render: function(data) {
		var self = this;
		this.profile = (data[0] && data[0].profile) || null;
		this.status = data[1] || null;
		if (!this.profile)
			return E('div', {}, [
				E('h2', {}, '分流规则'),
				E('p', { class: 'cbi-section-error' }, '还没有激活的配置档案，请先到「配置档案」页创建并激活一个。')
			]);

		var p = JSON.parse(JSON.stringify(this.profile));
		store.syncUci(p);
		p.rules = normalizeRules(p.rules);
		p.custom_domains = p.custom_domains || [];
		p.custom_cidrs = p.custom_cidrs || [];
		p.rule_mirror = p.rule_mirror || uci.get('ferry', 'main', 'rule_mirror', 'github');
		p.rule_mirror_custom = p.rule_mirror_custom || uci.get('ferry', 'main', 'rule_mirror_custom', '');
		p.rule_mirror_backup = p.rule_mirror_backup || uci.get('ferry', 'main', 'rule_mirror_backup', '');
		p.rule_update = p.rule_update == null ? uci.get('ferry', 'main', 'rule_update', '1') : p.rule_update;
		this.p = p;

		var table = E('div', {}, []);
		function refresh() {
			var rows = p.rules.map(function(r, idx) {
				var c = presets.CATEGORIES.filter(function(x) { return x.id === r.cat; })[0] || { id: r.cat, name: r.cat, desc: '' };
				var sel = E('select', { class: 'cbi-input-select', change: function(ev) { r.target = ev.target.value; } },
					TARGETS.map(function(t) {
						return E('option', { value: t[0], selected: r.target === t[0] }, t[1]);
					}));
				var cb = E('input', { type: 'checkbox', class: 'cbi-checkbox-input', click: function(ev) { r.enabled = ev.target.checked; } });
				cb.checked = r.enabled !== false;
				return E('tr', {}, [
					E('td', {}, String(idx + 1)),
					E('td', {}, [ E('strong', {}, c.name), E('div', { class: 'cbi-section-descr' }, c.desc || '') ]),
					E('td', {}, [ cb ]),
					E('td', {}, [ sel ]),
					E('td', { class: 'cbi-button-cell' }, [
						E('button', { class: 'cbi-button', click: function() { self.moveRule(r, -1, refresh); } }, '上移'),
						E('button', { class: 'cbi-button', click: function() { self.moveRule(r, 1, refresh); } }, '下移')
					])
				]);
			});
			while (table.firstChild)
				table.removeChild(table.firstChild);
			table.appendChild(E('table', { class: 'cbi-section-table' }, [
				E('tr', { class: 'cbi-section-table-titles' }, [
					E('th', {}, '优先级'), E('th', {}, '分类'), E('th', {}, '启用'), E('th', {}, '目标策略'), E('th', {}, '排序')
				])
			].concat(rows)));
		}
		refresh();

		/* 镜像源 */
		var mirrorSel = E('select', { class: 'cbi-input-select' }, MIRRORS.map(function(m) {
			return E('option', { value: m[0], selected: p.rule_mirror === m[0] }, m[1]);
		}));
		mirrorSel.value = p.rule_mirror;

		var customInput = E('input', { type: 'text', class: 'cbi-input-text', value: p.rule_mirror_custom, placeholder: 'https://mirror.example.com/' });
		var backupSel = E('select', { class: 'cbi-input-select' },
			[ [ '', '无备用源' ] ].concat(MIRRORS).map(function(m) {
				return E('option', { value: m[0], selected: p.rule_mirror_backup === m[0] }, m[1]);
			}));
		backupSel.value = p.rule_mirror_backup;

		var updateCb = E('input', { type: 'checkbox', class: 'cbi-checkbox-input' });
		updateCb.checked = String(p.rule_update) !== '0';

		var domainsBox = E('textarea', { class: 'cbi-input-textarea', rows: 4, style: 'width:100%',
			placeholder: '一行一个：example.com 走后缀匹配；写成 full:example.com 走精确匹配' },
			p.custom_domains.join('\n'));
		var cidrBox = E('textarea', { class: 'cbi-input-textarea', rows: 4, style: 'width:100%',
			placeholder: '一行一个网段，例如 10.0.0.0/8 或 2001:db8::/32' },
			p.custom_cidrs.join('\n'));

		var warnings = (this.status && this.status.warnings && this.status.warnings.length)
			? E('div', { class: 'cbi-section cbi-section-error' }, [
				E('p', {}, '最近一次生成告警：'),
				E('ul', {}, this.status.warnings.map(function(w) { return E('li', {}, w); }))
			])
			: '';

		return E('div', {}, [
			E('h2', {}, '分流规则'),
			E('p', { class: 'cbi-section-descr' },
				'规则按表格顺序生成，越靠上越优先（first-match，命中即停止）。' +
				'「自定义域名/网段」按它在列表中的位置插入，改完记得保存。当前档案：' + p.name),
			warnings,

			E('div', { class: 'cbi-section' }, [
				E('h3', {}, '规则数据源（镜像）'),
				E('div', { class: 'cbi-value' }, [
					E('label', { class: 'cbi-value-title' }, '主源'),
					E('div', { class: 'cbi-value-field' }, [ mirrorSel ])
				]),
				E('div', { class: 'cbi-value' }, [
					E('label', { class: 'cbi-value-title' }, '自建前缀'),
					E('div', { class: 'cbi-value-field' }, [
						customInput,
						E('div', { class: 'cbi-section-descr' }, '主源选「自建地址」时使用，格式为 <前缀>/MetaCubeX/meta-rules-dat/<路径>。')
					])
				]),
				E('div', { class: 'cbi-value' }, [
					E('label', { class: 'cbi-value-title' }, '备用源'),
					E('div', { class: 'cbi-value-field' }, [
						backupSel,
						E('div', { class: 'cbi-section-descr' }, '主源失败时依次尝试备用源；全部失败则回退本地缓存，不会阻止内核启动。')
					])
				]),
				E('div', { class: 'cbi-value' }, [
					E('label', { class: 'cbi-value-title' }, '允许更新规则'),
					E('div', { class: 'cbi-value-field' }, [
						updateCb,
						E('div', { class: 'cbi-section-descr' }, '关闭后只用本地缓存（缓存目录 /etc/ferry/rules-cache/）。')
					])
				])
			]),

			E('div', { class: 'cbi-section' }, [ E('h3', {}, '分类规则'), table ]),

			E('div', { class: 'cbi-section' }, [
				E('h3', {}, '自定义域名 / 网段'),
				E('div', { class: 'cbi-value' }, [
					E('label', { class: 'cbi-value-title' }, '域名'),
					E('div', { class: 'cbi-value-field' }, [ domainsBox ])
				]),
				E('div', { class: 'cbi-value' }, [
					E('label', { class: 'cbi-value-title' }, 'IP 网段'),
					E('div', { class: 'cbi-value-field' }, [ cidrBox ])
				])
			]),

			E('div', { class: 'cbi-button-row' }, [
				E('button', { class: 'cbi-button cbi-button-apply', click: function() {
					p.rule_mirror = mirrorSel.value;
					p.rule_mirror_custom = customInput.value.trim();
					p.rule_mirror_backup = backupSel.value;
					p.rule_update = updateCb.checked ? '1' : '0';
					p.custom_domains = domainsBox.value.split(/\r?\n/).map(function(s) { return s.trim(); })
						.filter(function(s) { return s; });
					p.custom_cidrs = cidrBox.value.split(/\r?\n/).map(function(s) { return s.trim(); })
						.filter(function(s) { return s; });
					if (p.rules.every(function(r) { return r.enabled === false; })) {
						fail('至少启用一个分类，否则只能由默认策略兜底。');
						return;
					}
					notify('正在保存规则并重新生成配置…');
					store.saveActiveProfile(p).then(function() {
						notify('规则已保存，配置已重新生成');
					}).catch(function(e) {
						fail('保存失败：' + e.message);
					});
				} }, '保存并应用')
			])
		]);
	},

	moveRule: function(r, dir, refresh) {
		var rules = this.p.rules;
		var i = rules.indexOf(r);
		var j = i + dir;
		if (j < 0 || j >= rules.length)
			return;
		var t = rules[i];
		rules[i] = rules[j];
		rules[j] = t;
		refresh();
	}
});
