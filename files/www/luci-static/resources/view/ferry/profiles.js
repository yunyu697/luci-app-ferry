'use strict';
'require view';
'require ui';
'require ferry.store as store';

function notify(msg, type) {
	if (typeof ui.addNotification === 'function')
		ui.addNotification(null, E('p', {}, msg), type || 'info');
	else
		window.alert(msg);
}

function fail(msg) {
	notify(msg, 'error');
}

// 较新的 LuCI 提供 ui.showModal；老版本没有该 API 时退化为内联区块，避免整页报错。
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

function askName(title, initial, onOk) {
	var inp = E('input', { type: 'text', class: 'cbi-input-text', value: initial || '' });
	openModal(title, E('div', { class: 'cbi-section' }, [
		E('div', { class: 'cbi-value' }, [
			E('label', { class: 'cbi-value-title' }, '名称'),
			inp
		])
	]), [
		{ label: '取消', class: 'cbi-button', callback: function() { return true; } },
		{ label: '确定', class: 'cbi-button cbi-button-apply', callback: function() {
			var v = String(inp.value || '').trim();
			if (!v) {
				fail('名称不能为空');
				return false;
			}
			onOk(v);
			return true;
		} }
	]);
}

function download(name, text, type) {
	try {
		var blob = new Blob([ text ], { type: type || 'application/json' });
		var url = URL.createObjectURL(blob);
		var a = document.createElement('a');
		a.href = url;
		a.download = name;
		document.body.appendChild(a);
		a.click();
		document.body.removeChild(a);
		URL.revokeObjectURL(url);
	} catch (e) {
		fail('浏览器不支持直接下载：' + e.message);
	}
}

