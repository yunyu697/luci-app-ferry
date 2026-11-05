// LuCI ferry 页面 DOM 断言（无截图）：正例 / 反例 / 重试恢复
// 由 tests/luci-dom-negative.sh 调用；也可单独用：
//   node luci-dom-assert.mjs negative <baseUrl> <user> <pass> <readyFlag> <restoreFlag> <outJson>
// 只使用 DOM 文本、选择器与控制台异常，不做任何截图。
import { writeFileSync, existsSync } from 'node:fs';

const [mode = 'negative', base, username = 'root', password = 'ferrytest',
	readyFlag = '', restoreFlag = '', out = 'luci-dom.json'] = process.argv.slice(2);

const CDP = process.env.CDP_URL || 'http://127.0.0.1:9333';
const PAGE = `${base}/cgi-bin/luci/admin/services/ferry`;
const sleep = ms => new Promise(r => setTimeout(r, ms));

let pass = 0, fail = 0;
const results = [];
function check(name, ok, detail = '') {
	ok ? pass++ : fail++;
	results.push({ name, ok: !!ok, detail });
	console.log(`${ok ? 'PASS' : 'FAIL'}: ${name}${detail ? ' — ' + detail : ''}`);
}

const res = await fetch(`${CDP}/json/new?about:blank`, { method: 'PUT' });
const target = await res.json();
const ws = new WebSocket(target.webSocketDebuggerUrl);

let id = 0;
const pending = new Map();
const events = [];
const send = (method, params = {}) => new Promise((resolve, reject) => {
	const mid = ++id;
	pending.set(mid, { resolve, reject });
	ws.send(JSON.stringify({ id: mid, method, params }));
});
ws.addEventListener('message', ev => {
	const msg = JSON.parse(ev.data);
	if (msg.id && pending.has(msg.id)) {
		const p = pending.get(msg.id); pending.delete(msg.id);
		msg.error ? p.reject(new Error(JSON.stringify(msg.error))) : p.resolve(msg.result);
	} else if (msg.method) events.push(msg);
});
await new Promise(r => ws.addEventListener('open', r, { once: true }));
await send('Page.enable');
await send('Runtime.enable');
await send('Log.enable');
await send('Page.addScriptToEvaluateOnNewDocument', {
	source: `window.__errs=[];
window.addEventListener('error',e=>window.__errs.push(String(e.message)));
window.addEventListener('unhandledrejection',e=>window.__errs.push(String((e.reason&&e.reason.message)||e.reason)));`
});
const evalJs = async expr => {
	const r = await send('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true });
	return r.result ? r.result.value : undefined;
};
const snapshot = async () => JSON.parse(await evalJs(`JSON.stringify({
	url: location.href, title: document.title, ready: document.readyState,
	hasMain: !!document.getElementById('maincontent'),
	text: (document.getElementById('maincontent')||document.body).innerText,
	inputs: document.querySelectorAll('#maincontent input').length,
	selects: document.querySelectorAll('#maincontent select').length,
	buttons: Array.from(document.querySelectorAll('#maincontent button')).map(b=>b.innerText.trim()),
	firstSelect: ((document.querySelector('#maincontent select')||{}).value) || '',
	windowErrs: window.__errs
})`));
const exceptions = () => events.filter(e => e.method === 'Runtime.exceptionThrown').map(e => ({
	text: e.params.exceptionDetails.text,
	desc: (e.params.exceptionDetails.exception && e.params.exceptionDetails.exception.description) || '',
}));
const factoryErr = () => /factory yields invalid constructor/i.test(JSON.stringify(exceptions()));

// 登录 + 打开页面
await send('Page.navigate', { url: PAGE });
await sleep(4000);
await evalJs(`(function(){
	var u=document.querySelector('input[name=luci_username]')||document.querySelector('input[type=text]');
	var p=document.querySelector('input[name=luci_password]')||document.querySelector('input[type=password]');
	if(!u||!p) return 'SKIP';
	u.value=${JSON.stringify(username)}; p.value=${JSON.stringify(password)};
	(u.form||document.forms[0]).submit(); return 'SUBMITTED';
})()`);
await sleep(6000);
await send('Page.navigate', { url: PAGE });
await sleep(14000);

let dom = await snapshot();
const initialExceptions = exceptions();

if (mode === 'negative') {
	check('页面加载完成', dom.hasMain && dom.ready === 'complete', dom.title);
	check('出现「配置读取失败」提示', dom.text.includes('配置读取失败'));
	check('出现「重试」按钮', dom.buttons.some(b => b.includes('重试')));
	check('表单骨架保留（标题）', dom.text.includes('Ferry 透明代理网关'));
	check('表单骨架保留（≥1 input）', dom.inputs >= 1, 'inputs=' + dom.inputs);
	check('表单骨架保留（≥1 select）', dom.selects >= 1, 'selects=' + dom.selects);
	check('无未捕获异常', initialExceptions.length === 0, 'count=' + initialExceptions.length);
	check('无 factory yields invalid constructor', !factoryErr());

	// 通知 shell 还原配置，然后点重试
	if (readyFlag) writeFileSync(readyFlag, 'restore-please\n');
	const deadline = Date.now() + 120000;
	while (restoreFlag && !existsSync(restoreFlag) && Date.now() < deadline) await sleep(500);
	check('配置已还原（flag 到达）', !restoreFlag || existsSync(restoreFlag));

	const clicked = await evalJs(`(function(){
		var b=Array.from(document.querySelectorAll('#maincontent button')).find(x=>x.innerText.trim()==='重试');
		if(!b) return 'NO_RETRY'; b.click(); return 'CLICKED';
	})()`);
	check('点击「重试」按钮', clicked === 'CLICKED', String(clicked));
	await sleep(10000);
	dom = await snapshot();
	check('重试后提示消失', !dom.text.includes('配置读取失败'));
	/* 完整表单远多于骨架（骨架只有 1 select / 1 input），用数量区分两者 */
	check('重试后表单恢复（完整表单控件）', dom.text.includes('Ferry 透明代理网关') && dom.inputs >= 5 && dom.selects >= 2,
		`inputs=${dom.inputs} selects=${dom.selects}`);
	check('重试后表单已填充（首个 select 有值）', !!dom.firstSelect, 'value=' + dom.firstSelect);
	check('重试过程无未捕获异常', exceptions().length === 0, 'count=' + exceptions().length);
}

writeFileSync(out, JSON.stringify({ mode, results, pass, fail, exceptions: exceptions(), dom }, null, 2));
console.log(`ASSERT PASS=${pass} FAIL=${fail}`);
ws.close();
process.exit(fail === 0 ? 0 : 1);
