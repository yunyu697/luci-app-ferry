'use strict';
'require baseclass';
'require fs';
'require uci';
'require rpc';
'require ferry.preset-defs as presets';

var NODES_FILE    = '/etc/ferry/nodes.json';
var PROFILES_FILE = '/etc/ferry/profiles.json';
var NODES_LST     = '/etc/ferry/nodes.lst';
var RULES_LST     = '/etc/ferry/rules.lst';
var CUSTOM_LST    = '/etc/ferry/custom.lst';
var STATUS_FILE   = '/etc/ferry/status.json';

var callReload = rpc.declare({
	object: 'service', method: 'reload', params: [ 'name' ]
});

var UCI_FIELDS = [
	'deploy', 'kernel', 'mode', 'proxy_port', 'mixed_port', 'dns_port',
	'hijack_dns', 'router_dns', 'dns_mode', 'log_level', 'enable_ipv6',
	'block_quic', 'tun_stack', 'firewall_backend', 'final_policy',
	'rule_mirror', 'rule_mirror_custom', 'rule_mirror_backup', 'rule_update',
	'sub_url', 'config_path', 'bin_path',
	'lan_iface', 'bypass_cidr', 'bypass_ip'
];

function nowIso() {
	return new Date().toISOString().replace(/\.\d+Z$/, 'Z');
}

/* ---------------- 配置加载（uci） ----------------
   导航打断（XHR abort / 页面切换）与真实失败的区分：
   - AbortError，或消息含 ERR_ABORTED / aborted / cancelled / Failed to fetch → 中断
   - 其余（RPC 返回错误、超时、权限）→ 真实失败
   真实失败先等 600ms 再重试一次，避免把切换瞬间的中断误报为错误。 */
function isInterruption(err) {
	var name = err && err.name ? String(err.name) : '';
	var msg = err && err.message ? String(err.message) : String(err || '');
	return name === 'AbortError' ||
		/ERR_ABORTED|aborted|cancelled|canceled|Failed to fetch/i.test(msg);
}

function loadConfig() {
	return uci.load('ferry').then(function() {
		return { ok: true, interrupted: false };
	}).catch(function(err) {
		if (isInterruption(err))
			return { ok: false, interrupted: true, error: err };
		return new Promise(function(resolve) {
			setTimeout(function() {
				uci.load('ferry').then(function() {
					resolve({ ok: true, interrupted: false });
				}, function(err2) {
					resolve({
						ok: false,
						interrupted: isInterruption(err2),
						error: err2
					});
				});
			}, 600);
		});
	});
}