return view.extend({
	load: function() {
		return Promise.all([
			store.ensureDb(),
			store.activeProfile().catch(function() { return { profile: null }; })
		]);
	},

	render: function(data) {
		var self = this;
		this.db = data[0] || { active: '', profiles: [] };
		this.active = this.db.active;

		var tbody = E('div', {}, []);

		function refresh() {
			var rows = (self.db.profiles || []).map(function(p) {
				var isActive = p.id === self.active;
				return E('tr', {}, [
					E('td', {}, isActive ? '● 激活' : ''),
					E('td', {}, [ E('strong', {}, p.name || p.id), E('div', { class: 'cbi-section-descr' }, p.id) ]),
					E('td', {}, p.deploy || 'router'),
					E('td', {}, p.kernel || 'mihomo'),
					E('td', {}, p.mode || 'tproxy'),
					E('td', {}, String((p.nodes || []).length)),
					E('td', {}, p.updated || '-'),
					E('td', { class: 'cbi-button-cell' }, [
						isActive
							? E('span', { class: 'cbi-section-descr' }, '当前激活')
							: E('button', { class: 'cbi-button cbi-button-apply', click: function() {
								notify('正在切换配置档案…');
								store.activate(p.id).then(function() {
									notify('已切换到「' + (p.name || p.id) + '」并 reload');
									window.setTimeout(function() { location.reload(); }, 600);
								}).catch(function(e) { fail('切换失败：' + e.message); });
							} }, '激活'),
						E('button', { class: 'cbi-button', click: function() {
							askName('重命名配置档案', p.name, function(name) {
								store.renameProfile(p.id, name).then(function() {
									p.name = name;
									notify('已重命名');
									window.setTimeout(function() { location.reload(); }, 400);
								}).catch(function(e) { fail('重命名失败：' + e.message); });
							});
						} }, '重命名'),
						E('button', { class: 'cbi-button', click: function() {
							store.copyProfile(p.id).then(function(cp) {
								self.db.profiles.push(cp);
								refresh();
								notify('已复制为「' + cp.name + '」');
							}).catch(function(e) { fail('复制失败：' + e.message); });
						} }, '复制'),
						E('button', { class: 'cbi-button', click: function() {
							store.exportProfile(p.id).then(function(text) {
								download('ferry-' + p.id + '.json', text);
								notify('已导出配置文件（包含节点与规则）');
							}).catch(function(e) { fail('导出失败：' + e.message); });
						} }, '导出'),
						isActive
							? E('button', { class: 'cbi-button', disabled: true }, '删除')
							: E('button', { class: 'cbi-button cbi-button-reset', click: function() {
								if (!window.confirm('删除配置档案「' + (p.name || p.id) + '」？节点不会从全局节点库删除。'))
									return;
								store.removeProfile(p.id).then(function() {
									self.db.profiles = self.db.profiles.filter(function(x) { return x.id !== p.id; });
									refresh();
									notify('已删除');
								}).catch(function(e) { fail('删除失败：' + e.message); });
							} }, '删除')
					])
				]);
			});
			while (tbody.firstChild)
				tbody.removeChild(tbody.firstChild);
			tbody.appendChild(E('table', { class: 'cbi-section-table' }, [
				E('tr', { class: 'cbi-section-table-titles' }, [
					E('th', {}, '状态'), E('th', {}, '名称'), E('th', {}, '部署'),
					E('th', {}, '内核'), E('th', {}, '模式'), E('th', {}, '节点'),
					E('th', {}, '更新时间'), E('th', {}, '操作')
				])
			].concat(rows)));
		}
		refresh();

		var importBox = E('textarea', { class: 'cbi-input-textarea', rows: 4, style: 'width:100%',
			placeholder: '粘贴通过「导出」得到的 JSON' });

		var fileInput = E('input', { type: 'file', accept: '.json,application/json' });
		fileInput.addEventListener('change', function() {
			var f = fileInput.files && fileInput.files[0];
			if (!f)
				return;
			var fr = new FileReader();
			fr.onload = function() { importBox.value = String(fr.result || ''); };
			fr.readAsText(f);
		});

		return E('div', {}, [
			E('h2', {}, '配置档案'),
			E('p', { class: 'cbi-section-descr' },
				'每个档案保存部署形态、内核、运行模式、节点集合、规则与预设。任意时刻只有一个档案处于激活状态；' +
				'激活项写入 UCI（profile）与 /etc/ferry/profiles.json，重启后保持。'),

			E('div', { class: 'cbi-section' }, [ E('h3', {}, '档案列表'), tbody ]),

			E('div', { class: 'cbi-button-row' }, [
				E('button', { class: 'cbi-button cbi-button-apply', click: function() {
					askName('新建配置档案', '配置 ' + (self.db.profiles.length + 1), function(name) {
						store.createProfile(name).then(function(p) {
							self.db.profiles.push(p);
							refresh();
							notify('已创建「' + p.name + '」，可切换到该档案后再编辑');
						}).catch(function(e) { fail('创建失败：' + e.message); });
					});
				} }, '新建（复制当前档案）')
			]),

			E('div', { class: 'cbi-section' }, [
				E('h3', {}, '导入配置档案'),
				E('p', { class: 'cbi-section-descr' }, '导入会追加为新档案（不会覆盖现有档案），其中的节点会合并进全局节点库。'),
				E('div', { class: 'cbi-value' }, [
					E('label', { class: 'cbi-value-title' }, '选择文件'),
					E('div', { class: 'cbi-value-field' }, [ fileInput ])
				]),
				importBox,
				E('div', { class: 'cbi-button-row' }, [
					E('button', { class: 'cbi-button cbi-button-apply', click: function() {
						var text = String(importBox.value || '').trim();
						if (!text) {
							fail('请先选择文件或粘贴 JSON');
							return;
						}
						store.importProfile(text).then(function(p) {
							self.db.profiles.push(p);
							refresh();
							importBox.value = '';
							notify('已导入「' + p.name + '」');
						}).catch(function(e) { fail('导入失败：' + e.message); });
					} }, '导入')
				])
			])
		]);
	}
});
