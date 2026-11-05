#!/usr/bin/env node
/*
 * LuCI 类加载器契约检查（离线，无需固件）。
 *
 * 背景：LuCI 的 `L.require()` 会把资源文件当作 factory 求值，随后执行
 *   Class.isSubclass(_class)  →  失败则抛 TypeError "<name>" factory yields invalid constructor
 *   const instance = new _class()
 * 并让 `require x as y` 拿到 **实例**。因此每个 resources/*.js 与 view/*.js 的
 * factory 必须 return 一个 Class 子类（view.extend / baseclass.extend），
 * 返回普通对象、数组、函数或 Promise 都会在浏览器端炸整页。
 *
 * 本脚本用最小化的 Class 模拟该契约：逐个文件求值、断言返回 constructor、
 * 实例化并断言对外 API 真的挂在实例上（能调用），从而补上 `node --check`
 * 无法覆盖的语义层盲区。
 */
import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const resDir = join(root, 'files/www/luci-static/resources');

/* ---------- 最小 Class（对齐 LuCI baseclass 的 extend/isSubclass 语义） ---------- */

class Class {
	static extend(props) {
		const Parent = this;
		function Sub(...args) {
			if (props && typeof props.__init__ === 'function')
				props.__init__.apply(this, args);
			else if (typeof Parent.prototype.__init__ === 'function')
				Parent.prototype.__init__.apply(this, args);
		}
		Sub.prototype = Object.create(Parent.prototype);
		Sub.prototype.constructor = Sub;
		Sub.__base__ = Parent;
		Sub.__name__ = (props && props.__name__) || null;
		for (const k of Object.keys(props || {})) {
			if (k === '__name__')
				continue;
			Sub.prototype[k] = props[k];
		}
		return Sub;
	}

	static isSubclass(cls, base) {
		if (typeof cls !== 'function')
			return false;
		let p = cls;
		while (p) {
			if (p === (base || this))
				return true;
			p = p.__base__;
		}
		return false;
	}

	static instantiate(args) {
		return new (this)(...args);
	}
}

Class.__name__ = 'Class';

/* ---------- 依赖桩 ---------- */

const L = {
	error(type, fmt, ...args) {
		throw new TypeError(String(fmt).replace(/%s/g, () => String(args.shift() ?? '?')));
	},
	raise(type, fmt, ...args) {
		throw new TypeError(String(fmt).replace(/%s/g, () => String(args.shift() ?? '?')));
	},
	url: p => '/cgi-bin/luci/' + String(p).replace(/^\/+/, ''),
	toArray: v => (Array.isArray(v) ? v : (v == null ? [] : [v])),
	isObject: v => v !== null && typeof v === 'object'
};

/* 任意属性都返回 Promise 的函数桩；只用于被延迟调用（load/render 等）的依赖。 */
function stub(name) {
	const fn = function() { return Promise.resolve({}); };
	fn.__stub__ = name;
	return new Proxy(fn, {
		get(target, key) {
			if (key === 'then' || key === 'constructor' || key === Symbol.toPrimitive)
				return undefined;
			if (key in target)
				return target[key];
			return () => Promise.resolve({});
		}
	});
}

const view = stub('view');
view.extend = Class.extend.bind(Class);

const fileMap = {
	'baseclass': null,
	'ferry.preset-defs': join(resDir, 'ferry/preset-defs.js'),
	'ferry.store': join(resDir, 'ferry/store.js'),
	'ferry.links': join(resDir, 'ferry/links.js'),
	'ferry.kernels': join(resDir, 'ferry/kernels.js'),
	'view.ferry.main': join(resDir, 'view/ferry/main.js'),
	'view.ferry.nodes': join(resDir, 'view/ferry/nodes.js'),
	'view.ferry.rules': join(resDir, 'view/ferry/rules.js'),
	'view.ferry.presets': join(resDir, 'view/ferry/presets.js'),
	'view.ferry.deploy': join(resDir, 'view/ferry/deploy.js'),
	'view.ferry.profiles': join(resDir, 'view/ferry/profiles.js'),
	'view.ferry.kernel': join(resDir, 'view/ferry/kernel.js')
};

/* rpc.declare 必须返回可调用函数（真实 LuCI 里就是 uhttpd 的 rpc 代理） */
const rpc = {
	declare(def) {
		const fn = (...args) => Promise.resolve({});
		fn.__def__ = def;
		return fn;
	}
};

/* poll 资源模块：add() 返回 boolean */
const poll = {
	added: [],
	add(fn, interval) { poll.added.push({ fn, interval }); return true; },
	remove(fn) { poll.added = poll.added.filter(x => x.fn !== fn); return true; }
};

const stubs = {
	'view': view,
	'fs': stub('fs'),
	'uci': stub('uci'),
	'rpc': rpc,
	'poll': poll,
	'ui': stub('ui'),
	'form': stub('form')
};

/* ---------- 最小 DOM：让 view.render() 能真的跑一遍 ---------- */

