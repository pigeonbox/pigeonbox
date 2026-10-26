# scripts/

装配仓(hub)级脚本。模块仓各自的工具在自己的仓里（如 `contracts/scripts/` 的 IDL 再生成）。

| 脚本 | 用途 | 说明 |
|---|---|---|
| `setup.sh` | 拉齐/更新十二个模块仓（幂等），`make setup` 的实体 | 默认全拉 contracts/core/server/frontend/fnos/openwrt/p2p/kit + NAS 打包四仓 synology/qnap/ugreen/terramaster；`SETUP_<名>=0` 可分别跳过 |
| `smoke-full.sh` | 全能力真机冒烟（44 项断言，含临时 Redis） | 需先 `make build`，对运行中的 server 执行 |
| `e2e-api-key-smoke.sh` | API Key 全链路 e2e（创建/认证/限流/撤销） | 对运行中的 server 执行 |
| `e2e-chunk-upload.py` | 大文件分片上传 e2e（init/分片/complete/秒传） | Python3 标准库实现 |
| `e2e-s3-minio.sh` | MinIO S3 存储后端 e2e | 本地起 MinIO 容器后跑通 S3 读写与分享 |
| `export_config_from_db.{go,py}` | 从旧版 SQLite `key_values` 表导出配置为 YAML | **遗留迁移工具**：`key_values` 表已废弃（现行为 `system_configs` 单行 JSON，由 core 自动读写），仅用于迁移更早期部署的数据。Go 版需独立构建：`cd scripts && GOWORK=off go run export_config_from_db.go -db data/fileCodeBox.db` |
| `generate_favicon.sh` | 品牌图标生成入口（薄封装，转调 `gen-brand-icons.py`） | 前端/静态资源维护用 |
| `gen-brand-icons.py` | 品牌图标**换底色 + 全套派生资产**重出 | 真相源 `frontend-core/public/favicon.svg`（内嵌 512px PNG）+ 白鸽贴片 `pigeon-glyph.png`；底色公式与站内 logo 底座一致。`--accent 0e9f6e` 换色并重出（frontend-core/fnos/desktop/synology/qnap 全套），不带参数只重出派生件 |
| `test_nfs_storage.sh` | NFS 存储后端连通性与读写测试 | 存储运维用 |

> 来源说明：`export_config_from_db.*`、`generate_favicon.sh`、`test_nfs_storage.sh` 收编自旧单体仓库（legacy/PigeonBox），2026-10 迁入；`e2e-*` 与 `smoke-full.sh` 为本项目 2026-10-03 新写；`gen-brand-icons.py` 为 2026-10-26 品牌换色时新增（`generate_favicon.sh` 的实体）。
