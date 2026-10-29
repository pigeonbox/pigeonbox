package main

import (
	"strings"
)

// cmdNotes 渲染 hub Release 说明(hub release.yml 与 finalize 共用,组件矩阵)。
func cmdNotes(tf *TrainFile, tag string) string {
	if tag == "" {
		tag = "v" + tf.Get("train")
	}
	if tf.Get("train") == "" {
		return "**PigeonBox 生态快照**。本仓是生态装配 hub:服务器本体经容器镜像与 Helm 分发," +
			"桌面 / NAS / 路由器等文件型产物由各组件 CI 以 desktop-v* / fnos-v* / openwrt-v* / p2p-v* tag 自动回挂到本页。\n"
	}
	rel := func(label, q string) string {
		return "[" + label + "](https://github.com/pigeonbox/pigeonbox/releases?q=" + q + "&expanded=false)"
	}
	var b strings.Builder
	w := func(s string) { b.WriteString(s + "\n") }
	w("**PigeonBox " + tag + " 生态列车**。本页即全生态二进制产物的统一出口——组件产物由各仓 CI 自动回挂(下方矩阵)。")
	w("")
	w("| 组件 | 版本 | 产物 |")
	w("|---|---|---|")
	w("| server / frontend | v" + tf.Get("images.server") + " | ghcr.io/pigeonbox/server + frontend;Helm: `helm repo add pigeonbox https://pigeonbox.github.io/charts` |")
	// 2026-10-22 Wave B':desktop 不再随包 p2pc sidecar(直传拆为独立应用
	// PigeonBeam),terminal.desktop.p2pc 键随之退休 ⇒ 这里不再拼 p2pc 版本。
	w("| desktop | " + tf.Get("terminal.desktop.tag") + " | " + rel("desktop-v*", "desktop-v") + " Windows/macOS/Linux 安装包(纯客户端;设备直传请用 PigeonBeam) |")
	w("| fnos | " + tf.Get("terminal.fnos.tag") + " | " + rel("fnos-v*", "fnos-v") + " fpk 应用包 |")
	w("| openwrt | " + tf.Get("terminal.openwrt.tag") + " | " + rel("openwrt-v*", "openwrt-v") + " ipk + apk |")
	w("| qnap | " + tf.Get("terminal.qnap.tag") + " | " + rel("qnap-v*", "qnap-v") + " QPKG 原生应用包(免 Container Station) |")
	p2pcRef := tf.Get("terminal.p2pc_ref")
	if p2pcRef == "" {
		p2pcRef = tf.Get("lib.p2p")
	}
	// "Box 包内随带" → "NAS 三端随带":2026-10-22 Wave B' 后 server 镜像不再
	// 随包 p2pc(只 NAS 三端随带,供内嵌 PigeonBeam 用)。
	w("| p2p | " + tf.Get("lib.p2p") + " | " + rel("p2p-v*", "p2p-v") + " p2pc 二进制;镜像 ghcr.io/pigeonbox/p2p;NAS 三端随带 " + p2pcRef + " |")
	for _, p := range platforms {
		w("| " + p + " | " + tf.Get("terminal."+p+".tag") + " | " + rel(p+"-v*", p+"-v") + " 部署包 |")
	}
	w("")
	// kit 已于 2026-10-16 归档（并入 oekit）⇒ 不再进版本台账 ⇒ 渲染时也**不出现**
	// （此前恒渲染成「kit  ·」——空版本号挂在外链说明里，像是漏了组件）。
	bottom := "底层: core " + tf.Get("lib.core") + " · contracts " + tf.Get("lib.contracts")
	if kit := tf.Get("lib.kit"); kit != "" {
		bottom += " · kit " + kit
	}
	bottom += " · frontend-core " + tf.Get("lib.frontend-core") + " · chart " + tf.Get("charts.chart") +
		"。全部源码仓: https://github.com/orgs/pigeonbox/repositories"
	w(bottom)
	if maj, ok := trainMajor(tf.Get("train")); ok && maj >= 3 {
		w("")
		w("### ⚠️ 破坏性变更（3.0.0 起）——设备直传已拆为独立应用 PigeonBeam（信鸽直传）")
		w("")
		w("Box 侧不再编排设备直传。以下能力**已退役**，请改用 PigeonBeam 客户端：")
		w("")
		w("| 退役项 | 表现 | 替代 |")
		w("|---|---|---|")
		w("| admin 直传端点 | `/admin/p2p/status`、`/tasks`、`/tasks/:id/log`、`/send`、`/send/upload`、`/recv`、`/cancel`、`/tasks/:id/approve`、`/publish` 共 9 个端点 404 | 在 PigeonBeam 客户端完成设备间直传 |")
		w("| admin 直传控制台 | 管理台「设备直传」页已移除，联邦面迁至「联邦」页 | 同上 |")
		w("| MCP 直传工具 | `p2p_status` / `p2p_tasks` / `p2p_send` / `p2p_recv` 消失（`p2p_peers` / `p2p_invites` / `p2p_accept` 保留） | 同上 |")
		w("| `pb` CLI 直传子命令 | `pb p2p status/tasks/send/recv/cancel` 报「未知 p2p 子命令」（`peers/invites/accept/push` 保留） | 同上 |")
		w("| 配置 `p2p.direct` 段 | 该段被忽略并已在启动日志中提示；**只配了 `p2p.direct.registry_url` 的实例会失去在线名录**，请改配到 `p2p.federation.registry_url` | 同上 |")
		w("| server 镜像 / desktop 客户端 | 不再随包 p2pc（server）与 p2pc sidecar（desktop） | NAS 三仓仍随带 PigeonBeam（入口为 `/beam`） |")
		w("")
		w("跨站取件路由（取件码本柜未命中时自动到联网站点查找）**不受影响**，联邦面整体保留。")
	}
	// 4.0.0（2026-10-26）：主版本号 3.x → 4.x，本版为**破坏性**发布 ——
	// 旧版本兼容层整轮退役（数据迁移在启动期自动完成，见下表「自动迁移」列）。
	if maj, ok := trainMajor(tf.Get("train")); ok && maj >= 4 {
		w("")
		w("### ⚠️ 破坏性变更（4.0.0 起）——旧版本兼容层退役")
		w("")
		w("3.x 期间为「旧客户端/旧后端/旧链接/旧字段/旧形态」保留的兼容分支、别名与兜底**整轮移除**。")
		w("大部分是**自动迁移**（启动期幂等执行，无需人工介入）；标注「需检查」的两项请逐条核对。")
		w("")
		w("| 退役项 | 表现 | 处理 |")
		w("|---|---|---|")
		w("| `file_codes.prefix` / `file_codes.suffix` 两列 | 列被删除；管理端/用户端列表不再下发这两个字段 | **自动迁移**（启动期 `ALTER TABLE DROP COLUMN`；全库恒空、无写入方） |")
		w("| 契约字段 `UserShareItemData.prefix` / `UserFileItem.prefix`+`suffix` | 响应体不再含这两个键；前端类型同步删除 | **自动**（前后端同版本升级即可）；自研客户端若读这两个字段请改用 `file_name` |")
		w("| 旧直传开关 `download.presign_anonymous_enabled` | 该键不再被读取 | **自动迁移**（读配置时并入 `download.presign_policy`：`false`⇒`authenticated`，`true`⇒`everyone`）；**需检查**：曾用该键关闭匿名直传的站点，请确认 `presign_policy` 取值符合预期 |")
		w("| 旧文件清单形态（「虚拟行 id=0」） | 取件页文件清单不再出现 id=0 的合成项 | **自动迁移**（启动期回填 `file_code_files` 子行） |")
		w("| `file_path` 列双语义（「目录 + UUID 文件名」/「完整相对路径」） | 统一为「完整相对路径」 | **自动迁移**（启动期归一存量行）；**需检查**：若有自研脚本按旧形态拼路径，请改按完整相对路径 |")
		w("| 存储磁盘历史双层布局（`<root>/uploads/uploads/…`） | 读路径不再回退到双层位置 | **自动迁移**（启动期同盘 rename 上提一层，冲突跳过不覆盖）；**需检查**：若有脚本直接读 `data/uploads/uploads/`，请改读 `data/uploads/` |")
		// ⚠️ 单元格里的竖线必须转义（`\|`）：markdown 表格按**未转义**的 `|` 分列，
		// 反引号里的竖线也不例外。实弹：本行曾写成 `code===0 || code===200` 未转义
		// ⇒ GitHub 与 VitePress 都把整行拆成 3 列，「表现」「处理」两列内容直接消失，
		// "集成方请继续只认 0" 这条关键指引在 Release 页与文档站上都读不到。
		w("| 前端视图层的成功码双写（`code===0 \\|\\| code===200`） | 官方前端内部收敛为「只认 200」 | **对集成方无影响**：接口成功码**恒为 `code: 0`**（errcode.CodeSuccess，2026-10-15 起已统一），`200` 只是官方前端请求层把 `0` 归一化后的内部值 —— **集成方请继续只认 `0`** |")
		w("")
		w("**不受影响**：MCP 协议多版本握手、联邦 wire 的 N-1 双格式、p2p 配对码、跨节点取件路由、")
		w("PigeonBeam 拆分（3.0.0 起）与联邦面（全部保留）。")
	}
	return b.String()
}

// trainMajor 取列车号的主版本号（非语义化版本返回 ok=false）。
func trainMajor(train string) (int, bool) {
	t := strings.TrimSpace(train)
	t = strings.TrimPrefix(t, "v")
	if i := strings.IndexAny(t, ".-+"); i >= 0 {
		t = t[:i]
	}
	if t == "" {
		return 0, false
	}
	n := 0
	for _, r := range t {
		if r < '0' || r > '9' {
			return 0, false
		}
		n = n*10 + int(r-'0')
	}
	return n, true
}
