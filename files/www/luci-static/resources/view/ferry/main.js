'use strict';
'require view';
'require form';
'require uci';

return view.extend({
	load: function() {
		return uci.load('ferry');
	},

	render: function() {
		var m, s, o;

		m = new form.Map('ferry', _('Ferry 透明代理网关'),
			_('把 mihomo 或 sing-box 作为路由器上的透明代理内核，为整个局域网提供自动代理。' +
			  '保存并应用后服务会自动重启，并按当前选项重新生成内核配置。'));

		/* ---------- 基础设置 ---------- */
		s = m.section(form.NamedSection, 'main', 'ferry', _('基础设置'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Flag, 'enabled', _('启用'),
			_('关闭后停止内核进程并清理全部接管规则，局域网恢复直连。'));
		o.rmempty = false;
		o.default = '0';

		o = s.option(form.Select, 'kernel', _('代理内核'),
			_('同一时间只运行一个内核。切换内核会自动重新生成对应格式的配置。'));
		o.value('mihomo', _('mihomo（Clash Meta）'));
		o.value('singbox', _('sing-box'));
		o.rmempty = false;
		o.default = 'mihomo';

		o = s.option(form.Select, 'mode', _('运行模式'),
			_('TPROXY：TCP+UDP 透明代理，推荐；TUN：虚拟网卡接管，兼容性最好；REDIRECT：仅 TCP。'));
		o.value('tproxy', _('TPROXY（TCP + UDP，推荐）'));
		o.value('tun', _('TUN（虚拟网卡）'));
		o.value('redirect', _('REDIRECT（仅 TCP）'));
		o.rmempty = false;
		o.default = 'tproxy';

		o = s.option(form.Select, 'deploy', _('部署形态'),
			_('主路由：接管全部 LAN 流量；旁路由：不接管本机转发，由上游网关指向本机；' +
			  '客户端：不开启透明代理，只生成配置并监听混合端口。'));
		o.value('router', _('主路由（接管全部 LAN）'));
		o.value('bypass', _('旁路由（透明网关）'));
		o.value('client', _('客户端（只生成配置）'));
		o.rmempty = false;
		o.default = 'router';

		o = s.option(form.Value, 'proxy_port', _('透明代理端口'),
			_('TPROXY / REDIRECT 模式下内核的监听端口，需与接管规则一致。'));
		o.datatype = 'port';
		o.default = '7890';
		o.rmempty = false;

		o = s.option(form.Value, 'mixed_port', _('混合端口'),
			_('HTTP + SOCKS5 混合端口，供局域网设备显式配置代理使用；填 0 关闭。'));
		o.datatype = 'range(0,65535)';
		o.default = '7891';

		o = s.option(form.Value, 'dns_port', _('DNS 端口'),
			_('内核 DNS 监听端口。开启劫持后，局域网发往 53 端口的查询会被改写到该端口。'));
		o.datatype = 'port';
		o.default = '1053';
		o.rmempty = false;

		o = s.option(form.Flag, 'hijack_dns', _('劫持局域网 DNS'),
			_('把局域网 53 端口流量重定向到内核，防止 DNS 泄漏。'));
		o.default = '1';

		o = s.option(form.Flag, 'router_dns', _('路由器自身 DNS 走内核'),
			_('改写 dnsmasq 上游为内核 DNS 监听端口，避免路由器自身解析泄漏；TUN 模式由内核自动接管。'));
		o.default = '1';

		o = s.option(form.Select, 'dns_mode', _('DNS 增强模式'),
			_('fake-ip 兼容性更好、解析更快；redir-host 更适合需要真实 IP 的场景。'));
		o.value('fake-ip', 'fake-ip');
		o.value('redir-host', 'redir-host');
		o.depends('kernel', 'mihomo');
		o.default = 'fake-ip';

		o = s.option(form.Select, 'log_level', _('日志级别'));
		o.value('silent', _('silent（静默）'));
		o.value('error', _('error'));
		o.value('warning', _('warning'));
		o.value('info', _('info'));
		o.value('debug', _('debug'));
		o.default = 'info';

		/* ---------- 代理来源 ---------- */
		s = m.section(form.NamedSection, 'main', 'ferry', _('代理来源'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Value, 'sub_url', _('订阅 URL'),
			_('mihomo：填 Clash/mihomo 格式 YAML 订阅，将作为 proxy-provider 使用；' +
			  'sing-box：需返回完整的 sing-box JSON 配置（格式转换请在外部完成）。'));
		o.datatype = 'string';
		o.placeholder = 'https://example.com/subscription';
		o.rmempty = true;

		o = s.option(form.Value, 'config_path', _('自备配置文件'),
			_('填写后优先使用该文件，插件不再生成配置。mihomo 填 YAML 路径，sing-box 填 JSON 路径。'));
		o.placeholder = '/etc/mihomo/custom.yaml';
		o.rmempty = true;

		o = s.option(form.Value, 'bin_path', _('内核二进制路径'),
			_('留空则自动使用 /usr/bin/mihomo 或 /usr/bin/sing-box。'));
		o.placeholder = '/usr/bin/mihomo';
		o.rmempty = true;

		/* ---------- 分流与绕过 ---------- */
		s = m.section(form.NamedSection, 'main', 'ferry', _('分流与绕过'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Select, 'final_policy', _('默认策略'),
			_('未被任何分流规则命中时的处理方式。分类规则请到「分流规则」页调整。'));
		o.value('proxy', _('走代理（MATCH,PROXY / final=proxy）'));
		o.value('direct', _('直连（MATCH,DIRECT / final=direct）'));
		o.rmempty = false;
		o.default = 'proxy';

		o = s.option(form.DynamicList, 'bypass_cidr', _('绕过网段（CIDR）'),
			_('这些目标网段不会被代理，直连访问。插件已内置常见保留网段。'));
		o.datatype = 'cidr';
		o.placeholder = '192.168.0.0/16';

		o = s.option(form.DynamicList, 'bypass_ip', _('绕过目标 IP'),
			_('需要直连的具体目标 IP，例如某些内网服务器或探测地址。'));
		o.datatype = 'ipaddr';
		o.placeholder = '192.168.1.10';

		/* ---------- 高级选项 ---------- */
		s = m.section(form.NamedSection, 'main', 'ferry', _('高级选项'));
		s.anonymous = true;
		s.addremove = false;

		o = s.option(form.Value, 'lan_iface', _('局域网接口'),
			_('需要接管的接口名，留空自动从 network.lan 推断，通常是 br-lan。'));
		o.placeholder = 'br-lan';
		o.rmempty = true;

		o = s.option(form.Flag, 'enable_ipv6', _('接管 IPv6'),
			_('nftables 后端下同时接管 IPv6；iptables 后端只处理 IPv4。'));
		o.default = '1';

		o = s.option(form.Flag, 'block_quic', _('丢弃转发 QUIC（UDP/443）'),
			_('REDIRECT 模式只能接管 TCP，丢弃 QUIC 可避免浏览器绕过代理泄漏。'));
		o.depends('mode', 'redirect');
		o.default = '1';

		o = s.option(form.Select, 'tun_stack', _('TUN 协议栈'),
			_('mihomo TUN 模式使用的协议栈；sing-box 固定使用 mixed。'));
		o.value('system', 'system');
		o.value('gvisor', 'gvisor');
		o.value('mixed', 'mixed');
		o.depends('kernel', 'mihomo');
		o.depends('mode', 'tun');
		o.default = 'system';

		o = s.option(form.Select, 'firewall_backend', _('接管实现'),
			_('auto 会在系统支持 nftables 时优先使用 nftables，否则回退 iptables。'));
		o.value('auto', _('auto（推荐）'));
		o.value('nft', 'nftables');
		o.value('iptables', 'iptables');
		o.default = 'auto';

		o = s.option(form.DummyValue, '_hint', _('状态与日志'));
		o.default = _('保存并应用后，可用 SSH 执行 /etc/init.d/ferry status 查看状态，' +
			'logread -e ferry 查看日志。');

		return m.render();
	}
});
