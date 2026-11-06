// 前端错误态反例（无浏览器）：从 kernel.js 抽出 rpcTimeout，模拟
//   1) 请求永不返回（超时） 2) ubus 未知方法 3) 接口 404
// 三种都必须 reject（而不是吞掉/挂起），且错误文案能落到 versionsErr/mirrorsErr。
// 由 tests/test-kernel.sh 第 31 组调用：node tests/test-kernel-ui-errors.mjs
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const src = readFileSync(join(here, '..', 'files/www/luci-static/resources/view/ferry/kernel.js'), 'utf8');

let pass = 0, fail = 0;
const check = (name, ok, detail = '') => {
	console.log(`${ok ? 'PASS' : 'FAIL'}: ${name}${detail ? ' — ' + detail : ''}`);
	ok ? pass++ : fail++;
};

// 抽出 rpcTimeout 源码（从 function 行到列 0 的右花括号）
const start = src.indexOf('function rpcTimeout');
const end = src.indexOf('\n\t\t}', start);
check('能抽出 rpcTimeout', start >= 0 && end > start, `start=${start}`);
const fnSrc = src.slice(start, end + 4);
const rpcTimeout = new Function(`${fnSrc}; return rpcTimeout;`)();

// 反例 1：永不返回 → 必须超时 reject
let t0 = Date.now();
await rpcTimeout(new Promise(() => {}), 200, '读取版本清单')
	.then(() => check('超时反例：不应 resolve', false))
	.catch(e => {
		const dt = Date.now() - t0;
		check('超时反例：200ms 内 reject', dt < 900, `${dt}ms`);
		check('超时反例：文案含源操作与重启指引',
			/读取版本清单/.test(e.message) && /rpcd/.test(e.message), e.message);
	});

// 反例 2：ubus 未知方法 → reject 原文透传（界面据此显示错误态）
await rpcTimeout(Promise.reject(new Error('Method not found')), 5000, '读取镜像源')
	.then(() => check('未知方法反例：不应 resolve', false))
	.catch(e => check('未知方法反例：错误原文透传', /Method not found/.test(e.message), e.message));

// 反例 3：HTTP 404 → reject 原文透传
await rpcTimeout(Promise.reject(new Error('RPC 调用失败：HTTP 404')), 5000, '读取版本清单')
	.then(() => check('404 反例：不应 resolve', false))
	.catch(e => check('404 反例：错误原文透传', /404/.test(e.message), e.message));

// 正例：及时返回时不能误报超时
await rpcTimeout(Promise.resolve({ ok: true }), 200, '读取版本清单')
	.then(v => check('正例：及时返回正常 resolve', v && v.ok === true))
	.catch(e => check('正例：不应 reject', false, e.message));

// 错误必须被写进 render 状态（不是只 console.log）
check('ok:false 落 versionsErr', /if \(!r \|\| !r\.ok\)/.test(src) && /state\.versionsErr = \(r && r\.error\)/.test(src));
check('RPC reject 落 versionsErr', /state\.versionsErr = \(e && e\.message\)/.test(src));
check('RPC reject 落 mirrorsErr', /state\.mirrorsErr = \(e && e\.message\)/.test(src));
check('无 console-only 错误处理', !/console\.(log|error|warn)/.test(src));

console.log(`ASSERT PASS=${pass} FAIL=${fail}`);
process.exit(fail === 0 ? 0 : 1);
