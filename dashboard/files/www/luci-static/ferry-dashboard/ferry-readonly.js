/*
 * Ferry 只读面板 shim（zashboard 3.22.0 一次性补丁）
 *
 * 必须在 zashboard 主 bundle 之前执行（见 dashboard/patches/zashboard-3.22.0-readonly.patch）。
 * 作用：
 *   1) 拦截所有写请求：只放行 GET/HEAD/OPTIONS 与「切换节点」PUT /proxies/{group}；
 *      其余 PUT/PATCH/POST/DELETE 一律返回 403 并提示，避免与 ferry 的配置/内核管理双写冲突。
 *   2) WebSocket 只放行读取类端点（/traffic /logs /memory /connections）。
 *   3) 顶部横幅说明只读范围；sing-box 后端额外说明能力缺失（规则/配置/延迟明细/重启升级）。
 * 不修改 zashboard 的 JS/CSS，升级或回退时只需移除 index.html 里的一行 script。
 */
(function() {
	'use strict';

	var qs = new URLSearchParams(window.location.search || '');
	var type = (qs.get('type') || '').toLowerCase();
	var kernel = (qs.get('kernel') || '').toLowerCase();
	var sb = type === 'singbox' || kernel === 'singbox';
	var host = qs.get('hostname') || window.location.hostname;
	var port = qs.get('port') || '9090';
	var origins = [
		'http://' + host + ':' + port,
		'https://' + host + ':' + port,
		'ws://' + host + ':' + port,
		'wss://' + host + ':' + port
	];

	var WRITE_MSG = 'Ferry 只读面板：配置/重载/重启/升级/订阅更新已禁用';

	function sameApi(url) {
		try {
			var u = new URL(url, window.location.href);
			return origins.indexOf(u.origin) >= 0 ? u : null;
		} catch (e) {
			return null;
		}
	}

	function apiPath(url) {
		var u = sameApi(url);
		return u ? u.pathname : null;
	}

	function methodOf(input, init) {
		var m = (init && init.method) || (input && input.method) || 'GET';
		return String(m).toUpperCase();
	}

	// 只放行「切换某个代理组的当前节点」；其余写操作全部拒绝。
	function isAllowedWrite(method, path) {
		return method === 'PUT' && /^\/proxies\/[^/]+\/?$/.test(path);
	}

	function isAllowed(method, path) {
		if (method === 'GET' || method === 'HEAD' || method === 'OPTIONS')
			return true;
		return isAllowedWrite(method, path);
	}

	var toastTimer = null;
	function toast(msg) {
		var el = document.getElementById('ferry-ro-toast');
		if (!el) {
			el = document.createElement('div');
			el.id = 'ferry-ro-toast';
			el.style.cssText = 'position:fixed;left:50%;bottom:64px;transform:translateX(-50%);' +
				'z-index:2147483000;max-width:86vw;background:rgba(190,30,30,.96);color:#fff;' +
				'font:13px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif;' +
				'padding:10px 16px;border-radius:10px;box-shadow:0 6px 24px rgba(0,0,0,.35);';
			document.body.appendChild(el);
		}
		el.textContent = msg;
		el.style.display = 'block';
		if (toastTimer) clearTimeout(toastTimer);
		toastTimer = setTimeout(function() { el.style.display = 'none'; }, 5000);
	}

	function blockResponse(method, path) {
		return new Response(JSON.stringify({
			message: 'Ferry 只读面板已阻止写入：' + method + ' ' + path
		}), {
			status: 403,
			headers: { 'Content-Type': 'application/json' }
		});
	}

	// ---- fetch ----
	if (window.fetch) {
		var _fetch = window.fetch;
		window.fetch = function(input, init) {
			var url = (typeof input === 'string') ? input : (input && input.url);
			var path = url ? apiPath(url) : null;
			var method = methodOf(input, init);
			if (path && !isAllowed(method, path)) {
				toast(WRITE_MSG);
				return Promise.resolve(blockResponse(method, path));
			}
			return _fetch.apply(this, arguments);
		};
	}

	// ---- XMLHttpRequest（axios 默认适配器）----
	if (window.XMLHttpRequest) {
		var _open = XMLHttpRequest.prototype.open;
		var _send = XMLHttpRequest.prototype.send;
		XMLHttpRequest.prototype.open = function(method, url) {
			this.__ferry_req = { method: String(method || 'GET').toUpperCase(), url: url };
			return _open.apply(this, arguments);
		};
		XMLHttpRequest.prototype.send = function() {
			var req = this.__ferry_req;
			var path = req && req.url ? apiPath(req.url) : null;
			if (path && !isAllowed(req.method, path)) {
				var self = this;
				toast(WRITE_MSG);
				try {
					var body = JSON.stringify({ message: 'Ferry 只读面板已阻止写入：' + req.method + ' ' + path });
					Object.defineProperty(self, 'readyState', { value: 4, configurable: true });
					Object.defineProperty(self, 'status', { value: 403, configurable: true });
					Object.defineProperty(self, 'statusText', { value: 'Forbidden', configurable: true });
					Object.defineProperty(self, 'responseText', { value: body, configurable: true });
					Object.defineProperty(self, 'response', { value: body, configurable: true });
					setTimeout(function() {
						self.dispatchEvent(new Event('readystatechange'));
						self.dispatchEvent(new Event('load'));
						self.dispatchEvent(new Event('loadend'));
					}, 0);
				} catch (e) {
					try { self.abort(); } catch (_) {}
				}
				return;
			}
			return _send.apply(this, arguments);
		};
	}

	// ---- WebSocket：只允许读取类端点 ----
	if (window.WebSocket) {
		var _WS = window.WebSocket;
		var WS_OK = /^\/(traffic|logs|memory|connections)(\/)?$/;
		function StubWS(url) {
			this.url = String(url);
			this.readyState = 3;
			this.onopen = null;
			this.onmessage = null;
			this.onerror = null;
			this.onclose = null;
		}
		StubWS.prototype.addEventListener = function() {};
		StubWS.prototype.removeEventListener = function() {};
		StubWS.prototype.close = function() {};
		StubWS.prototype.send = function() {};
		function FerryWebSocket(url, protocols) {
			var path = apiPath(url);
			if (path && !WS_OK.test(path)) {
				toast(WRITE_MSG);
				return new StubWS(url);
			}
			return new _WS(url, protocols);
		}
		FerryWebSocket.prototype = _WS.prototype;
		FerryWebSocket.CONNECTING = 0;
		FerryWebSocket.OPEN = 1;
		FerryWebSocket.CLOSING = 2;
		FerryWebSocket.CLOSED = 3;
		window.WebSocket = FerryWebSocket;
	}

	// ---- 顶部横幅 ----
	function banner() {
		if (document.getElementById('ferry-ro-banner')) return;
		var el = document.createElement('div');
		el.id = 'ferry-ro-banner';
		el.style.cssText = 'position:fixed;top:8px;left:50%;transform:translateX(-50%);z-index:2147483000;' +
			'background:rgba(20,20,24,.86);color:#f5f5f5;border-radius:10px;padding:6px 14px;' +
			'font:12px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif;' +
			'box-shadow:0 4px 18px rgba(0,0,0,.3);max-width:92vw;text-align:center;';
		el.innerHTML = 'Ferry 只读面板 · 仅允许切换节点' +
			(sb ? '<br><span style="opacity:.8">sing-box 后端：规则页、配置页、延迟明细、重启/升级不可用（内核不提供）；「规则」页入口已隐藏</span>' : '');
		document.body.appendChild(el);
		setTimeout(function() { el.style.transition = 'opacity .6s'; el.style.opacity = '0.55'; }, 6000);
	}

	// sing-box 没有规则页数据，隐藏其导航入口（页面本身不再可进入，避免空白页）
	function hideUnavailablePages() {
		if (!sb) return;
		var labels = document.querySelectorAll('.dock .dock-label');
		for (var i = 0; i < labels.length; i++) {
			var t = (labels[i].textContent || '').trim();
			if (t === '规则' || t === 'Rules') {
				var b = labels[i].closest('button');
				if (b) b.style.display = 'none';
			}
		}
	}

	function startSbHiding() {
		if (!sb || !document.body) return;
		hideUnavailablePages();
		new MutationObserver(hideUnavailablePages).observe(document.body, { childList: true, subtree: true });
	}

	if (document.readyState === 'loading') {
		document.addEventListener('DOMContentLoaded', banner);
		document.addEventListener('DOMContentLoaded', startSbHiding);
	} else {
		banner();
		startSbHiding();
	}
})();
