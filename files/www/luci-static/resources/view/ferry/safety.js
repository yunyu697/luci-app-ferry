'use strict';
'require view';
'require rpc';
'require ui';

var callStatus = rpc.declare({ object: 'luci-ferry-safety', method: 'status', expect: {} });
var callConfirm = rpc.declare({ object: 'luci-ferry-safety', method: 'confirm', expect: {} });
var callRollback = rpc.declare({ object: 'luci-ferry-safety', method: 'rollback', expect: {} });
var callDisable = rpc.declare({ object: 'luci-ferry-safety', method: 'disable', expect: {} });
var callEnable = rpc.declare({ object: 'luci-ferry-safety', method: 'enable', expect: {} });
var callDiag = rpc.declare({ object: 'luci-ferry-safety', method: 'diag', expect: {} });
var callDiagDownload = rpc.declare({ object: 'luci-ferry-safety', method: 'diag_download', expect: {} });

function notify(msg, type) {
	if (typeof ui.addNotification === 'function')
		ui.addNotification(null, E('p', {}, msg), type || 'info');
	else
		window.alert(msg);
}

function fmtLeft(s) {
	s = Number(s) || 0;
	if (s <= 0) return '0 秒';
	var m = Math.floor(s / 60), r = s % 60;
	return m > 0 ? (m + ' 分 ' + r + ' 秒') : (r + ' 秒');
}

