'use strict';
'require view';
'require ui';
'require ferry.store as store';
'require ferry.preset-defs as presets';

function notify(msg, type) {
	if (typeof ui.addNotification === 'function')
		ui.addNotification(null, E('p', {}, msg), type || 'info');
	else
		window.alert(msg);
}

return view.extend({
	load: function() {
		return store.activeProfile().catch(function() { return { profile: null }; });
	},

	render: function(data) {
		var self = this;
		this.profile = (data && data.profile) || null;

		var cards = presets.PRESETS.map(function(pr) {
			var targets = presets.CATEGORIES.map(function(c) {
				var t = pr.targets[c.id] || c.defaultTarget;
				return E('li', {}, c.name + ' → ' + t);
			});
			var active = self.profile && self.profile.preset === pr.id;
			return E('div', { class: 'cbi-section', style: 'border:1px solid var(--border-color, #ccc);border-radius:6px;padding:8px 12px;margin-bottom:8px' }, [
				E('h3', {}, pr.name + (active ? '（当前预设）' : '')),
				E('p', {}, pr.desc),
				E('p', { class: 'cbi-section-descr' },
					'运行模式：' + pr.mode + '　部署形态：' + pr.deploy + '　默认策略：' + pr.final),
				E('ul', {}, targets),
				E('div', { class: 'cbi-button-row' }, [
					E('button', { class: 'cbi-button cbi-button-apply', click: function() {
						if (!window.confirm('应用预设「' + pr.name + '」？会覆盖当前档案的规则与策略，但保留已导入的节点。'))
							return;
						notify('正在应用预设…');
						store.applyPreset(pr.id).then(function() {
							notify('预设「' + pr.name + '」已应用，配置已重新生成');
							window.setTimeout(function() { location.reload(); }, 600);
						}).catch(function(e) {
							notify('应用失败：' + e.message, 'error');
						});
					} }, active ? '重新应用' : '应用预设')
				])
			]);
		});

		return E('div', {}, [
			E('h2', {}, '场景预设'),
			E('p', { class: 'cbi-section-descr' },
				'一键套用一组规则开关、默认策略与建议运行模式。预设只改当前激活档案的规则与策略，' +
				'不会删除或重排已导入的节点；应用后仍可在「分流规则」页继续微调。' +
				'当前档案：' + (this.profile ? this.profile.name : '（无）'))
		].concat(cards));
	}
});