function esc(v) {
	return String(v == null ? '' : v)
		.replace(/\\/g, '\\\\')
		.replace(/"/g, '\\"')
		.replace(/\r?\n/g, ' ');
}

function readText(path) {
	return fs.read(path).catch(function() { return ''; });
}

function readJson(path, fallback) {
	return readText(path).then(function(txt) {
		if (!txt)
			return fallback;
		try {
			return JSON.parse(txt);
		} catch (e) {
			return fallback;
		}
	});
}

function writeJson(path, obj) {
	return fs.write(path, JSON.stringify(obj, null, 2) + '\n');
}

/* ---------------- 节点 ---------------- */

function loadNodes() {
	return readJson(NODES_FILE, { version: 1, nodes: [] }).then(function(db) {
		if (!db || !Array.isArray(db.nodes))
			db = { version: 1, nodes: [] };
		return db.nodes;
	});
}

function saveNodes(nodes) {
	var seenIds = {}, seenNames = {}, i = 0;
	nodes = (nodes || []).map(function(n) {
		var copy = JSON.parse(JSON.stringify(n));
		do {
			if (!copy.id || seenIds[copy.id])
				copy.id = 'n' + Date.now().toString(36) + '-' + (i + 1);
		} while (seenIds[copy.id]);
		seenIds[copy.id] = 1;
		i++;
		return copy;
	});

	nodes.forEach(function(n) {
		var base = String(n.name || '').trim() || (n.type + '-' + n.server);
		var name = base, k = 2;
		while (seenNames[name])
			name = base + '-' + (k++);
		seenNames[name] = 1;
		n.name = name;
	});

	return writeJson(NODES_FILE, { version: 1, nodes: nodes }).then(function() {
		return nodes;
	});
}

/* ---------------- profile ---------------- */

function uciSnapshot(id, name) {
	var p = { id: id, name: name, preset: 'daily', nodes: [], rules: presets.buildRules('daily'),
		custom_domains: [], custom_cidrs: [], updated: nowIso() };
	UCI_FIELDS.forEach(function(f) {
		var v = uci.get('ferry', 'main', f, null);
		if (v != null)
			p[f] = v;
	});
	p.deploy = p.deploy || 'router';
	p.kernel = p.kernel || 'mihomo';
	p.mode = p.mode || 'tproxy';
	p.final_policy = p.final_policy || 'proxy';
	return p;
}

function ensureDb() {
	return readJson(PROFILES_FILE, null).then(function(db) {
		if (db && Array.isArray(db.profiles) && db.profiles.length) {
			if (!db.active || !findProfile(db, db.active))
				db.active = db.profiles[0].id;
			return db;
		}
		return uci.load('ferry').catch(function() { return null; }).then(function() {
			var p = uciSnapshot('default', '默认');
			var ndb = { version: 1, active: 'default', profiles: [ p ] };
			return writeJson(PROFILES_FILE, ndb).then(function() { return ndb; });
		});
	});
}

function findProfile(db, id) {
	for (var i = 0; i < db.profiles.length; i++)
		if (db.profiles[i].id === id)
			return db.profiles[i];
	return null;
}

function activeProfile() {
	return ensureDb().then(function(db) {
		return { db: db, profile: findProfile(db, db.active) };
	});
}

function saveDb(db) {
	return writeJson(PROFILES_FILE, db);
}

function pushToUci(p) {
	UCI_FIELDS.forEach(function(f) {
		/* 空字符串也要写，否则「无备用源」「留空 bin_path」这类设置会被旧值覆盖 */
		if (p[f] == null)
			return;
		/* bypass_cidr / bypass_ip 是 UCI list，uci.get 返回数组，原样写回 */
		uci.set('ferry', 'main', f, Array.isArray(p[f]) ? p[f] : String(p[f]));
	});
}

/* 用当前 UCI 刷新 profile 快照里的标量字段，避免在基础设置页改过的值被规则/部署页回写覆盖 */
function syncUci(p) {
	UCI_FIELDS.forEach(function(f) {
		var v = uci.get('ferry', 'main', f, null);
		if (v != null)
			p[f] = v;
	});
	return p;
}

/* ---------------- 编译：JSON -> shell 可读的平面文件 ---------------- */

function nodeBlock(n) {
	var L = [ 'BEGIN' ];
	L.push('name=' + esc(n.name));
	L.push('type=' + esc(n.type));
	L.push('enabled=' + (n.enabled ? 1 : 0));
	L.push('server=' + esc(n.server));
	L.push('port=' + (parseInt(n.port, 10) || 0));
	L.push('uuid=' + esc(n.uuid));
	L.push('password=' + esc(n.password));
	L.push('cipher=' + esc(n.cipher));
	L.push('alter_id=' + (parseInt(n.alterId, 10) || 0));
	L.push('scy=' + esc(n.scy));
	L.push('flow=' + esc(n.flow));
	L.push('network=' + esc(n.network || 'tcp'));
	L.push('path=' + esc(n.path));
	L.push('host=' + esc(n.host));
	L.push('service_name=' + esc(n.serviceName));
	L.push('tls=' + (n.tls ? 1 : 0));
	L.push('sni=' + esc(n.sni));
	L.push('alpn=' + esc((n.alpn || []).join(',')));
	L.push('fingerprint=' + esc(n.fingerprint));
	L.push('public_key=' + esc(n.publicKey));
	L.push('short_id=' + esc(n.shortId));
	L.push('insecure=' + (n.insecure ? 1 : 0));
	L.push('plugin=' + esc(n.plugin));
	L.push('plugin_opts=' + esc(n.pluginOpts));
	L.push('ssr_protocol=' + esc(n.ssrProtocol));
	L.push('ssr_obfs=' + esc(n.ssrObfs));
	L.push('ssr_protocol_param=' + esc(n.ssrProtocolParam));
	L.push('ssr_obfs_param=' + esc(n.ssrObfsParam));
	L.push('hy_obfs=' + esc(n.hyObfs));
	L.push('hy_obfs_password=' + esc(n.hyObfsPassword));
	L.push('hy_up=' + esc(n.hyUp));
	L.push('hy_down=' + esc(n.hyDown));
	L.push('tuic_cc=' + esc(n.tuicCC));
	L.push('tuic_udp=' + esc(n.tuicUdpMode));
	L.push('END');
	return L.join('\n') + '\n';
}

function rulesText(p) {
	var rules = (p.rules && p.rules.length) ? p.rules : presets.buildRules(p.preset || 'daily');
	var lines = rules.filter(function(r) {
		return r.enabled !== false && r.target && r.cat;
	}).map(function(r) {
		return r.cat + ' ' + r.target;
	});
	return lines.join('\n') + (lines.length ? '\n' : '');
}

function customText(p) {
	var out = [];
	(p.custom_domains || []).forEach(function(d) {
		d = String(d || '').trim();
		if (!d)
			return;
		if (d.indexOf('full:') === 0)
			out.push('domain ' + d.slice(5).trim());
		else
			out.push('suffix ' + d.replace(/^\*?\.?/, ''));
	});
	(p.custom_cidrs || []).forEach(function(c) {
		c = String(c || '').trim();
		if (!c)
			return;
		out.push((c.indexOf(':') >= 0 ? 'ip6 ' : 'ip ') + c);
	});
	return out.join('\n') + (out.length ? '\n' : '');
}

function compile(p) {
	return loadNodes().then(function(nodes) {
		var ids = p.nodes || [];
		var chosen = nodes.filter(function(n) {
			return ids.indexOf(n.id) >= 0;
		});
		if (ids.length === 0)
			chosen = [];
		return fs.write(NODES_LST, chosen.map(nodeBlock).join(''))
			.then(function() { return fs.write(RULES_LST, rulesText(p)); })
			.then(function() { return fs.write(CUSTOM_LST, customText(p)); });
	});
}

/* ---------------- 激活 / 切换 ---------------- */

function reloadService() {
	return fs.exec('/etc/init.d/ferry', [ 'reload' ]).then(function(res) {
		if (res && res.code)
			return callReload('ferry');
		return res;
	}).catch(function() {
		return callReload('ferry').catch(function() { return null; });
	});
}

function activate(id) {
	return ensureDb().then(function(db) {
		var p = findProfile(db, id);
		if (!p)
			throw new Error('配置档案不存在：' + id);
		db.active = id;
		p.updated = nowIso();
		return uci.load('ferry').then(function() {
			pushToUci(p);
			uci.set('ferry', 'main', 'profile', id);
			return uci.save();
		}).then(function() {
			return saveDb(db);
		}).then(function() {
			return compile(p);
		}).then(function() {
			return reloadService();
		});
	});
}

function saveActiveProfile(p) {
	return ensureDb().then(function(db) {
		var cur = findProfile(db, db.active);
		if (!cur)
			throw new Error('当前没有激活的配置档案');
		Object.keys(p).forEach(function(k) {
			if (k !== 'id')
				cur[k] = p[k];
		});
		cur.updated = nowIso();
		return uci.load('ferry').then(function() {
			pushToUci(cur);
			return uci.save();
		}).then(function() {
			return saveDb(db);
		}).then(function() {
			return compile(cur);
		}).then(function() {
			return reloadService();
		});
	});
}

/* 节点页保存后调用：把全量节点 id 写进当前激活档案，不触碰 UCI 标量字段 */
function setActiveNodes(ids) {
	return ensureDb().then(function(db) {
		var cur = findProfile(db, db.active);
		if (!cur)
			throw new Error('当前没有激活的配置档案');
		cur.nodes = (ids || []).slice();
		cur.updated = nowIso();
		return saveDb(db).then(function() {
			return compile(cur);
		}).then(function() {
			return reloadService();
		}).then(function() {
			return cur;
		});
	});
}

function applyPreset(presetId) {
	var preset = presets.findPreset(presetId);
	if (!preset)
		return Promise.reject(new Error('未知预设：' + presetId));
	return activeProfile().then(function(r) {
		return uci.load('ferry').catch(function() { return null; }).then(function() {
			var p = { };
			Object.keys(r.profile).forEach(function(k) { p[k] = r.profile[k]; });
			syncUci(p);
			p.preset = presetId;
			p.rules = presets.buildRules(presetId);
			p.mode = preset.mode;
			p.deploy = preset.deploy;
			p.final_policy = preset.final;
			return saveActiveProfile(p);
		});
	});
}

/* ---------------- profile CRUD ---------------- */

function newId(db) {
	var n = 1;
	while (db.profiles.some(function(p) { return p.id === 'p' + n; }))
		n++;
	return 'p' + n;
}

function createProfile(name) {
	return ensureDb().then(function(db) {
		return activeProfile().then(function(r) {
			var src = r.profile;
			var p = JSON.parse(JSON.stringify(src));
			p.id = newId(db);
			p.name = name || ('配置 ' + p.id);
			p.updated = nowIso();
			db.profiles.push(p);
			return saveDb(db).then(function() { return p; });
		});
	});
}

function copyProfile(id, name) {
	return ensureDb().then(function(db) {
		var src = findProfile(db, id);
		if (!src)
			throw new Error('配置档案不存在：' + id);
		var p = JSON.parse(JSON.stringify(src));
		p.id = newId(db);
		p.name = name || (src.name + ' 副本');
		p.updated = nowIso();
		db.profiles.push(p);
		return saveDb(db).then(function() { return p; });
	});
}

function renameProfile(id, name) {
	return ensureDb().then(function(db) {
		var p = findProfile(db, id);
		if (!p)
			throw new Error('配置档案不存在：' + id);
		p.name = String(name || '').trim() || p.name;
		p.updated = nowIso();
		if (db.active === id) {
			return uci.load('ferry').then(function() {
				uci.set('ferry', 'main', 'profile', id);
				return uci.save();
			}).then(function() { return saveDb(db); });
		}
		return saveDb(db);
	});
}

function removeProfile(id) {
	return ensureDb().then(function(db) {
		if (db.active === id)
			throw new Error('不能删除当前激活的配置档案，请先切换到其他档案');
		if (db.profiles.length <= 1)
			throw new Error('至少保留一个配置档案');
		db.profiles = db.profiles.filter(function(p) { return p.id !== id; });
		return saveDb(db);
	});
}

function importProfile(text) {
	var obj;
	try {
		obj = JSON.parse(text);
	} catch (e) {
		return Promise.reject(new Error('JSON 解析失败：' + e.message));
	}
	if (!obj || !obj.profile || !obj.profile.kernel || !obj.profile.mode)
		return Promise.reject(new Error('不是有效的 Ferry 配置档案'));
	var prof = obj.profile;
	var incoming = Array.isArray(obj.profile_nodes) ? obj.profile_nodes : [];

	return ensureDb().then(function(db) {
		return loadNodes().then(function(existing) {
			var idMap = {}, merged = existing.slice();
			incoming.forEach(function(n) {
				var copy = JSON.parse(JSON.stringify(n));
				copy.id = '';
				merged.push(copy);
			});
			return saveNodes(merged).then(function(saved) {
				var fresh = saved.slice(existing.length);
				incoming.forEach(function(n, i) {
					if (fresh[i] && n.id)
						idMap[n.id] = fresh[i].id;
				});
				prof.id = newId(db);
				prof.name = (prof.name || '导入配置') + ' (导入)';
				prof.nodes = (prof.nodes || []).map(function(id) {
					return idMap[id] || id;
				}).filter(function(id) { return !!id; });
				prof.updated = nowIso();
				db.profiles.push(prof);
				return saveDb(db).then(function() { return prof; });
			});
		});
	});
}

function exportProfile(id) {
	return ensureDb().then(function(db) {
		var p = findProfile(db, id);
		if (!p)
			throw new Error('配置档案不存在：' + id);
		var nodes = null;
		return loadNodes().then(function(all) {
			nodes = all.filter(function(n) { return (p.nodes || []).indexOf(n.id) >= 0; });
			return JSON.stringify({
				version: 1, exported: nowIso(), profile: p,
				profile_nodes: nodes
			}, null, 2) + '\n';
		});
	});
}

function status() {
	return readJson(STATUS_FILE, null);
}

function readKernelConfig() {
	return uci.load('ferry').catch(function() { return null; }).then(function() {
		var kernel = uci.get('ferry', 'main', 'kernel', 'mihomo');
		var custom = uci.get('ferry', 'main', 'config_path', '');
		var path = custom || (kernel === 'singbox' ? '/etc/sing-box/config.json' : '/etc/mihomo/config.yaml');
		return readText(path).then(function(txt) {
			return { path: path, text: txt };
		});
	});
}

return baseclass.extend({
	files: {
		nodes: NODES_FILE, profiles: PROFILES_FILE, status: STATUS_FILE
	},
	loadNodes: loadNodes,
	saveNodes: saveNodes,
	ensureDb: ensureDb,
	activeProfile: activeProfile,
	activate: activate,
	saveActiveProfile: saveActiveProfile,
	setActiveNodes: setActiveNodes,
	syncUci: syncUci,
	applyPreset: applyPreset,
	createProfile: createProfile,
	copyProfile: copyProfile,
	renameProfile: renameProfile,
	removeProfile: removeProfile,
	importProfile: importProfile,
	exportProfile: exportProfile,
	compile: compile,
	reloadService: reloadService,
	status: status,
	readKernelConfig: readKernelConfig,
	loadConfig: loadConfig,
	esc: esc
});
