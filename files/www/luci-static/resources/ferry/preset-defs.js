'use strict';
/* 分类与场景预设定义（供 LuCI 使用；shell 侧的 geo 名称映射在 rules.sh 中） */

var CATEGORIES = [
	{ id: 'cn',        name: '国内/直连',      desc: '国内站点，默认直连',           defaultTarget: 'direct' },
	{ id: 'ads',       name: '广告与追踪',      desc: '广告、统计与追踪域名',         defaultTarget: 'reject' },
	{ id: 'streaming', name: '流媒体解锁',      desc: 'Netflix / Disney / YouTube',  defaultTarget: 'proxy' },
	{ id: 'ai',        name: 'AI 服务',        desc: 'OpenAI / Anthropic / Gemini',  defaultTarget: 'proxy' },
	{ id: 'telegram',  name: 'Telegram',       desc: 'Telegram 相关域名',           defaultTarget: 'proxy' },
	{ id: 'dev',       name: 'GitHub/开发者',   desc: 'GitHub / GitLab / StackExchange', defaultTarget: 'proxy' },
	{ id: 'academic',  name: '学术',           desc: 'Coursera / edX / Khan Academy', defaultTarget: 'proxy' },
	{ id: 'game',      name: '游戏',           desc: 'Steam / Epic 等游戏平台',      defaultTarget: 'proxy' },
	{ id: 'custom',    name: '自定义域名/网段', desc: '手工填写的域名与 IP 段',       defaultTarget: 'proxy' }
];

var PRESETS = [
	{
		id: 'daily', name: '日常省流', mode: 'tproxy', deploy: 'router', final: 'proxy',
		desc: '国内与游戏直连，其余走代理，节省流量与延迟。',
		targets: { cn: 'direct', ads: 'reject', streaming: 'proxy', ai: 'proxy', telegram: 'proxy',
			dev: 'proxy', academic: 'proxy', game: 'direct', custom: 'direct' }
	},
	{
		id: 'global', name: '全局代理', mode: 'tproxy', deploy: 'router', final: 'proxy',
		desc: '除广告拦截外全部走代理，适合全设备统一出口。',
		targets: { cn: 'proxy', ads: 'reject', streaming: 'proxy', ai: 'proxy', telegram: 'proxy',
			dev: 'proxy', academic: 'proxy', game: 'proxy', custom: 'proxy' }
	},
	{
		id: 'streaming', name: '流媒体优先', mode: 'tproxy', deploy: 'router', final: 'proxy',
		desc: '流媒体与 AI 走代理，国内直连，其他分类直连以降低干扰。',
		targets: { cn: 'direct', ads: 'reject', streaming: 'proxy', ai: 'proxy', telegram: 'proxy',
			dev: 'direct', academic: 'direct', game: 'direct', custom: 'direct' }
	},
	{
		id: 'ai', name: 'AI 优先', mode: 'tproxy', deploy: 'router', final: 'proxy',
		desc: 'AI 与开发者站点走代理，其余尽量直连。',
		targets: { cn: 'direct', ads: 'reject', streaming: 'direct', ai: 'proxy', telegram: 'proxy',
			dev: 'proxy', academic: 'proxy', game: 'direct', custom: 'direct' }
	},
	{
		id: 'gaming', name: '游戏低延迟', mode: 'tproxy', deploy: 'router', final: 'direct',
		desc: '游戏平台与国外站点走代理，其余直连；建议 TPROXY 以确保 UDP 生效。',
		targets: { cn: 'direct', ads: 'reject', streaming: 'proxy', ai: 'proxy', telegram: 'proxy',
			dev: 'proxy', academic: 'direct', game: 'proxy', custom: 'proxy' }
	},
	{
		id: 'whitelist', name: '仅白名单走代理', mode: 'tproxy', deploy: 'router', final: 'direct',
		desc: '默认全部直连，只有流媒体/AI/开发者/Telegram 走代理。',
		targets: { cn: 'direct', ads: 'reject', streaming: 'proxy', ai: 'proxy', telegram: 'proxy',
			dev: 'proxy', academic: 'direct', game: 'direct', custom: 'direct' }
	},
	{
		id: 'bypass', name: '旁路由透明网关', mode: 'tproxy', deploy: 'bypass', final: 'proxy',
		desc: '部署为旁路由：主路由 DHCP 把网关与 DNS 指向本机，其余规则同日常省流。',
		targets: { cn: 'direct', ads: 'reject', streaming: 'proxy', ai: 'proxy', telegram: 'proxy',
			dev: 'proxy', academic: 'proxy', game: 'direct', custom: 'direct' }
	}
];

function findPreset(id) {
	for (var i = 0; i < PRESETS.length; i++)
		if (PRESETS[i].id === id)
			return PRESETS[i];
	return null;
}

function buildRules(presetId) {
	var p = findPreset(presetId) || PRESETS[0];
	return CATEGORIES.map(function(c) {
		return {
			cat: c.id,
			target: p.targets[c.id] || c.defaultTarget,
			enabled: true
		};
	});
}

return {
	CATEGORIES: CATEGORIES,
	PRESETS: PRESETS,
	findPreset: findPreset,
	buildRules: buildRules
};