function node(tagName) {
	const n = {
		tagName,
		attrs: {},
		children: [],
		listeners: {},
		get firstChild() { return this.children.length ? this.children[0] : null; },
		appendChild(c) { this.children.push(c); return c; },
		removeChild(c) {
			const i = this.children.indexOf(c);
			if (i >= 0) this.children.splice(i, 1);
			return c;
		},
		addEventListener(type, fn) { (this.listeners[type] = this.listeners[type] || []).push(fn); }
	};
	return n;
}

/* LuCI 的 E() 不展开嵌套数组：这里对嵌套数组直接报错，避免漏掉真实渲染问题 */
function E(tag, attrs, children) {
	const n = node(tag);
	for (const k of Object.keys(attrs || {}))
		n.attrs[k] = attrs[k];
	for (const c of (children || [])) {
		if (c === null || c === undefined)
			continue;
		if (Array.isArray(c)) {
			n.__nestedArray__ = true;
			continue;
		}
		n.appendChild(typeof c === 'object' ? c : String(c));
	}
	return n;
}

const documentStub = {
	getElementById: () => null,
	querySelectorAll: () => [],
	createElement: (t) => node(t)
};

globalThis.E = E;

/* ---------- 模拟 L.require ---------- */

let failures = 0;
const instances = {};

function fail(msg) {
	failures++;
	console.log(`FAIL: ${msg}`);
}

function describe(v) {
	if (v === null) return 'null';
	if (Array.isArray(v)) return 'array';
	if (typeof v === 'function' && v.__name__ === undefined && !v.__base__) return 'plain function';
	if (v instanceof Promise) return 'Promise';
	if (typeof v === 'object' && !v.__base__) return 'plain object';
	return typeof v;
}

function load(name) {
	if (instances[name])
		return instances[name];
	if (name === 'baseclass')
		return (instances[name] = Class);

	const file = fileMap[name];
	if (!file)
			throw new Error(`未知依赖 ${name}`);

	const source = readFileSync(file, 'utf8');
	const aliases = [];
	const deps = [];

	/* 与 luci.js 相同的行首 'require x [as y]' 指令扫描（'use strict' 允许跳过） */
	for (const line of source.split(/\r?\n/)) {
		const m = /^\s*'([^']*)'\s*;/.exec(line);
		if (!m)
			continue;
		const stmt = m[1];
		if (stmt === 'use strict')
			continue;
		const rm = /^require[ \t]+(\S+)(?:[ \t]+as[ \t]+([a-zA-Z_]\S*))?$/.exec(stmt);
		if (!rm)
			break;
		const dep = rm[1];
		deps.push(dep in stubs ? stubs[dep] : load(dep));
		aliases.push(rm[2] || dep.replace(/[^a-zA-Z0-9_]/g, '_'));
	}

	const factory = new Function(
		'window', 'document', 'L', ...aliases,
		`${source}\n//# sourceURL=${file}`
	);

	let cls;
	try {
		cls = factory({}, documentStub, L, ...deps);
	}
	catch (e) {
		fail(`"${name}" 求值时抛错：${e.message}\n  in ${file}`);
		return null;
	}

	if (!Class.isSubclass(cls)) {
		fail(`"${name}" factory yields invalid constructor（返回的是 ${describe(cls)}）\n  in ${file}`);
		return null;
	}

	const inst = new cls();
	instances[name] = inst;
	instances[name + '#class'] = cls;
	return inst;
}

/* ---------- 断言 ---------- */

function expectApi(name, keys) {
	const inst = instances[name];
	if (!inst) return;
	for (const k of keys) {
		if (inst[k] === undefined || inst[k] === null)
			fail(`${name} 实例缺少成员 ${k}`);
		else if (typeof inst[k] === 'function' && k !== 'files')
			/* ok */;
	}
	console.log(`PASS: ${name} -> constructor + instance (${keys.join(', ')})`);
}

for (const name of Object.keys(fileMap)) {
	if (name === 'baseclass') continue;
	load(name);
}

expectApi('ferry.preset-defs', [ 'CATEGORIES', 'PRESETS', 'findPreset', 'buildRules' ]);
expectApi('ferry.store', [ 'files', 'loadNodes', 'saveNodes', 'compile', 'applyPreset', 'status', 'esc' ]);
expectApi('ferry.links', [ 'parse', 'parseOne', 'b64d', 'tlsOf' ]);
expectApi('ferry.kernels', [ 'callStatus', 'callVersions', 'callStart', 'callPreview', 'callRemove',
	'callMirrors', 'callMirrorSet', 'callMirrorTest', 'callJob',
	'bucketOf', 'bucketInfo', 'matrixText', 'fmtBytes', 'shortSha', 'errText', 'archFamily', 'archMatch' ]);
for (const v of [ 'main', 'nodes', 'rules', 'presets', 'deploy', 'profiles', 'kernel' ])
	expectApi(`view.ferry.${v}`, [ 'load', 'render' ]);

