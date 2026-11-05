'use strict';
'require baseclass';
'require rpc';

var callStatus = rpc.declare({ object: 'luci-ferry-kernel', method: 'status' });
var callVersions = rpc.declare({ object: 'luci-ferry-kernel', method: 'versions', params: [ 'kernel', 'prerelease' ] });
var callJob = rpc.declare({ object: 'luci-ferry-kernel', method: 'job' });
var callPreview = rpc.declare({ object: 'luci-ferry-kernel', method: 'preview', params: [ 'kernel', 'version' ] });
var callStart = rpc.declare({
	object: 'luci-ferry-kernel', method: 'start',
	params: [ 'op', 'kernel', 'version', 'urls', 'file', 'sha256', 'expect_version',
	          'mirror', 'allow_unverified', 'activate', 'restart', 'force' ]
});
var callRemove = rpc.declare({ object: 'luci-ferry-kernel', method: 'remove', params: [ 'kernel', 'version' ] });
var callMirrors = rpc.declare({ object: 'luci-ferry-kernel', method: 'mirrors' });
var callMirrorSet = rpc.declare({ object: 'luci-ferry-kernel', method: 'mirror_set', params: [ 'json' ] });
var callMirrorTest = rpc.declare({ object: 'luci-ferry-kernel', method: 'mirror_test', params: [ 'name' ] });

/* sing-box 配置模板矩阵（与 generate.sh 的 pm_sb_bucket 保持一致）
 * 每个区间都用真实二进制做过 `sing-box check`，见 README 的“sing-box 版本矩阵”。 */
var SB_BUCKETS = {
	'A': { range: '1.8.x – 1.10.x', dns: 'address', rules: 'outbound', tun: 'inet4_address', ddr: false },
	'B': { range: '1.11.x',          dns: 'address', rules: 'action',    tun: 'address',        ddr: false },
	'C': { range: '1.12.x – 1.13.x', dns: 'address', rules: 'action',    tun: 'address',        ddr: true  },
	'D': { range: '>= 1.14.x',       dns: 'type',    rules: 'action',    tun: 'address',        ddr: true  }
};

var ERR_TEXT = {
	ERR_NETWORK:      '下载失败（网络不可达或源不可用），可换镜像或改用本地导入',
	ERR_SHA_MISMATCH: 'SHA-256 校验不通过，文件已丢弃',
	ERR_UNVERIFIED:   '该版本官方未提供 checksum，需要勾选“允许未校验安装”',
	ERR_ARCH:         '二进制架构与本机不匹配',
	ERR_LIBC:         '二进制依赖 glibc，本固件为 musl',
	ERR_DISK_FULL:    '磁盘空间不足（至少需要 8MB 可用）',
	ERR_EXTRACT:      '解压失败或包内没有可执行文件',
	ERR_EXEC:         '二进制无法执行（架构或依赖不匹配）',
	ERR_VERSION_MISMATCH: '二进制版本与所选版本不一致',
	ERR_CONFIG_CHECK: '生成的配置未通过二进制自检，已自动回滚',
	ERR_START:        '新内核启动失败，已自动回滚',
	ERR_CONFIG_INCOMPATIBLE: '自备配置文件格式与新内核不匹配，需要显式确认',
	ERR_CUSTOM_BIN_PATH: '检测到 ferry.main.bin_path 已设置，内核管理不会覆盖自定义路径',
	ERR_NOT_INSTALLED: '目标版本尚未安装',
	ERR_NO_PREVIOUS:  '没有可回滚的上一版本',
	ERR_TAG:          '非法版本名',
	ERR_LOCAL:        '读取本地文件失败'
};

return baseclass.extend({
	callStatus: callStatus,
	callVersions: callVersions,
	callJob: callJob,
	callPreview: callPreview,
	callStart: callStart,
	callRemove: callRemove,
	callMirrors: callMirrors,
	callMirrorSet: callMirrorSet,
	callMirrorTest: callMirrorTest,

	bucketOf: function(version) {
		var m = String(version || '').match(/([0-9]+)\.([0-9]+)/);
		if (!m)
			return null;
		var maj = +m[1], min = +m[2];
		if (maj < 1 || (maj == 1 && min < 8))
			return null;
		if (maj > 1 || min >= 14)
			return 'D';
		if (min >= 12)
			return 'C';
		if (min == 11)
			return 'B';
		return 'A';
	},

	bucketInfo: function(version) {
		var b = this.bucketOf(version);
		return b ? SB_BUCKETS[b] : null;
	},

	matrixText: function() {
		return 'A: 1.8.x–1.10.x（address DNS + outbound 规则 + inet4_address）; '
		     + 'B: 1.11.x（address DNS + action 规则）; '
		     + 'C: 1.12.x–1.13.x（+ default_domain_resolver）; '
		     + 'D: >=1.14.x（type UDP DNS + action 规则）';
	},

	fmtBytes: function(n) {
		n = +(n || 0);
		if (n >= 1048576)
			return (n / 1048576).toFixed(1) + ' MiB';
		if (n >= 1024)
			return (n / 1024).toFixed(1) + ' KiB';
		return n + ' B';
	},

	shortSha: function(s) {
		return s ? String(s).substr(0, 16) + '…' : '—';
	},

	errText: function(code) {
		return ERR_TEXT[code] || code || '未知错误';
	},

	archFamily: function(a) {
		switch (a) {
			case 'amd64': case '386': case 'x86_64': return 'x86';
			case 'arm64': case 'aarch64': return 'arm64';
			case 'arm': case 'armv6': case 'armv7': case 'armv7l': return 'arm';
			case 'mips': case 'mipsle': return 'mips';
			case 'riscv64': return 'riscv64';
			default: return a || '';
		}
	},

	archMatch: function(host, bin) {
		return !!host && !!bin && this.archFamily(host) === this.archFamily(bin);
	}
});
