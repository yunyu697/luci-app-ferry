'use strict';
/* Ferry 分享链接解析：vmess / vless / ss / ssr / trojan / hysteria2 / tuic
 * 输出统一内部结构，再由 store.js 编译成 nodes.lst，供 shell 映射到两种内核。 */

function b64d(s) {
	s = String(s == null ? '' : s)
		.replace(/-/g, '+').replace(/_/g, '/')
		.replace(/[\s]/g, '');
	while (s.length % 4)
		s += '=';
	var bin = atob(s);
	try {
		return decodeURIComponent(escape(bin));
	} catch (e) {
		return bin;
	}
}

function qs(str) {
	var out = {};
	(str || '').split('&').forEach(function(pair) {
		if (!pair)
			return;
		var i = pair.indexOf('=');
		var k = i < 0 ? pair : pair.slice(0, i);
		var v = i < 0 ? '' : pair.slice(i + 1);
		try { k = decodeURIComponent(k); } catch (e) {}
		try { v = decodeURIComponent(v); } catch (e) {}
		out[k] = v;
	});
	return out;
}

function frac(uri, scheme) {
	var body = uri.slice(scheme.length + 3);
	var name = '', query = '';
	var h = body.indexOf('#');
	if (h >= 0) { name = body.slice(h + 1); body = body.slice(0, h); }
	var q = body.indexOf('?');
	if (q >= 0) { query = body.slice(q + 1); body = body.slice(0, q); }
	var at = body.lastIndexOf('@');
	return {
		user: at < 0 ? '' : body.slice(0, at),
		hostport: at < 0 ? body : body.slice(at + 1),
		query: query,
		name: name
	};
}

function splitHostPort(hp, defPort) {
	var port = defPort || 0;
	var host = hp;
	var c = hp.lastIndexOf(':');
	if (c > 0) {
		host = hp.slice(0, c);
		port = parseInt(hp.slice(c + 1), 10) || defPort;
	}
	return { host: host, port: port };
}

function newNode(type, name, server, port) {
	return {
		id: '', type: type, name: name || '', enabled: true,
		server: server || '', port: port || 0,
		uuid: '', password: '', cipher: '', alterId: 0, scy: '', flow: '',
		network: 'tcp', path: '', host: '', serviceName: '',
		tls: false, sni: '', alpn: [], fingerprint: '',
		publicKey: '', shortId: '', insecure: false,
		plugin: '', pluginOpts: '',
		ssrProtocol: '', ssrObfs: '', ssrProtocolParam: '', ssrObfsParam: '',
		hyObfs: '', hyObfsPassword: '', hyUp: '', hyDown: '',
		tuicCC: '', tuicUdpMode: ''
	};
}

function splitList(v) {
	if (!v)
		return [];
	return String(v).split(',').map(function(s) { return s.trim(); }).filter(function(s) { return s; });
}

function applyTlsCommon(n, q) {
	n.tls = (q.security === 'tls' || q.security === 'reality' || q.tls === 'tls');
	n.sni = q.sni || q.host || '';
	n.fingerprint = q.fp || '';
	n.publicKey = q.pbk || '';
	n.shortId = q.sid || '';
	n.insecure = (q.allowInsecure === '1' || q.insecure === '1' || q.skip_cert_verify === '1');
	n.alpn = splitList(q.alpn);
}

function parseVmess(uri) {
	var j = JSON.parse(b64d(uri.slice('vmess://'.length)));
	var n = newNode('vmess', j.ps || j.remarks || '', j.add || '', parseInt(j.port, 10) || 0);
	n.uuid = j.id || '';
	n.alterId = parseInt(j.aid, 10) || 0;
	n.scy = j.scy || '';
	n.network = j.net || 'tcp';
	n.host = j.host || '';
	n.path = j.path || '';
	n.serviceName = (j.net === 'grpc') ? (j.path || '') : '';
	n.sni = j.sni || j.host || '';
	n.tls = (j.tls === 'tls' || j.tls === 'reality');
	n.fingerprint = j.fp || '';
	n.alpn = splitList(j.alpn);
	n.insecure = (j.allowInsecure === true || j.verify_cert === false);
	return n;
}

function parseVless(uri) {
	var p = frac(uri, 'vless');
	var hp = splitHostPort(p.hostport);
	var q = qs(p.query);
	var n = newNode('vless', p.name || '', hp.host, hp.port);
	n.uuid = p.user;
	n.flow = q.flow || '';
	n.network = q.type || 'tcp';
	n.path = q.path || '';
	n.host = q.host || '';
	n.serviceName = q.serviceName || '';
	applyTlsCommon(n, q);
	return n;
}

function parseTrojan(uri) {
	var p = frac(uri, 'trojan');
	var hp = splitHostPort(p.hostport);
	var q = qs(p.query);
	var n = newNode('trojan', p.name || '', hp.host, hp.port);
	n.password = p.user;
	n.network = q.type || 'tcp';
	n.path = q.path || '';
	n.host = q.host || '';
	n.serviceName = q.serviceName || '';
	applyTlsCommon(n, q);
	n.tls = true;
	return n;
}

