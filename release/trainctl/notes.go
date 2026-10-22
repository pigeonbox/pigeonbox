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
	w("底层: core " + tf.Get("lib.core") + " · contracts " + tf.Get("lib.contracts") + " · kit " + tf.Get("lib.kit") +
		" · frontend-core " + tf.Get("lib.frontend-core") + " · chart " + tf.Get("charts.chart") +
		"。全部源码仓: https://github.com/orgs/pigeonbox/repositories")
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
