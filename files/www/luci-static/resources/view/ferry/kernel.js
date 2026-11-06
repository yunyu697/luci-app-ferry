'use strict';
'require view';
'require ui';
'require poll';
'require ferry.kernels as K';

function clear(node) { while (node.firstChild) node.removeChild(node.firstChild); }
function add(node, child) { node.appendChild(child); return child; }

function button(label, cls, onclick) {
	var b = E('button', { 'class': 'cbi-button ' + (cls || 'cbi-button-action') }, [ label ]);
	if (onclick) b.addEventListener('click', onclick);
	return b;
}

function table(headers, rows) {
	return E('table', { 'class': 'table' }, [
		E('tr', { 'class': 'tr table-titles' },
			headers.map(function(h) { return E('th', { 'class': 'th' }, [ h ]); }))
	].concat(rows.map(function(r) {
		return E('tr', { 'class': 'tr' },
			r.map(function(c) { return E('td', { 'class': 'td' }, [ c ]); }));
	})));
}

function select(options, onchange) {
	var s = E('select', { 'class': 'cbi-input-select' }, options.map(function(o) {
		return E('option', { 'value': o[0], 'selected': (o[2] ? '' : null) }, [ o[1] ]);
	}));
	if (onchange) s.addEventListener('change', onchange);
	return s;
}

function hint(text)  { return E('div', { 'class': 'cbi-value-help' }, [ text ]); }
function warn(text)  { return E('div', { 'class': 'alert-message warning' }, [ text ]); }
function info(text)  { return E('div', { 'class': 'alert-message' }, [ text ]); }

// 内核目录的持久性（对应后端 store_persist）
function storePersistText(s) {
	if (s.store_persist === 'rootfs')
		return 'overlay / ' + (s.store_device || '?') + '（sysupgrade 会清空，只有 keep.d 登记才进备份：'
			+ (s.keepd_installed ? '已登记，当前备份约 ' + Math.round((s.store_backup_kb || 0) / 1024) + ' MB' : '未登记') + '）';
	if (s.store_persist === 'external')
		return '外置存储（固件升级不影响，不占用 overlay）';
	if (s.store_persist === 'volatile')
		return '内存盘（重启即丢，不能用于安装）';
	return '未知';
}