function parseSS(uri) {
	var p = frac(uri, 'ss');
	var q = qs(p.query);
	var userinfo = p.user;
	var hostport = p.hostport;

	if (!userinfo) {
		// 旧格式：ss://BASE64(method:password@host:port)
		var dec = b64d(hostport);
		var at = dec.lastIndexOf('@');
		userinfo = at < 0 ? dec : dec.slice(0, at);
		hostport = at < 0 ? '' : dec.slice(at + 1);
	} else if (userinfo.indexOf(':') < 0) {
		// SIP002：ss://BASE64(method:password)@host:port
		userinfo = b64d(userinfo);
	}

	var hp = splitHostPort(hostport);
	var c = userinfo.indexOf(':');
	var n = newNode('ss', p.name || '', hp.host, hp.port);
	n.cipher = c < 0 ? userinfo : userinfo.slice(0, c);
	n.password = c < 0 ? '' : userinfo.slice(c + 1);

	if (q.plugin) {
		var parts = q.plugin.split(';');
		n.plugin = parts.shift();
		n.pluginOpts = parts.join(';');
	}
	return n;
}

function parseSSR(uri) {
	var dec = b64d(uri.slice('ssr://'.length));
	var params = '';
	var i = dec.indexOf('/?');
	if (i >= 0) {
		params = dec.slice(i + 2);
		dec = dec.slice(0, i);
	}
	var parts = dec.split(':');
	var host = parts[0] || '';
	var port = parseInt(parts[1], 10) || 0;
	var protocol = parts[2] || 'origin';
	var method = parts[3] || '';
	var obfs = parts[4] || 'plain';
	var pass = b64d(parts.slice(5).join(':'));
	var q = qs(params);
	var n = newNode('ssr', q.remarks ? b64d(q.remarks) : '', host, port);
	n.cipher = method;
	n.password = pass;
	n.ssrProtocol = protocol;
	n.ssrObfs = obfs;
	n.ssrProtocolParam = q.protoparam ? b64d(q.protoparam) : '';
	n.ssrObfsParam = q.obfsparam ? b64d(q.obfsparam) : '';
	return n;
}

function parseHysteria2(uri) {
	var scheme = uri.slice(0, uri.indexOf('://')).toLowerCase();
	var p = frac(uri, scheme);
	var hp = splitHostPort(p.hostport);
	var q = qs(p.query);
	var n = newNode('hysteria2', p.name || '', hp.host, hp.port);
	n.password = p.user;
	n.sni = q.sni || '';
	n.insecure = (q.insecure === '1');
	n.alpn = splitList(q.alpn);
	n.hyObfs = q.obfs || '';
	n.hyObfsPassword = q['obfs-password'] || '';
	n.tls = true;
	return n;
}

function parseTuic(uri) {
	var p = frac(uri, 'tuic');
	var hp = splitHostPort(p.hostport);
	var q = qs(p.query);
	var n = newNode('tuic', p.name || '', hp.host, hp.port);
	var u = p.user.indexOf(':');
	n.uuid = u < 0 ? p.user : p.user.slice(0, u);
	n.password = u < 0 ? '' : p.user.slice(u + 1);
	n.sni = q.sni || '';
	n.insecure = (q.allow_insecure === '1' || q.insecure === '1');
	n.alpn = splitList(q.alpn);
	n.tuicCC = q.congestion_control || '';
	n.tuicUdpMode = q.udp_relay_mode || '';
	n.tls = true;
	return n;
}

function parseOne(uri) {
	var u = String(uri || '').trim();
	if (!u)
		return null;
	var low = u.toLowerCase();
	try {
		if (low.indexOf('vmess://') === 0)
			return parseVmess(u);
		if (low.indexOf('vless://') === 0)
			return parseVless(u);
		if (low.indexOf('ssr://') === 0)
			return parseSSR(u);
		if (low.indexOf('ss://') === 0)
			return parseSS(u);
		if (low.indexOf('trojan://') === 0)
			return parseTrojan(u);
		if (low.indexOf('hysteria2://') === 0 || low.indexOf('hy2://') === 0)
			return parseHysteria2(u);
		if (low.indexOf('tuic://') === 0)
			return parseTuic(u);
	} catch (e) {
		throw new Error(shortUri(u) + ' 解析失败：' + e.message);
	}
	throw new Error('不支持的协议：' + shortUri(u));
}

function shortUri(u) {
	return u.length > 32 ? u.slice(0, 28) + '…' : u;
}

return {
	parseOne: parseOne,
	parse: function(text) {
		var nodes = [], errors = [];
		String(text || '').split(/\r?\n/).forEach(function(line) {
			var t = line.trim().replace(/^[\s"'<>]+|[\s"'>]+$/g, '');
			if (!t || t.indexOf('://') < 0)
				return;
			try {
				var n = parseOne(t);
				if (n)
					nodes.push(n);
			} catch (e) {
				errors.push(e.message);
			}
		});
		return { nodes: nodes, errors: errors };
	},
	b64d: b64d,
	tlsOf: function(n) {
		return n.tls || n.type === 'trojan' || n.type === 'hysteria2' || n.type === 'tuic';
	}
};
