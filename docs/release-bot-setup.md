# 发布机器人账号配置清单(pigeonbox-ci)

发布列车 v2(设计稿 `docs/specs/2026-10-12-release-train-v2-design.md`)的写操作统一走 org 机器人账号,
取代 7 个仓级 `*_PAT` + `CHARTS_PAT` + `TRAIN_PAT` + `RELEASE_PAT`。以下步骤需要 org owner 在 GitHub 侧操作,
完成后全链路(编排器推 tag/合并 PR/charts 直提/组件回挂/回调)即切到单一凭据。

## 1. 建账号与入 org

1. 注册机器人账号(建议名 `pigeonbox-ci`,用团队公共邮箱;**注册后不要改密码**——改密码会吊销其全部 classic PAT,这正是 v1 的事故类别)。
2. org → People → Invite member,邀请该账号入 `pigeonbox` org(普通 member 即可)。
3. 逐仓授权 write:以下 15 仓 Settings → Collaborators and teams → 给机器人(或其所在 team)`Write`:
   `pigeonbox`(hub)、`server`、`frontend`、`frontend-core`、`fnos`、`openwrt`、`qnap`、`synology`、`ugreen`、`terramaster`、`desktop`、`charts`、`contracts`、`core`、`kit`、`p2p`(共 16 个,含库线四仓备用)。
4. 受保护分支:各仓 main(fnos 为 master)的 branch protection 若要求「合并前需检查/审阅」,给机器人勾 `Do not allow bypassing the above settings` 的**豁免**(Allow specified actors to bypass → 加 pigeonbox-ci),否则 advance 自动合并需 `--admin` 兜底(可用但每次响亮告警)。

## 2. 发 classic PAT

必须 **classic**(fine-grained 不支持 ghcr packages 读取,advance 的镜像核对依赖 `read:packages`):

- Scopes:`repo` + `workflow` + `read:packages`
- 有效期:建议 90 天并设轮换提醒(轮换=org secret 改一处)

## 3. 配 org secret

```bash
# 在 org 级配置,全部仓可用(过渡期工作流写法为 PB_BOT_TOKEN || 旧PAT,配好即自动优先)
gh secret set PB_BOT_TOKEN --org pigeonbox --body "<PAT>"
```

## 4. 验证

```bash
gh workflow run train-orchestrator.yml -R pigeonbox/pigeonbox -f phase=advance
gh run watch -R pigeonbox/pigeonbox   # 应全绿;日志确认 clone 用机器人凭据
```

## 5. 过渡期结束后清理(1.20.0 首航 shipped 之后)

- 删各仓旧 secret:`FNOS_PAT` `OPENWRT_PAT` `QNAP_PAT` `SYNOLOGY_PAT` `UGREEN_PAT` `TERRAMASTER_PAT` `DESKTOP_PAT` `CHARTS_PAT`(server)`TRAIN_PAT` `RELEASE_PAT`(charts)
- 工作流里的 `|| secrets.<旧PAT>` 回退表达式一并清理(hub train-orchestrator + 8 组件仓 release.yml)
- 删 9 处 version-tagger.yml、server release.yml 的等 frontend tag 轮询、charts sync-appversion.yml、hub train-release.yml、scripts/release-train.sh

## 安全取舍记录

org secret 对全 org 仓可见 = 各仓共享一个写 token。现状 7 个仓级 PAT 本就互有 hub `contents:write`,
信任面无实质扩大(2026-10-12 拍板)。若未来引入不可信仓,再把该仓排除出 secret 可见范围即可。
