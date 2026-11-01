# PigeonBox

**Anonymous code-based file & text sharing — like picking up a parcel.** Upload, get a pickup code, share the code; the recipient enters the code and downloads. No registration required.

PigeonBox is the Go multirepo workspace of the [pigeonbox](https://github.com/orgs/pigeonbox/repositories) organization. This repository is the **umbrella (hub)**: no business code, only tooling to assemble the module repos into a buildable workspace.

## Repositories

| Repo | Role | Version |
|------|------|---------|
| [contracts](https://github.com/pigeonbox/contracts) | Contract layer: error codes + Thrift-generated types + IDL source of truth (zero business deps) | v0.20.8 |
| [core](https://github.com/pigeonbox/core) | Business core library: 17 domain services (incl. config center) + repo/storage + `bootstrap.Bootstrap()` | v0.32.43 |
| [server](https://github.com/pigeonbox/server) | Deployable app: thin main + `pb` CLI (incl. `p2p` subcommands) + configs + Dockerfile (pure backend since 0.9.0; image no longer bundles p2pc) | v4.6.7 |
| [frontend](https://github.com/pigeonbox/frontend) | Frontend shell: neutral build + nginx image (released with server; host adapters live in platform repos' `web/`) | with server `v*` |
| [frontend-core](https://github.com/pigeonbox/frontend-core) | Shared frontend core: platform-agnostic app (Vue3 + TS + Vite + Element Plus) + host adapter SPI, consumed as Release tgz | v0.11.46 |
| [desktop](https://github.com/pigeonbox/desktop) | Desktop client: Tauri 2 tray app connecting to any PigeonBox server (pure client; direct transfer now lives in PigeonBeam) | desktop-v4.6.7 |
| [fnos](https://github.com/pigeonbox/fnos) | fnOS (fnNAS) native app: single-process fpk + official open-platform SSO integration + bundled p2pc (Docker image discontinued) | v4.6.7 |
| [openwrt](https://github.com/pigeonbox/openwrt) | OpenWrt/iStoreOS native packages (ipk + apk): procd-managed, UCI config, LuCI integration, single port 12345 with embedded Web UI, bundled p2pc | v4.6.7 |
| [synology](https://github.com/pigeonbox/synology) | Synology DSM 7.2+ package (SPK, noarch): Container Manager compose shell with install wizard | v4.6.7 |
| [qnap](https://github.com/pigeonbox/qnap) | QNAP QTS native app (QPKG, x86_64 + arm_64): single process, no Container Station needed (QTS 4.5+), QTS account SSO, bundled p2pc | v4.6.7 |
| [ugreen](https://github.com/pigeonbox/ugreen) | UGREEN UGOS Pro deployment package: paste-in Docker compose project (incl. CN mirror variant) | v4.6.7 |
| [terramaster](https://github.com/pigeonbox/terramaster) | TerraMaster TOS 5/6/7 deployment package: Docker Manager project import | v4.6.7 |
| [p2p](https://github.com/pigeonbox/p2p) | P2P federated registry + device transfer: node leases, passcode routing, WS signaling, encrypted relay, p2pc CLI/web clients (wire protocol v4) | v0.9.6 |
| [kit](https://github.com/pigeonbox/kit) | Shared Go toolkit — **archived 2026-10-16**, merged into [oekit](https://github.com/oekit) | v0.3.1 (final) |
| [charts](https://github.com/pigeonbox/charts) | Kubernetes Helm chart (frontend + server split deployments, multi-replica public/admin topology) | pigeonbox-2.0.111 |

Dependency direction (CI-enforced): `server / fnos / openwrt / qnap ──► core ──► contracts`; frontend: `shell & platform-repo web/ ──► frontend-core (tgz) ──► contracts (TS d.ts)`; `core` and `p2p` consume the external `oekit` foundation modules on demand (the in-repo `kit` was archived on 2026-10-16); `p2p` is a leaf repo with zero Go-module coupling — the server image and the fnos/qnap/openwrt/desktop packages pull pinned p2pc binaries at **packaging time**.

## Highlights

- **Share text or files anonymously** with pickup codes, expiry by time and/or a **pickup quota** (one pickup = one content delivery; text shares are counted per distinct recipient, not per page view), optional access password (bcrypt).
- **Chunked uploads** with resume + instant upload (SHA-256 dedup) + presigned direct upload.
- **Storage backends**: 14 hot-switchable drivers persisted across restarts — local disk, S3/MinIO, cloud vendor presets (Aliyun OSS, Tencent COS, Baidu BOS, Kingsoft KS3, Huawei OBS), WebDAV, FTP/FTPS, SFTP, GCS, Azure Blob, HDFS, OneDrive.
- **Admin console**: dashboard, file/user management, audit log, site config persisted in DB (7-section settings navigation incl. P2P), transfer logs.
- **User system**: quotas, API keys, OIDC SSO login, notifications (in-app + webhook + SMTP).
- **Federated P2P (opt-in)**: every server is a symmetric P2P node — hot-toggle federation in admin settings (empty registry = official public registry); end-to-end encrypted device-to-device direct transfer (p2pc protocol v4: multi-file manifests, zstd, IPv6 + port mapping, relay fallback) bundled with the server image, NAS packages, and the desktop client; MCP endpoint for AI clients (18 tools; the p2p_* direct-transfer tools were retired with the PigeonBeam split — 3 federation tools remain).
- **Ops-ready**: Prometheus metrics, OpenTelemetry tracing (opt-in), health checks, Helm chart with ServiceMonitor, multi-arch images.
- Light by design: a parcel locker, not a cloud drive.

## Quick start

```bash
docker compose up -d          # or: BUILD=1 make compose-up (local build, run make setup first)
```

Frontend entry `http://localhost:12345` (`PB_API_PORT`, default 12345) — the frontend image also proxies the API, the server publishes no ports. `PB_HTTP_PORT` (default 80) only applies to the optional nginx profile. There is **no default admin password** since 3.0.0: leave `PB_ADMIN_PASSWORD` empty and the site starts in `/setup` first-run wizard mode — open the site and create the admin there. Set `PB_ADMIN_PASSWORD` only for unattended deployments.

Build from source:

```bash
git clone https://github.com/pigeonbox/pigeonbox.git && cd pigeonbox
make setup     # fetch module repos (idempotent)
make test      # Go tests + frontend typecheck
make build     # workspace build → bin/
make smoke     # boot server & smoke-test
```

## Documentation

- Architecture (Mermaid): [docs/architecture.md](docs/architecture.md)
- Roadmap: [ROADMAP.md](ROADMAP.md) · Changelog: [CHANGELOG.md](CHANGELOG.md)
- Contributing: [CONTRIBUTING.md](CONTRIBUTING.md) · Security policy: [SECURITY.md](SECURITY.md)
- Environment variables: [docs/ENVIRONMENT_VARIABLES.md](docs/ENVIRONMENT_VARIABLES.md)

## License

[Apache-2.0](LICENSE) © PigeonBox
