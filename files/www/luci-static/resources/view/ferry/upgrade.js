'use strict';
'require view';
'require rpc';
'require ui';

var callStatus = rpc.declare({ object: 'luci-ferry-upgrade', method: 'status', expect: {} });
var callSnapshot = rpc.declare({ object: 'luci-ferry-upgrade', method: 'snapshot', expect: {} });
var callVerify = rpc.declare({ object: 'luci-ferry-upgrade', method: 'verify', expect: {} });
var callRestore = rpc.declare({ object: 'luci-ferry-upgrade', method: 'restore', expect: {} });
var callPrep = rpc.declare({ object: 'luci-ferry-upgrade', method: 'prep', expect: {} });
var callRemove = rpc.declare({ object: 'luci-ferry-upgrade', method: 'remove', expect: {} });

function notify(msg) {
	if (typeof ui.addNotification === 'function')
		ui.addNotification(null, E('p', {}, msg), 'info');
	else
		window.alert(msg);
}

return view.extend({
	load: function() {
		return callStatus().catch(function() { return {}; });
	},

	render: function(status) {
		var self = this;
		var out = E('pre', {
			style: 'white-space:pre-wrap;max-height:26em;overflow:auto;background:var(--background-color-low,#f5f5f5);padding:1em;border-radius:4px'
		}, (status && status.output) || '');

		function btn(label, cls, fn) {
			return E('button', { class: 'cbi-button ' + (cls || ''), click: function(ev) {
				ev.preventDefault();
				out.textContent = '执行中…';
				fn().then(function(r) {
					out.textContent = (r && r.output) || '完成';
					return callStatus().then(function(s) {
						out.textContent += '\n\n--- 当前状态 ---\n' + ((s && s.output) || '');
					}).catch(function() {});
				}).catch(function(e) {
					out.textContent = '失败：' + (e.message || e);
					notify('操作失败：' + (e.message || e));
				});
			} }, label);
		}

		return E([
			E('h2', {}, _('升级与恢复')),
			E('div', { class: 'cbi-section-descr' }, _(
				'升级前：先“导出快照并自检”，再“升级前准备”（写入 keep.d、生成离线安装包）；' +
				'如果使用 attended sysupgrade（owut/auc），还需要“安全移除 ferry”，否则构建会因找不到第三方包失败。' +
				'刷机后首次启动会由 /etc/uci-defaults/60-ferry-selfheal 自动离线装回并恢复配置；' +
				'也可以用下面的“一键恢复”手工触发。'
			)),
			E('div', { class: 'cbi-section' }, [
				btn(_('导出快照并自检'), 'cbi-button-action', callSnapshot),
				' ',
				btn(_('升级前准备'), '', callPrep),
				' ',
				btn(_('一致性校验'), '', callVerify),
				' ',
				btn(_('一键恢复'), 'cbi-button-apply', callRestore),
				' ',
				btn(_('安全移除 ferry'), 'cbi-button-reset', function() {
					if (!window.confirm(_('将卸载 ferry 包（保留 /etc/config/ferry 与 /etc/ferry，含内核与快照）。继续？')))
						return Promise.reject(new Error(_('已取消')));
					return callRemove();
				})
			]),
			E('div', { class: 'cbi-section' }, [
				E('h3', {}, _('输出')),
				out
			])
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