/* 行为断言：契约不只是“类型对”，API 还得真能跑 */
try {
	const presets = instances['ferry.preset-defs'];
	const rules = presets.buildRules('daily');
	if (!Array.isArray(rules) || rules.length !== presets.CATEGORIES.length)
		fail('preset-defs.buildRules() 未返回与 CATEGORIES 等长的数组');
	else
		console.log(`PASS: preset-defs.buildRules('daily') -> ${rules.length} 条规则`);
	if (!presets.findPreset(presets.PRESETS[0].id))
		fail('preset-defs.findPreset() 找不到第一个预设');
	else
		console.log(`PASS: preset-defs.findPreset('${presets.PRESETS[0].id}') -> 命中`);
}
catch (e) {
	fail(`preset-defs 行为断言失败：${e.message}`);
}

try {
	const links = instances['ferry.links'];
	const out = links.parse('ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ@1.2.3.4:8388#demo');
	if (!out || !Array.isArray(out.nodes) || out.nodes.length !== 1)
		fail('links.parse() 未能解析 ss:// 链接');
	else
		console.log('PASS: links.parse(ss://) -> 1 个节点');
}
catch (e) {
	fail(`links 行为断言失败：${e.message}`);
}

/* 行为断言：sing-box 配置矩阵（边界必须与 generate.sh 的 pm_sb_bucket 一致） */
try {
	const K = instances['ferry.kernels'];
	const cases = [
		[ '1.8.14', 'A' ], [ '1.10.7', 'A' ], [ '1.11.0', 'B' ], [ '1.12.0', 'C' ],
		[ '1.13.1', 'C' ], [ '1.14.4', 'D' ], [ 'v1.11.1', 'B' ], [ '1.7.0', null ],
		[ '', null ], [ 'abc', null ]
	];
	let bad = 0;
	for (const [ v, want ] of cases) {
		const got = K.bucketOf(v);
		if (got !== want) {
			bad++;
			fail(`kernels.bucketOf('${v}') = ${got}，期望 ${want}`);
		}
	}
	if (!bad)
		console.log(`PASS: kernels.bucketOf 覆盖 ${cases.length} 个版本样本（A/B/C/D 与不支持）`);
	if (K.bucketInfo('1.8.14').dns !== 'address' || K.bucketInfo('1.14.4').dns !== 'type')
		fail('kernels.bucketInfo() 的 DNS 字段与矩阵不一致');
	else
		console.log('PASS: kernels.bucketInfo() DNS 字段（A=address / D=type）');
	if (!K.archMatch('amd64', '386') || !K.archMatch('armv7', 'arm') || K.archMatch('amd64', 'arm64'))
		fail('kernels.archMatch() 架构家族判断错误');
	else
		console.log('PASS: kernels.archMatch() 架构家族判断');
}
catch (e) {
	fail(`kernels 行为断言失败：${e.message}`);
}

/* 真实渲染路径：调用 view.render()（view.extend 出来的实例，而不只是看类型） */
try {
	const viewK = instances['view.ferry.kernel'];
	const tree = viewK.render({
		uci_kernel: 'mihomo', uci_kernel_norm: 'mihomo', arch: 'amd64',
		active: 'v1.19.33', active_version: '1.19.33', active_size: 12000000,
		active_arch: 'amd64', arch_match: true, running: false,
		bin_path: '/usr/bin/mihomo', config_path: '/etc/mihomo/config.yaml',
		config_compatible: true, free_kb: 100000, installed: [], job: null
	});
	if (!tree || !tree.tagName)
		fail('view.ferry.kernel.render() 未返回 DOM 节点');
	else if (tree.__nestedArray__)
		fail('view.ferry.kernel.render() 出现嵌套数组（LuCI 的 E() 不会展开）');
	else
		console.log(`PASS: view.ferry.kernel.render() -> <${tree.tagName}> ${tree.children.length} 个子节点`);
}
catch (e) {
	fail(`view.ferry.kernel.render() 抛错：${e.message}`);
}

/* ---------- 静态守卫：已被 LuCI 24.10.4 移除的 form.Select ---------- */

for (const f of [ 'main', 'nodes', 'rules', 'presets', 'deploy', 'profiles', 'kernel' ]) {
	const src = readFileSync(fileMap[`view.ferry.${f}`], 'utf8');
	const m = /form\.Select(?!\s*\|\|)/.exec(src);
	if (m) {
		const line = src.slice(0, m.index).split('\n').length;
		fail(`view/ferry/${f}.js:${line} 直接使用 form.Select（24.10.4 起已移除，需 form.Select || form.ListValue）`);
	}
}

if (failures) {
	console.log(`\nRESULT: FAIL (${failures} 项)`);
	process.exit(1);
}

console.log(`\nRESULT: PASS (${Object.keys(instances).filter(k => !k.endsWith('#class')).length} 个模块通过 LuCI 类加载器契约)`);