return view.extend({
	load: function() {
		return callStatus().catch(function() { return {}; });
	},

	render: function(status) {
		var self = this;
		var panel = E('div', { class: 'cbi-section' });
		var diagBox = E('div', { class: 'cbi-section' });
		var timer = null;

		function btn(label, cls, fn) {
			return E('button', { class: 'cbi-button ' + (cls || ''), click: function(ev) {
				ev.preventDefault();
				fn();
			} }, label);
		}

		function action(fn, okMsg) {
			return fn().then(function() {
				notify(okMsg);
				return refresh();
			}).catch(function(e) {
				notify('操作失败：' + (e.message || e), 'error');
			});
		}

		function refresh() {
			return callStatus().then(function(s) {
				status = s || {};
				renderPanel();
			}).catch(function() {});
		}

		function renderPanel() {
			while (panel.firstChild) panel.removeChild(panel.firstChild);

			panel.appendChild(E('h3', {}, '应用事务'));
			if (!status.pending) {
				panel.appendChild(E('p', {}, '当前没有待确认的应用。保存并应用配置后，会在这里显示倒计时。'));
			} else {
				var phase = status.phase === 'applying' ? '正在应用' : '等待确认';
				panel.appendChild(E('p', { class: 'cbi-section-descr' }, [
					'状态：' + phase + '（事务 ' + (status.id || '?') + '）　',
					status.phase === 'pending'
						? '剩余 ' + fmtLeft(status.secondsleft) + '，超时自动回滚到应用前。'
						: '应用过程异常中断时，看门狗会在 120 秒内还原。'
				]));
				if (status.phase === 'pending') {
					panel.appendChild(E('div', { class: 'cbi-button-row' }, [
						btn('确认保留', 'cbi-button-apply', function() {
							action(callConfirm, '已确认保留本次配置');
						}),
						btn('立即回滚', 'cbi-button-remove', function() {
							action(callRollback, '已按快照回滚');
						})
					]));
				}
			}

			panel.appendChild(E('h3', {}, '临时关闭代理'));
			if (status.tmp_off) {
				panel.appendChild(E('p', { class: 'cbi-section-error' },
					'代理已临时关闭：内核已停止、接管规则已撤除、dnsmasq 已回到原生上游。' +
					'此状态重启后保持，点击恢复才会重新接管。'));
				panel.appendChild(E('div', { class: 'cbi-button-row' }, [
					btn('恢复代理', 'cbi-button-apply', function() {
						action(callEnable, '已恢复关闭前的接管形态');
					})
				]));
			} else {
				panel.appendChild(E('p', { class: 'cbi-section-descr' },
					'一键停止内核并撤除全部接管规则，DNS 完整回到 dnsmasq 原生上游（不保留半关闭状态）。'));
				panel.appendChild(E('div', { class: 'cbi-button-row' }, [
					btn('临时关闭代理', 'cbi-button-remove', function() {
						if (window.confirm('确认临时关闭代理？当前接管会立即撤销。'))
							action(callDisable, '已临时关闭代理');
					})
				]));
			}

			panel.appendChild(E('h3', {}, '应用确认倒计时'));
			panel.appendChild(E('p', { class: 'cbi-section-descr' },
				'倒计时长度在「基础设置」里配置（30-180 秒，默认 60）。看门狗由 procd 常驻，' +
				'关闭浏览器或断开 SSH 不影响回滚。'));
		}

		renderPanel();

		diagBox.appendChild(E('h3', {}, '诊断包'));
		diagBox.appendChild(E('p', { class: 'cbi-section-descr' },
			'收集 UCI、nft、策略路由、内核版本与自检、日志尾部、DNS/连通性、能力探测；' +
			'订阅 URL 只保留 host，节点密码/UUID/token 与私钥会被脱敏。'));
		var diagResult = E('p', {});
		diagBox.appendChild(E('div', { class: 'cbi-button-row' }, [
			btn('生成诊断包', 'cbi-button-apply', function() {
				diagResult.textContent = '正在收集…';
				callDiag().then(function(r) {
					if (!r || !r.ok) {
						diagResult.textContent = '生成失败：' + ((r && r.error) || '未知错误');
						return;
					}
					diagResult.textContent = '已生成：' + r.path + '（' + r.size + ' 字节，sha256 ' + (r.sha256 || 'n/a') + '）';
					diagResult.setAttribute('data-path', r.path);
					var dl = E('button', { class: 'cbi-button cbi-button-action', click: function() {
						callDiagDownload().then(function(b64) {
							if (!b64 || b64.indexOf('{') === 0) {
								notify('设备缺少 base64 工具，请用 scp/SSH 下载：' + r.path, 'error');
								return;
							}
							var raw = atob(String(b64).replace(/\s+/g, ''));
							var arr = new Uint8Array(raw.length);
							for (var i = 0; i < raw.length; i++) arr[i] = raw.charCodeAt(i);
							var blob = new Blob([ arr ], { type: 'application/gzip' });
							var url = URL.createObjectURL(blob);
							var a = document.createElement('a');
							a.href = url; a.download = r.path.split('/').pop();
							document.body.appendChild(a); a.click(); document.body.removeChild(a);
							URL.revokeObjectURL(url);
						}).catch(function(e) {
							notify('下载失败：' + (e.message || e), 'error');
						});
					} }, '下载诊断包');
					var old = (diagResult.nextSibling && diagResult.nextSibling.className === 'cbi-button-row')
						? diagResult.nextSibling : null;
					if (!old) diagBox.appendChild(E('div', { class: 'cbi-button-row' }, [ dl ]));
				}).catch(function(e) {
					diagResult.textContent = '生成失败：' + (e.message || e);
				});
			})
		]));
		diagBox.appendChild(diagResult);

		// 有 pending 时每秒刷新；空闲时每 10 秒一次。
		// 代价：别的标签页/SSH 新建的 pending 最多晚 10 秒出现在本页；
		// 本页自身触发的保存会整页刷新，不受影响。
		var tick = 0;
		timer = window.setInterval(function() {
			tick++;
			if (!document.body.contains(panel)) {
				window.clearInterval(timer);
				return;
			}
			if ((status.pending && status.phase === 'pending') || tick % 10 === 0)
				refresh();
		}, 1000);

		return E('div', {}, [
			E('h2', {}, '安全与诊断'),
			E('p', { class: 'cbi-section-descr' },
				'应用配置后的回滚保护、临时关闭开关与脱敏诊断包。所有操作均可通过 ' +
				'ferry-txnctl / ferry-diag 在 SSH 里完成。'),
			panel,
			diagBox
		]);
	}
});