return view.extend({
	load: function() {
		return K.callStatus().catch(function() { return {}; });
	},

	render: function(st) {
		var self = this;

		var state = {
			st: st || {},
			versions: null,
			versionsErr: '',
			versionsLoading: false,
			mirrorsErr: '',
			job: (st && st.job) ? st.job : null,
			selKernel: (st && st.uci_kernel_norm) || 'mihomo',
			selVersion: '',
			selUrl: '',
			preview: null,
			previewFor: '',
			src: (st && st.source_selected) || 'auto',
			prerelease: false,
			mirrors: null,
			mirrorMsg: '',
			curSize: 0,
			lastInstall: null,
			busy: false
		};

		var boxStatus = E('div', {});
		var boxSwitch = E('div', {});
		var boxInstalled = E('div', {});
		var boxInstall = E('div', {});
		var boxMirrors = E('div', {});
		var boxJob = E('div', {});

		function refreshStatus() {
			K.callStatus().then(function(s) {
				state.st = s;
				renderStatus();
				renderInstallTable();
				renderSwitch();
			}).catch(function(e) { ui.addNotification(null, E('p', {}, [ '读取状态失败：' + e ]), 'danger'); });
		}

		function installedList() {
			return (state.st.installed || []).filter(function(v) { return v && v.kernel; });
		}

		function findCurrent() {
			var k = state.st.uci_kernel_norm, act = state.st.active;
			var l = installedList();
			for (var i = 0; i < l.length; i++)
				if (l[i].kernel === k && (act ? l[i].tag === act : l[i].active))
					return l[i];
			return null;
		}

		function renderStatus() {
			var s = state.st, cur = findCurrent();
			var sha = s.active_sha256 || (cur && cur.sha256) || '';
			var size = s.active_size || (cur && cur.size) || 0;
			var binArch = s.active_arch || (cur && cur.arch) || '';
			var rows = [
				[ '当前内核', E('strong', {}, [ s.uci_kernel || '—' ]) ],
				[ '运行状态', s.running ? E('span', { 'style': 'color:#2e7d32' }, [ '运行中' ]) : E('span', { 'style': 'color:#b12704' }, [ '未运行' ]) ],
				[ '当前版本', s.active_version ? (s.active_version + '（' + (s.active || '') + '）') : (cur ? cur.version : '无（未纳入内核管理）') ],
				[ '二进制路径', s.bin_path || '—' ],
				[ '二进制来源', s.bin_source === 'plugin' ? '插件目录（current 指针）'
					: (s.bin_source === 'system' ? '系统自带（只读回退，未被覆盖）' : '未找到可执行文件') ],
				[ '内核目录', (s.kernel_dir || '—') + (s.store_device ? '（分区 ' + s.store_device + '）' : '') ],
				[ '目录持久性', storePersistText(s) ],
				[ 'current 指针', s.current_link || '—' ],
				[ '系统内核', s.system_bin
					? (s.system_bin + (s.system_bin_exists ? '（存在，插件不会覆盖）' : '（不存在）'))
					: '—' ],
				[ '文件大小', size ? K.fmtBytes(size) : '—' ],
				[ 'SHA-256', sha ? E('code', { 'title': sha }, [ K.shortSha(sha) ]) : '—' ],
				[ '架构匹配', binArch ? (binArch + ' / 本机 ' + (s.arch || '?') + (s.arch_match ? '（匹配）' : '（不匹配）'))
					: '未知（未纳入内核管理）' ],
				[ '配置文件', s.config_path || '—' ],
				[ '配置兼容', s.config_compatible ? '是' : E('span', { 'style': 'color:#b12704' }, [ '否（自备配置格式与内核不符）' ]) ],
				[ '配置自检', s.config_check
					? E('pre', { 'style': 'white-space:pre-wrap;max-height:12em;overflow:auto;margin:0' }, [ s.config_check ])
					: '尚无自检记录（切换或重启服务后更新）' ],
				[ '回滚目标', s.previous || '无' ],
				[ '本机架构', (s.arch || '未知') + (s.variants ? '（可用变体：' + s.variants + '）' : '') ],
				[ '下载源', (s.source_selected || 'auto') + (s.source_chain ? '（顺序：' + s.source_chain + '）' : '') ],
				[ '下载暂存', s.download_dir || '—' ],
				[ '可用空间', '内核目录 ' + Math.round((s.free_kb || 0) / 1024) + ' MB；运行目录 '
					+ Math.round((s.free_run_kb || 0) / 1024) + ' MB' ]
			];
			clear(boxStatus);
			add(boxStatus, table([ '项目', '值' ], rows.map(function(r) { return [ r[0], r[1] ]; })));
			if (s.config_compatible === false)
				add(boxStatus, warn('自备配置与当前内核格式不一致，切换前请先修正 ferry.main.config_path。'));
			if (s.store_persist === 'rootfs')
				add(boxStatus, warn('内核目录在 overlay 上：sysupgrade 只保留 /etc/sysupgrade.conf 与 /lib/upgrade/keep.d 登记的路径。'
					+ (s.keepd_installed ? '本插件已登记 keep.d，升级时会打进备份（当前 ' + Math.round((s.store_backup_kb || 0) / 1024)
						+ ' MB，备份过大可能导致升级失败，建议放外置存储）。' : '但本机没有 keep.d 登记，升级固件会丢内核，请重装本插件或改目录。')));
		}

		function renderInstallTable() {
			var l = installedList(), s = state.st;
			clear(boxInstalled);
			if (!l.length) {
				add(boxInstalled, info('还没有纳入管理的版本。可在下方「获取新版本」里下载安装（内置官方源 + 加速镜像）；系统自带的 /usr/bin/mihomo 不会被接管或覆盖，只作为只读回退。'));
				return;
			}
			var rows = l.map(function(v) {
				var actions = [];
				var isCur = s.uci_kernel_norm === v.kernel && (s.active === v.tag || v.active);
				var archOk = K.archMatch(s.arch, v.arch);
				if (!isCur)
					actions.push(button('启用', 'cbi-button-apply', function() { doSwitch(v.kernel, v.tag); }));
				if (v.previous && !isCur)
					actions.push(button('回滚到该版本', 'cbi-button-reset', function() { doRollback(v.kernel, v.tag); }));
				if (!isCur)
					actions.push(button('卸载', 'cbi-button-remove', function() { doRemove(v.kernel, v.tag); }));
				return [
					(v.kernel === 'mihomo' ? 'mihomo' : 'sing-box') + (isCur ? ' ← 当前' : ''),
					v.version + '（' + v.tag + '）',
					K.fmtBytes(v.size),
					E('code', { 'title': v.sha256 || '' }, [ K.shortSha(v.sha256) ]),
					(v.arch || '?') + (archOk ? '' : ' ⚠ 架构不符'),
					(v.verified === 'sha256' ? '已校验' : (v.verified === 'self' ? '安装时自校验' : '未校验')),
					v.source || '—',
					v.active ? '启用中' : (v.previous ? '回滚点' : '—'),
					E('div', {}, actions)
				];
			});
			add(boxInstalled, table([ '内核', '版本', '大小', 'SHA-256', '架构', '完整性', '来源', '状态', '操作' ], rows));
		}

		function renderSwitch() {
			var l = installedList();
			var curK = state.st.uci_kernel_norm;
			clear(boxSwitch);

			if (!state.selKernel) state.selKernel = curK;
			var selK = select([
				[ 'mihomo', 'mihomo', state.selKernel === 'mihomo' ],
				[ 'singbox', 'sing-box', state.selKernel === 'singbox' ]
			], function(ev) { state.selKernel = ev.target.value; state.selVersion = ''; state.preview = null; state.previewFor = ''; renderSwitch(); });

			var vers = l.filter(function(v) { return v.kernel === state.selKernel; });
			if (!state.selVersion && vers.length) state.selVersion = vers[0].tag;
			var selV = select(
				[ [ '', vers.length ? '— 选择版本 —' : '（该内核暂无已安装版本）', !state.selVersion ] ].concat(
					vers.map(function(v) {
						return [ v.tag, v.version + '（' + v.tag + '）' + (v.active ? ' ← 当前' : ''), state.selVersion === v.tag ];
					})),
				function(ev) { state.selVersion = ev.target.value; state.preview = null; state.previewFor = ''; renderSwitch(); });

			var target = vers.filter(function(v) { return v.tag === state.selVersion; })[0];
			var infoRows = [];
			if (target) {
				infoRows.push([ '目标内核', (target.kernel === 'mihomo' ? 'mihomo' : 'sing-box') + '  ' + target.version ]);
				var archOk = K.archMatch(state.st.arch, target.arch);
				infoRows.push([ '架构匹配', (target.arch || '?') + ' / 本机 ' + (state.st.arch || '?') + (archOk ? '（匹配）' : '（不匹配，切换会被拒绝）') ]);
				infoRows.push([ '完整性与来源', (target.verified === 'sha256' ? 'SHA-256 已校验' : (target.verified === 'self' ? '安装时自校验' : '未校验')) + '，' + (target.source || '未知') ]);
				if (target.kernel === 'singbox') {
					var b = K.bucketInfo(target.version);
					infoRows.push([ '配置模板', b ? ('区间 ' + K.bucketOf(target.version) + '（' + b.range + '，DNS=' + b.dns + '，规则=' + b.rules + '）')
						: '⚠ 未适配版本（不在支持矩阵内，切换会被阻止）' ]);
				}
			}

			// 配置预览：目标变化时异步读取（当前生效配置摘录 + 格式/生成方式变化）
			var pkey = target ? (target.kernel + ':' + target.tag) : '';
			if (target && state.previewFor !== pkey) {
				state.previewFor = pkey;
				state.preview = null;
				K.callPreview(target.kernel, target.tag).then(function(r) {
					if (state.previewFor !== pkey) return;
					state.preview = (r && r.ok) ? r : { error: (r && r.error) || '预览失败' };
					renderSwitch();
				}).catch(function(e) {
					if (state.previewFor !== pkey) return;
					state.preview = { error: '' + e };
					renderSwitch();
				});
			}
			if (target) {
				var p = state.preview;
				if (!p) {
					infoRows.push([ '配置预览', '正在读取当前生效配置…' ]);
				} else if (p.error) {
					infoRows.push([ '配置预览', '读取失败：' + p.error ]);
				} else {
					var notes = [];
					notes.push(p.format_change
						? ('格式变化：' + p.current_format + ' → ' + p.target_format + '（会按新内核重新生成，不能直接套用）')
						: ('格式相同：' + p.target_format));
					notes.push(p.regenerate ? '将由插件重新生成配置' : ('检测到自备配置 ' + p.current_config + '（格式不匹配时需显式强制切换）'));
					if (target.kernel === 'singbox')
						notes.push('目标 sing-box 区间：' + (p.sb_bucket || 'unknown') + (K.bucketOf(target.version) ? '' : '（未适配版本）'));
					infoRows.push([ '配置预览', E('div', {}, [
						E('p', {}, [ notes.join('；') ]),
						E('div', { 'class': 'cbi-value-help' }, [ '当前生效配置 ' + p.current_config + '（前 1500 字节）' ]),
						E('pre', { 'style': 'white-space:pre-wrap;max-height:16em;overflow:auto' }, [ p.excerpt || '（空）' ])
					]) ]);
				}
			}

			var box = E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ '目标内核' ]),
					E('div', { 'class': 'cbi-value-field' }, [ selK ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ '目标版本' ]),
					E('div', { 'class': 'cbi-value-field' }, [ selV ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ '' ]),
					E('div', { 'class': 'cbi-value-field' }, [ table([ '切换前检查', '' ], infoRows) ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ '' ]),
					E('div', { 'class': 'cbi-value-field' }, [
						button('切换（停服务 → 替换 → 重新生成并自检 → 启动）', 'cbi-button-apply', function() {
							doSwitch(state.selKernel, state.selVersion, target);
						}),
						' ',
						button('回滚到上一版本', 'cbi-button-reset', function() { doRollback(state.selKernel, ''); })
					])
				])
			]);
			add(boxSwitch, box);
			add(boxSwitch, hint('切换会先停止服务；若新内核配置未通过二进制自检（sing-box check / mihomo -t）或启动失败，会自动回到原内核、原配置并恢复原运行状态。'));
		}

		function doSwitch(kernel, tag, target) {
			if (state.busy) return;
			if (!tag) { ui.addNotification(null, E('p', {}, [ '请选择目标版本' ]), 'warning'); return; }
			target = target || installedList().filter(function(v) { return v.kernel === kernel && v.tag === tag; })[0];
			var ver = target ? target.version : tag;
			var lines = '目标：' + kernel + ' ' + ver + '\n架构：' + ((target && target.arch) || '?') + ' / 本机 ' + (state.st.arch || '?');
			if (kernel === 'singbox') {
				var b = K.bucketInfo(ver);
				lines += '\n配置模板：' + (b ? (K.bucketOf(ver) + '（' + b.range + '）') : '未适配版本');
			}
			var force = 0;
			var needsForce = false;
			if (kernel !== state.st.uci_kernel_norm && state.st.config_path) {
				var ext = state.st.config_path.toLowerCase();
				var okExt = (kernel === 'singbox') ? /\.json$/.test(ext) : /\.ya?ml$/.test(ext);
				needsForce = !okExt;
			}
			if (needsForce) {
				if (!confirm(lines + '\n\n自备配置格式与目标内核不匹配，是否强制切换？')) return;
				force = 1;
			} else if (!confirm(lines + '\n\n确定切换？服务会短暂中断。')) {
				return;
			}
			state.busy = true;
			K.callStart({ op: 'switch', kernel: kernel, version: tag, restart: 1, force: force })
				.then(function(r) {
					if (!r || !r.ok) throw new Error((r && r.error) || '启动失败');
					state.job = { phase: 'queued', message: '任务已提交', done: false };
					renderJob();
					startPoll();
				})
				.catch(function(e) { state.busy = false; ui.addNotification(null, E('p', {}, [ '' + e ]), 'danger'); });
		}

		function doRollback(kernel, tag) {
			if (state.busy) return;
			if (!confirm('回滚会把当前启用的版本替换为上一个版本，确定继续？')) return;
			state.busy = true;
			K.callStart({ op: 'rollback', kernel: kernel, version: tag || '', restart: 1 })
				.then(function(r) {
					if (!r || !r.ok) throw new Error((r && r.error) || '回滚失败');
					state.job = { phase: 'queued', message: '回滚任务已提交', done: false };
					renderJob(); startPoll();
				})
				.catch(function(e) { state.busy = false; ui.addNotification(null, E('p', {}, [ '' + e ]), 'danger'); });
		}

		function doRemove(kernel, tag) {
			if (state.busy) return;
			if (!confirm('卸载 ' + kernel + ' ' + tag + '？\n只删除该版本的内核文件，不会删除用户配置与规则。')) return;
			K.callRemove(kernel, tag).then(function(r) {
				if (!r || !r.ok) { ui.addNotification(null, E('p', {}, [ (r && r.error) || '卸载失败' ]), 'danger'); return; }
				ui.addNotification(null, E('p', {}, [ '已卸载 ' + tag ]), 'info');
				refreshStatus();
			});
		}

		function renderJob() {
			var j = state.job;
			clear(boxJob);
			if (!j) return;
			var stepPct = { queued: 10, download: 35, verify: 55, extract: 70, version: 75, install: 82, switch: 90 };
			var pct = j.done ? 100 : (stepPct[j.phase] || 10);
			var bytesTxt = '';
			if (j.phase === 'download' && !j.done) {
				var total = state.curSize || 0;
				bytesTxt = '，已下载 ' + K.fmtBytes(j.bytes || 0) + (total ? ' / ' + K.fmtBytes(total) : '');
				if (total > 0) pct = Math.min(54, 10 + Math.round(45 * Math.min(1, (j.bytes || 0) / total)));
			} else if (j.bytes) {
				bytesTxt = '，共 ' + K.fmtBytes(j.bytes);
			}
			add(boxJob, E('div', { 'class': 'cbi-progressbar', 'title': pct + '%' }, [
				E('div', { 'style': 'width:' + pct + '%' }, [ pct + '%' ])
			]));
			add(boxJob, E('p', {}, [ '阶段：' + (j.phase || '—') + '　' + (j.message || '') + bytesTxt ]));
			if (j.source)
				add(boxJob, E('p', { 'style': 'margin:0' }, [
					'下载源：' + j.source + (j.fallback ? '（已回退到 ' + j.source + ' 源）' : '')
				]));
			if (j.done) {
				if (j.ok)
					add(boxJob, info('完成：' + (j.message || '')));
				else {
					add(boxJob, warn('失败（' + (j.code || '') + '）：' + (j.message || '')));
					add(boxJob, hint('原因：' + K.errText(j.code)));
					if (state.lastInstall)
						add(boxJob, button('重试（沿用上次参数）', 'cbi-button-action', function() {
							startInstall(state.lastInstall);
						}));
				}
			}
		}

		function startPoll() {
			if (state.pollFn) return;
			state.busy = true;
			state.pollFn = function() {
				K.callJob().then(function(r) {
					var j = r && r.job;
					if (!j) return;
					state.job = j;
					renderJob();
					if (j.done) {
						state.busy = false;
						if (state.pollFn) { poll.remove(state.pollFn); state.pollFn = null; }
						refreshStatus();
					}
				}).catch(function(e) {
					state.pollErrs = (state.pollErrs || 0) + 1;
					if (state.pollErrs >= 3) {
						if (state.pollFn) { poll.remove(state.pollFn); state.pollFn = null; }
						state.busy = false;
						state.job = { phase: 'error', done: true,
							message: '任务状态读取失败：' + ((e && e.message) || e) };
						renderJob();
					}
				});
			};
			poll.add(state.pollFn, 1);
			state.pollFn();
		}

		function versionOfUrl(u) {
			var vs = state.versions || [];
			for (var i = 0; i < vs.length; i++)
				if (vs[i].url === u)
					return vs[i].version;
			return '';
		}

		function saveStoreDir() {
			var v = ((document.getElementById('k-store-dir') || {}).value || '').trim();
			K.callStoreSet(v).then(function(r) {
				if (!r || !r.ok) throw new Error((r && r.error) || '保存失败');
				state.st.kernel_dir = r.kernel_dir;
				state.st.store_persist = r.store_persist;
				state.st.store_device = r.store_device;
				state.st.free_kb = r.free_kb;
				state.st.keepd_installed = r.keepd_installed;
				state.st.kernel_dir_cfg = v;
				renderStatus();
				renderInstall();
				ui.addNotification(null, E('p', {}, [ '内核目录已切换为 ' + r.kernel_dir + '（' + storePersistText(r) + '）' ]), 'info');
			}).catch(function(e) {
				ui.addNotification(null, E('p', {}, [ '' + (e && e.message ? e.message : e) ]), 'danger');
			});
		}

		function renderInstall() {
			clear(boxInstall);
			var mirrors = state.mirrors ? state.mirrors.mirrors || [] : [];
			var srcSel = select(
				[ [ 'auto', '自动（按顺序回退：内置官方 + 加速镜像）', state.src === 'auto' ] ].concat(
					mirrors.filter(function(m) { return m.name !== 'custom' || m.prefix; }).map(function(m) {
						return [ m.name, m.label + (m.official ? '（官方）' : (m.enabled ? '' : '（未启用，手动选用）')),
							state.src === m.name ];
					})).concat([ [ '__custom', '自定义 URL / 本地文件', state.src === '__custom' ] ]),
				function(ev) {
					state.src = ev.target.value;
					renderInstall();
					// 选源持久化到 UCI（ferry.main.kernel_source），下次打开仍是该源
					if (state.src !== '__custom')
						K.callSourceSet(state.src).then(function() { refreshStatus(); }).catch(function() {});
				});

			var verSel = select(
				[ [ '', state.versions ? '— 选择版本 —'
					: (state.versionsLoading ? '（内置清单加载中…）'
					: (state.versionsErr ? '（清单加载失败，见下方错误）' : '（未加载，点“获取版本清单”）')), !state.selUrl ] ].concat(
					(state.versions || []).map(function(v) {
						return [ v.url, v.version + (v.prerelease ? '（预发布）' : '') + '  ' + v.asset
							+ (v.size ? '  ' + K.fmtBytes(v.size) : ''), state.selUrl === v.url ];
					})),
				function(ev) {
					state.selUrl = ev.target.value;
					var v = (state.versions || []).filter(function(x) { return x.url === state.selUrl; })[0];
					state.curSize = v ? (v.size || 0) : 0;
					// 内置清单自带官方 SHA-256：选中即填入，避免用户忘记校验
					var shaEl = document.getElementById('k-sha');
					if (shaEl && v && v.sha256) shaEl.value = v.sha256;
					renderInstall();
				});

			var customUrl = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': 'width:100%',
				'placeholder': 'https://…（完整 URL，必须是 HTTPS）', 'id': 'k-custom-url' });
			var localPath = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': 'width:100%',
				'placeholder': '/tmp/mihomo.gz 或 /tmp/sing-box.tar.gz（离线导入，绝对路径）', 'id': 'k-local-path' });
			var sha = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': 'width:100%',
				'placeholder': '期望 SHA-256（可选；留空则要求勾选未校验确认）', 'id': 'k-sha' });
			var allowUnver = E('input', { 'type': 'checkbox', 'id': 'k-allow-unverified' });
			var autoActivate = E('input', { 'type': 'checkbox', 'id': 'k-activate', 'checked': '' });
			var preBox = E('input', { 'type': 'checkbox', 'id': 'k-prerelease', 'checked': state.prerelease ? '' : null });
			preBox.addEventListener('change', function(ev) { state.prerelease = !!ev.target.checked; });

			var srcHint = '';
			if (state.src === 'auto') {
				var chain = (state.st && state.st.source_chain) || 'github ghfast ghproxy';
				srcHint = '按顺序自动回退：' + chain + '；失败会在任务里显示「已回退到 X 源」';
			} else if (state.src !== '__custom') {
				var sm = mirrors.filter(function(x) { return x.name === state.src; })[0];
				if (sm)
					srcHint = sm.official ? '官方 GitHub Release（https://github.com）'
						: ('前缀：' + (sm.prefix || '（未配置，将回落官方源）') + '；失败会自动回退到其余源');
			}

			var progress = E('div', { 'id': 'k-progress' });

			add(boxInstall, E('div', { 'class': 'cbi-section' }, [
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ '内核目录' ]),
					E('div', { 'class': 'cbi-value-field' }, [
						E('input', {
							'id': 'k-store-dir', 'type': 'text', 'class': 'cbi-input-text',
							'value': state.st.kernel_dir_cfg || '',
							'placeholder': state.st.kernel_dir || '/etc/ferry/kernels'
						}),
						' ',
						button('保存目录', 'cbi-button-action', saveStoreDir),
						E('div', { 'class': 'cbi-value-help' }, [
							'留空 = 插件默认 /etc/ferry/kernels（在 overlay 上，已用 keep.d 登记，sysupgrade 会打进备份）；'
							+ '外置存储请填已挂载目录，如 /mnt/sda1/ferry-kernels（不占 overlay，升级固件也不受影响）。'
							+ '当前：' + (state.st.kernel_dir || '/etc/ferry/kernels') + '，' + storePersistText(state.st)
						])
					])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ '下载源' ]),
					E('div', { 'class': 'cbi-value-field' }, [
						srcSel, ' ', button('刷新源列表', 'cbi-button-neutral', function() { loadMirrors(); }),
						srcHint ? E('div', { 'class': 'cbi-value-help' }, [ srcHint ]) : ''
					])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ '包含预发布' ]),
					E('div', { 'class': 'cbi-value-field' }, [
						preBox,
						' ',
						button('获取版本清单', 'cbi-button-action', function() {
							loadVersions();
						})
					])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ '在线安装' ]),
					E('div', { 'class': 'cbi-value-field' }, [
						verSel,
						' ',
						button('下载并安装', 'cbi-button-apply', function() {
							var u = (document.getElementById('k-custom-url') || {}).value || '';
							var vsel = u ? null : (state.versions || []).filter(function(v) { return v.url === state.selUrl; })[0];
							var urls = u || (vsel && vsel.url) || state.selUrl;
							var version = u ? 'custom-' + new Date().toISOString().replace(/[-:T.Z]/g, '').slice(0, 14)
								: (vsel ? vsel.version : '');
							if (!urls || !version) { ui.addNotification(null, E('p', {}, [ '请选择版本或填写自定义 URL' ]), 'warning'); return; }
							state.curSize = vsel ? (vsel.size || 0) : 0;
							startInstall({
								op: 'install', kernel: state.selKernel, version: version, urls: urls,
								sha256: (document.getElementById('k-sha') || {}).value || (vsel && vsel.sha256) || '',
								size: vsel ? (vsel.size || 0) : 0,
								mirror: (u ? 'github' : (state.src === '__custom' ? 'auto' : state.src)),
								allow_unverified: (document.getElementById('k-allow-unverified') || {}).checked ? 1 : 0,
								activate: (document.getElementById('k-activate') || {}).checked ? 1 : 0,
								restart: 1
							});
						})
					])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ '自定义 URL' ]),
					E('div', { 'class': 'cbi-value-field' }, [ customUrl ])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ '本地导入' ]),
					E('div', { 'class': 'cbi-value-field' }, [
						localPath,
						E('div', { 'class': 'cbi-value-help' }, [ '无外网时：先用 scp 把 .gz / .tar.gz 放到路由器（如 /tmp/），再填绝对路径。' ]),
						button('从本地文件安装', 'cbi-button-neutral', function() {
							var p = (document.getElementById('k-local-path') || {}).value || '';
							if (!/^\//.test(p)) { ui.addNotification(null, E('p', {}, [ '本地路径必须是绝对路径' ]), 'warning'); return; }
							var ver = p.replace(/^.*\//, '').replace(/\.(tar\.gz|tgz|gz|bin)$/i, '');
							startInstall({
								op: 'install-local', kernel: state.selKernel, version: ver, file: p,
								sha256: (document.getElementById('k-sha') || {}).value || '',
								allow_unverified: (document.getElementById('k-allow-unverified') || {}).checked ? 1 : 0,
								activate: (document.getElementById('k-activate') || {}).checked ? 1 : 0,
								restart: 1
							});
						})
					])
				]),
				E('div', { 'class': 'cbi-value' }, [
					E('label', { 'class': 'cbi-value-title' }, [ '安全选项' ]),
					E('div', { 'class': 'cbi-value-field' }, [
						E('label', {}, [ allowUnver, ' 允许未校验安装（官方未提供 checksum 时必须显式勾选）' ]),
						E('br'),
						E('label', {}, [ autoActivate, ' 安装后立即启用（会重启服务）' ])
					])
				]),
				progress
			]));
			add(boxInstall, hint('版本清单来自包内置清单（含官方 SHA-256 与大小，离线可用），生成日期 '
				+ ((state.versionsMeta && state.versionsMeta.generated) || '未知') + '。下载会按当前源顺序回退；'
				+ 'SHA-256 不匹配、架构不符、glibc 依赖、磁盘不足都会直接失败且不落位，旧版本保留可回滚。'
				+ ((state.versionsMeta && state.versionsMeta.unavailable)
					? '已隐藏 ' + state.versionsMeta.unavailable + ' 条源上不可用的资产（审计标记 dead，不展示以免点了才失败）。' : '')));
			if (state.versionsErr)
				add(boxInstall, E('div', { 'class': 'cbi-value' }, [
					E('div', { 'class': 'cbi-value-field' }, [
						warn('版本清单读取失败：' + state.versionsErr), ' ',
						button('重试', 'cbi-button-neutral', function() { loadVersions(); })
					])
				]));
		}

		// 所有后端调用都加 5s 上限：rpcd 未重载 / 后端异常时也必须落到错误态，
		// 不允许界面停在「加载中」（r10 起）。
		function rpcTimeout(p, ms, what) {
			return new Promise(function(resolve, reject) {
				var done = false;
				var timer = setTimeout(function() {
					if (done) return;
					done = true;
					reject(new Error(what + '超时（' + (ms / 1000) + 's 无响应）：后端未就绪或 rpcd 未重载，'
						+ '请执行 /etc/init.d/rpcd restart 后重试'));
				}, ms);
				p.then(function(v) { if (done) return; done = true; clearTimeout(timer); resolve(v); },
					function(e) { if (done) return; done = true; clearTimeout(timer); reject(e); });
			});
		}

		// 版本清单来自包内置清单：纯离线，必须与镜像源/网络状态无关
		function loadVersions(silent) {
			state.versionsErr = '';
			state.versionsLoading = true;
			if (!silent) ui.addNotification(null, E('p', {}, [ '正在读取 ' + state.selKernel + ' 版本清单…' ]), 'info');
			rpcTimeout(K.callVersions(state.selKernel, state.prerelease ? 1 : 0), 5000, '读取版本清单')
				.then(function(r) {
					if (!r || !r.ok) { state.versions = null; state.versionsErr = (r && r.error) || '获取失败'; }
					else {
						state.versions = r.versions || [];
						state.versionsErr = '';
						state.versionsMeta = { arch: r.arch, variants: r.variants, generated: r.generated, list: r.list,
							unavailable: r.unavailable || 0 };
						if (!state.selUrl && state.versions.length) {
							state.selUrl = state.versions[0].url;
							state.curSize = state.versions[0].size || 0;
						}
					}
				})
				.catch(function(e) { state.versions = null; state.versionsErr = (e && e.message) || ('' + e); })
				.then(function() { state.versionsLoading = false; renderInstall(); });
		}

		function startInstall(args) {
			if (state.busy) { ui.addNotification(null, E('p', {}, [ '已有任务在执行' ]), 'warning'); return; }
			state.lastInstall = args;
			state.busy = true;
			K.callStart(args).then(function(r) {
				if (!r || !r.ok) throw new Error((r && r.error) || '任务提交失败');
				state.job = { phase: 'queued', message: '任务已提交', done: false };
				renderJob(); startPoll();
			}).catch(function(e) { state.busy = false; ui.addNotification(null, E('p', {}, [ '' + e ]), 'danger'); });
		}

		function loadMirrors(cb) {
			state.mirrorsErr = '';
			rpcTimeout(K.callMirrors(), 5000, '读取镜像源')
				.then(function(r) {
					state.mirrors = (r && r.ok) ? r.mirrors : { mirrors: [] };
					if (r && !r.ok) state.mirrorsErr = r.error || '镜像源读取失败';
				})
				.catch(function(e) {
					state.mirrors = { mirrors: [] };
					state.mirrorsErr = (e && e.message) || ('' + e);
				})
				.then(function() { renderMirrors(); renderInstall(); if (cb) cb(); });
		}

		function renderMirrors() {
			clear(boxMirrors);
			var list = (state.mirrors && state.mirrors.mirrors) || [];
			var rows = list.map(function(m) {
				var prefix = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'style': 'width:60%',
					'value': m.prefix || '', 'data-name': m.name, 'placeholder': 'https://your-proxy/' });
				var enabled = E('input', { 'type': 'checkbox', 'data-en': m.name, 'checked': m.enabled ? '' : null });
				var testOut = E('span', {}, [ state.mirrorMsg && state.mirrorMsg[m.name] ?
					state.mirrorMsg[m.name].text : (m.official ? '官方源' : '未检测') ]);
				var testBtn = m.official ? null : button('检测', 'cbi-button-neutral', function() {
					if (!state.mirrorMsg) state.mirrorMsg = {};
					state.mirrorMsg[m.name] = { text: '检测中…' };
					renderMirrors();
					K.callMirrorTest(m.name).then(function(r) {
						state.mirrorMsg[m.name] = r && r.ok
							? { text: '可用，' + r.elapsed + 's / ' + K.fmtBytes(r.bytes) }
							: { text: '不可用（rc=' + ((r && r.rc) || '?') + '）' };
						renderMirrors();
					}).catch(function(e) {
						state.mirrorMsg[m.name] = { text: '检测失败：' + ((e && e.message) || e) };
						renderMirrors();
					});
				});
				return [ m.label || m.name, m.name, prefix, enabled, E('span', {}, [ testOut, ' ', testBtn || '' ]) ];
			});
			add(boxMirrors, table([ '名称', '标识', '前缀', '启用', '可用性' ], rows));
			if (state.mirrorsErr)
				add(boxMirrors, E('div', { 'class': 'cbi-value' }, [
					E('div', { 'class': 'cbi-value-field' }, [
						warn('镜像源读取失败：' + state.mirrorsErr), ' ',
						button('重试', 'cbi-button-neutral', function() { loadMirrors(); })
					])
				]));
			add(boxMirrors, E('div', { 'class': 'cbi-value' }, [
				E('div', { 'class': 'cbi-value-field' }, [
					button('保存镜像设置', 'cbi-button-apply', function() {
						var list2 = ((state.mirrors && state.mirrors.mirrors) || []).slice();
						Array.prototype.forEach.call(document.querySelectorAll('input[data-name]'), function(el) {
							var name = el.getAttribute('data-name');
							list2.forEach(function(m) { if (m.name === name) m.prefix = el.value; });
						});
						Array.prototype.forEach.call(document.querySelectorAll('input[data-en]'), function(el) {
							var name = el.getAttribute('data-en');
							list2.forEach(function(m) { if (m.name === name) m.enabled = el.checked; });
						});
						K.callMirrorSet(JSON.stringify({ mirrors: list2 })).then(function(r) {
							if (!r || !r.ok) { ui.addNotification(null, E('p', {}, [ (r && r.error) || '保存失败' ]), 'danger'); return; }
							ui.addNotification(null, E('p', {}, [ '镜像设置已保存' ]), 'info');
							loadMirrors();
						}).catch(function(e) {
							ui.addNotification(null, E('p', {}, [ '保存失败：' + ((e && e.message) || e) ]), 'danger');
						});
					}),
					' ',
					button('恢复默认', 'cbi-button-reset', function() {
						state.mirrors = null;
						loadMirrors();
					})
				])
			]));
			add(boxMirrors, hint('镜像只做传输加速（GitHub 前缀或 jsDelivr 映射），不改变校验策略：SHA-256 始终以官方值/官方侧车为准，镜像给错或给旧文件会被校验拦住。默认启用官方 + ghfast.top + ghproxy.net，失败按顺序自动回退。'));
		}

		function renderLicense() {
			return E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, [ '许可证与来源' ]),
				E('p', {}, [ '本页面只管理内核二进制，不随 luci-app-ferry 分发任何内核。mihomo 与 sing-box 均为 GPL-3.0 许可，请自行从其官方发布页下载并遵守其许可条款。' ]),
				E('p', {}, [ 'sing-box 配置模板按内核版本生成，支持矩阵：' + K.matrixText() + '。矩阵之外的版本会被拒绝切换。' ])
			]);
		}

		// 初始装配
		var root = E('div', {}, [
			E('h2', {}, [ 'Ferry 内核管理' ]),
			E('div', { 'class': 'cbi-section' }, [ E('h3', {}, [ '当前状态' ]), boxStatus ]),
			E('div', { 'class': 'cbi-section' }, [ E('h3', {}, [ '切换内核 / 版本' ]), boxSwitch ]),
			E('div', { 'class': 'cbi-section' }, [ E('h3', {}, [ '已安装版本' ]), boxInstalled ]),
			E('div', { 'class': 'cbi-section' }, [ E('h3', {}, [ '获取新版本' ]), boxInstall ]),
			E('div', { 'class': 'cbi-section' }, [ E('h3', {}, [ '镜像源（可选）' ]), boxMirrors ]),
			E('div', { 'class': 'cbi-section' }, [ E('h3', {}, [ '任务进度' ]), boxJob ]),
			renderLicense()
		]);

		renderStatus();
		renderSwitch();
		renderInstallTable();
		renderInstall();
		renderJob();
		// 内置版本清单必须离线可得；镜像源失败不能连坐版本列表
		loadVersions(true);
		loadMirrors();

		if (state.st.job && state.st.job.phase && !state.st.job.done)
			startPoll();

		return root;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
