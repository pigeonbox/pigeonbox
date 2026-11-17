# PigeonBox 支持策略与 EOL 窗口

> 本页是**用户可见的支持口径**；机器可读真相源是 [`release/support.json`](../release/support.json)。
> `docs/SUPPORT.md` 的支持矩阵 / PigeonBeam 兼容表，以及 `SECURITY.md` 的支持窗口表，
> 都由发布列车 bump 从该 JSON 同步生成，并由治理门禁
> （`scripts` 的 `TestSupportPolicyAndSLO`）逐项对账；**不要手改生成块**。

## 一、当前支持窗口

<!-- support-matrix:begin -->
当前维护线：**6.5.x（列车 6.5.0）**；安全支持窗口起算 **2026-11-17**。

| 版本线 | 状态 | 安全修复范围 | 安全支持截止 | 说明 |
|---|---|---|---|---|
| 6.5.x | ✅ 支持 | 全量安全修复 + 关键缺陷修复 | 2027-05-16 | 当前维护线：全量安全修复 + 关键缺陷修复 |
| 6.4.x | ⚠️ 仅高危/严重 | 仅 critical/high 安全修复 | 2027-02-15 | 上一 minor：仅 critical/high 安全修复（6.5.0 发布后 90 天） |
| 6.3.x | ⚠️ 仅高危/严重 | 仅 critical/high 安全修复 | 2027-02-15 | 上一 minor：仅 critical/high 安全修复（6.4.0 发布后 90 天） |
| 6.2.x | ⚠️ 仅高危/严重 | 仅 critical/high 安全修复 | 2027-02-15 | 上一 minor：仅 critical/high 安全修复（6.3.0 发布后 90 天） |
| 6.1.x | ⚠️ 仅高危/严重 | 仅 critical/high 安全修复 | 2027-02-15 | 上一 minor：仅 critical/high 安全修复（6.2.0 发布后 90 天） |
| 6.0.x | ⚠️ 仅高危/严重 | 仅 critical/high 安全修复 | 2027-02-15 | 上一 minor：仅 critical/high 安全修复（6.1.0 发布后 90 天） |
| 5.9.x | ⚠️ 仅高危/严重 | 仅 critical/high 安全修复 | 2027-02-14 | 上一 minor：仅 critical/high 安全修复（6.0.0 发布后 90 天） |
| 5.8.x | ⚠️ 仅高危/严重 | 仅 critical/high 安全修复 | 2027-02-14 | 上一 minor：仅 critical/high 安全修复（5.9.0 发布后 90 天） |
| 5.7.x | ⚠️ 仅高危/严重 | 仅 critical/high 安全修复 | 2027-02-10 | 上一 minor：仅 critical/high 安全修复（5.8.0 发布后 90 天） |
| 5.6.x | ❌ EOL | 无 | 2026-11-12 | 已 EOL：不再提供安全补丁 |
| <=5.5.x | ❌ EOL | 无 | 2026-11-09 | 已 EOL：不再提供安全补丁 |
<!-- support-matrix:end -->

### 怎么读这张表

- **当前维护线**：接收全部安全修复 + 关键缺陷修复，窗口为窗口起算日起 **180 天**
  （具体日期见上表）。若窗口到期时下一 minor 尚未发布，当前线继续作为维护线，窗口
  顺延到下一 minor 发布日 + 180 天；新日期由列车 bump 写入上表。
- **上一 minor**：只接收 **critical / high** 安全修复，截止日期见上表（当前线发布后
  90 天）。更早的 minor 若仍在已承诺的 critical 窗口内，会继续按原日期支持，不会被
  提前 EOL；承诺日过后状态改为 EOL。
- **EOL 版本**：不再提供安全补丁、CVE 修复或兼容性承诺。仍在使用 EOL 版本的实例应尽快
  升级；升级前按 [`docs/UPGRADE.md`](UPGRADE.md) 备份数据目录。

> 判据：任选一个表中版本，其「安全支持截止」列就是该版本线的最后安全支持日期。
> 截止日之后发现的漏洞，只在当前维护线修复，不回补 EOL 线。

## 二、EOL 政策

