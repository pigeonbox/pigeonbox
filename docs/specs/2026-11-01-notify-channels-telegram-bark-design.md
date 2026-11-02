# 通知渠道扩展：Telegram / Bark（core#31）设计

2026-11-01 · 针对 ROADMAP「下一步」`Telegram / Bark 通知渠道（SMTP 已落地，架构上扩渠道）`。

## 现状与目标

`app/notify` 已有两个渠道：**站内信**（落库 + 用户收件箱）与 **Webhook**（`notify.created` 事件 JSON POST）+ **SMTP 邮件**（对登记邮箱补发）。目标是**在架构上把「外部推送渠道」扩到 Telegram 与 Bark**，让站内信事件也能推到这两个常用即时通道，而不推翻现有 webhook/SMTP。

## 核心决策

### 1. 渠道抽象：渐进式 fan-out，不推翻现有

现有 `Service` 用 `webhookURL atomic.Pointer[string]` + `mailer atomic.Pointer[SMTPMailer]` 两渠道（热重建写、请求路径读 ⇒ 原子防 data race）。**不引入重量级 Channel 接口重构**（回归面大），而是：

- 仿 `webhookURL`，加 `telegramCfg atomic.Pointer[TelegramConfig]` + `barkCfg atomic.Pointer[BarkConfig]`。
- 抽统一出口 `dispatchExternal(event, payload, title, content)`，向**所有已启用渠道**（webhook + telegram + bark）fire-and-forget，各渠道独立 best-effort（失败只记日志，绝不影响站内信主流程）。
- `dispatchWebhook` → 改调 `dispatchExternal`；`EmitShareFlagged` / `EmitP2pInvite` 的 `async.GoSafe` 里同样走 `dispatchExternal`。

> SMTP 不并入此外部 fan-out（它是「对登记邮箱补发」的语义，与广播推送不同），保持现状。

### 2. 配置形状（`conf.NotifyConfig` 扩）

```go
type NotifyConfig struct {
    WebhookURL string        `mapstructure:"webhook_url" json:"webhook_url"`
    SMTP       SMTPConfig    `mapstructure:"smtp" json:"smtp"`
    Telegram   TelegramConfig `mapstructure:"telegram" json:"telegram"` // 新
    Bark       BarkConfig    `mapstructure:"bark" json:"bark"`          // 新
}
type TelegramConfig struct {
    BotToken string `mapstructure:"bot_token" json:"bot_token"` // env: PB_TELEGRAM_BOT_TOKEN
    ChatID   string `mapstructure:"chat_id" json:"chat_id"`     // env: PB_TELEGRAM_CHAT_ID
}
type BarkConfig struct {
    ServerURL  string `mapstructure:"server_url" json:"server_url"`   // 用户填；env: PB_BARK_SERVER_URL
    DeviceKey  string `mapstructure:"device_key" json:"device_key"`   // env: PB_BARK_DEVICE_KEY
}
```

缺省空 = 禁用该渠道。env 映射进 `bootstrap/config.go` 的表（照 `notify.webhook_url`）。

### 3. SSRF 策略（两渠道风险面不同）

- **Telegram**：目标固定 `https://api.telegram.org/bot<token>/sendMessage`（host **不可由用户输入**）⇒ SSRF 面小。token/chat_id 是配置值不构成出站 URL 注入。仍对拼好的 URL 跑 `security.ValidateEndpointURL`（纵深防御）。
- **Bark**：`ServerURL` **由用户填**（自建 Bark 服务）⇒ **必走 `security.ValidateEndpointURL`**（同 webhook，2026-10-08 加固口径），发送前复跑校验；私网目标默认拒（沿用全局 `security.ssrf` 口径，**不为 Bark 开 allow_private 后门**——用户填私网属自担，除非后续明确要对端粒度放行）。
- 两渠道发送前**都复跑校验**（防配置期绕过 + DNS 重绑定），沿用 `sendWebhook` 的加固范式。

### 4. 消息格式

- **Telegram** `POST api.telegram.org/bot<token>/sendMessage`，JSON `{chat_id, text}`，text = `title\n\ncontent`（可带事件名前缀）。
- **Bark** `POST <ServerURL>/<DeviceKey>`，JSON `{title, body, group?, icon?}`（Bark 通用推送 JSON 协议）。

### 5. 热重建与装配

- `Service` 加 `SetTelegram(*TelegramConfig)` / `SetBark(*BarkConfig)`（原子换指针，同 `SetWebhookURL`）。
- `bootstrap/wiring.go` 的 `applyNotifyConfig` 加两渠道装配（host/配置空 = 卸载）；`OnNotifyChanged` 热重建钩子已有，public 副本收到变更后重挂。

### 6. 守卫（均带负对照）

- **SSRF**：Bark 填私网 URL ⇒ `ValidateEndpointURL` 拒（负对照：合法公网 URL 过）；Telegram 拼 URL 仍过校验。
- **fan-out**：三渠道各自 best-effort（一渠道失败不影响他渠道与站内信）。
- **data race**：配置原子持有（`-race` 下热重建 + 并发读不 race）。

## 范围分批

- **第一批（本设计）**：core 侧渠道扩展（配置 + telegram/bark sender + SSRF + fan-out + 热重建 + 守卫）⇒ 走**配置文件 / env** 即可用。
- **第二批（admin 配置面）**：`contracts/admin.thrift` notify 配置形状 + `frontend-core` `views/admin/Config.vue` 面板 + i18n，让管理员**在界面填** bot token / chat id / bark server。跟第一批之后的车。

## 参考

- 现有渠道范式：`core/app/notify/notify.go`（`sendWebhook` 的 SSRF 复跑 + `dispatchWebhook` 的 fire-and-forget）。
- SSRF 校验：`core/pkg/security/ssrf.go`（`ValidateEndpointURL`）。
- 热重建装配：`core/bootstrap/wiring.go` `applyNotifyConfig` / `OnNotifyChanged`。