1. **每个 minor 线有明确截止日**：写入上表；不写「视情况而定」。
2. **EOL 后不做安全回补**：不为 EOL 线发 advisory 补丁或重建镜像；如漏洞影响 EOL 线，
   advisory 会注明「仅当前维护线修复」。
3. **EOL 前会先降级**：当前线发布后，上一 minor 进入 critical/high-only 窗口（90 天），
   再之后 EOL。降级/截止日期均写上表；已承诺日期不会因后续发布提前失效。
4. **版本号不预绑定功能**：安全修复可按 hotfix 通道发版，不改变支持窗口的起算规则。

## 三、升级建议

| 你的版本 | 建议 | 说明 |
|---|---|---|
| 当前维护线 | 保持更新 | 全量安全修复 + 关键缺陷修复 |
| 上一 minor | 在表中截止日前升级到当前维护线 | 只剩 critical/high 修复 |
| EOL 版本 | 尽快升级到当前维护线 | 已无安全补丁 |

容器 / NAS / 原生包的升级步骤见 [`docs/UPGRADE.md`](UPGRADE.md)；跨破坏性节点（3.0.0 / 4.0.0）
必须先整目录备份。升级后可用 `pb doctor`（server 仓 CLI）做 DB / 存储 / Redis / 版本 / 站点地址自检。

> `pb doctor` 的「已停止安全支持」提示在 server 仓接线本表之前，仍以本页表格为准；
> 接线后 CLI 会直接读取 `release/support.json` 的判定结果（不另维护一份 EOL 名单）。

## 四、PigeonBeam 协议兼容周期

PigeonBeam（信鸽直传）是独立应用，wire 协议与 p2p 仓版本线绑定；本仓列车通过
`release/train.yaml` 的 `lib.p2p` 钉版。当前口径（已按 p2p 仓公开信息核对）：

<!-- support-beam:begin -->
| 项 | 当前值 | 依据 |
|---|---|---|
| wire 协议 | **v4**（floor v4） | p2p 仓 `docs/PRODUCT.md`「品牌约定」 |
| p2p 版本线 | **v0.10.0** | `release/train.yaml` `lib.p2p`；p2p 仓对应 tag 的 Release |
| N-1 协商窗口 | **自 p2p v0.7.1 起** | p2p `docs/PRODUCT.md` Phase 2①：版本帧 `{proto, floor}`，`agreed=min(双方 proto)`；v4 floor 恒等于 proto |
| v4 客户端兼容承诺 | **至少到 2027-05-16** | 与当前产品线同窗口；兼容期只延长不缩短 |
| wire v5 的前置条件 | **必须双格式（v4 + v5）** | p2p `docs/PRODUCT.md`：wire 破坏性变更（v5 起）必须带 N-1 双格式实现，否则不得升 proto |
<!-- support-beam:end -->

**第三方规划口径**：

1. 现在按 **wire v4** 对接；v4 客户端可继续使用到 **上表「v4 客户端兼容承诺」日期**。
2. 若 wire v5 在该日期前发布，v5 必须同时支持 v4 与 v5 两种格式；v4 兼容期从
   **v5.0.0 发布日 + 180 天**重新起算（届时由 bump/治理更新上表日期）。
3. 若 wire v5 在该日期之后才发布，v4 兼容期以当前上表承诺为准，不提前失效。
4. 兼容期只覆盖 **协议互操作**；PigeonBeam 客户端自身的安全修复窗口以 p2p 仓
   `SECURITY.md` / Release 说明为准。

## 五、维护者操作

- 开新车时 `release/trainctl bump` 会同步更新 `release/support.json` 的 `train` / `minor` /
  `window_start` / `p2p_pin`，并重写 `SECURITY.md` 与本页的 **support-matrix / support-beam**
  生成块；**不要手改生成块**。
- 政策参数（180 / 90 天、critical/high 级别）在 `release/support.json` 的 `policy` 段；
  改动属于治理决策，需在 PR 说明理由并同步 [release-rules](rules/release-rules.md)。
- 发版说明（Release notes）必须标注本版是否安全版与支持窗口剩余；支持窗口的判据只认本页表格。