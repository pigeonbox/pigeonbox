# PigeonBox

**Anonymous code-based file & text sharing — like picking up a parcel.** Upload, get a pickup code, share the code; the recipient enters the code and downloads. No registration required.

PigeonBox is the Go multirepo workspace of the [pigeonbox](https://github.com/orgs/pigeonbox/repositories) organization. This repository is the **umbrella (hub)**: no business code, only tooling to assemble the module repos into a buildable workspace.

## Repositories

| Repo | Role | Version |
|------|------|---------|
| [contracts](https://github.com/pigeonbox/contracts) | Contract layer: error codes + Thrift-generated types + IDL source of truth (zero business deps) | v0.10.1 |
| [core](https://github.com/pigeonbox/core) | Business core library: 17 domain services (incl. config) + repo/storage + `bootstrap.Bootstrap()` | v0.16.2 |
| [server](https://github.com/pigeonbox/server) | Deployable app: thin main + `pb` CLI + configs + Dockerfile (pure backend since 0.9.0) | v0.15.13 |
| [frontend](https://github.com/pigeonbox/frontend) | Frontend shell: neutral build + nginx image (released with server; host adapters live in platform repos' `web/`) | with server `v*` |
| [frontend-core](https://github.com/pigeonbox/frontend-core) | Shared frontend core: platform-agnostic app (Vue3 + TS + Vite + Element Plus) + host adapter SPI, consumed as Release tgz | v0.1.8 |
| [desktop](https://github.com/pigeonbox/desktop) | Desktop client: Tauri 2 tray app connecting to any PigeonBox server, p2pc sidecar direct transfer | desktop-v1.16.0 |
| [fnos](https://github.com/pigeonbox/fnos) | fnOS (fnNAS) native app: single-process fpk + official open-platform SSO integration (Docker image discontinued) | v1.16.0 |
| [openwrt](https://github.com/pigeonbox/openwrt) | OpenWrt/iStoreOS native packages (ipk + apk): procd-managed, UCI config, LuCI integration, single port 12345 with embedded Web UI | v1.16.0 |
| [synology](https://github.com/pigeonbox/synology) | Synology DSM 7.2+ package (SPK, noarch): Container Manager compose shell with install wizard | v1.16.0 |
| [qnap](https://github.com/pigeonbox/qnap) | QNAP QTS native app (QPKG, x86_64 + arm_64): single process, no Container Station needed (QTS 4.5+), QTS account SSO | v1.16.0 |
| [ugreen](https://github.com/pigeonbox/ugreen) | UGREEN UGOS Pro deployment package: paste-in Docker compose project (incl. CN mirror variant) | v1.16.0 |
| [terramaster](https://github.com/pigeonbox/terramaster) | TerraMaster TOS 5/6/7 deployment package: Docker Manager project import | v1.16.0 |
| [p2p](https://github.com/pigeonbox/p2p) | P2P federated registry + device transfer: node leases, passcode routing, WS signaling, encrypted relay, p2pc CLI/web clients | v0.6.0 |
| [kit](https://github.com/pigeonbox/kit) | Shared Go toolkit: 28 general-purpose packages with zero ecosystem deps | v0.3.1 |
| [charts](https://github.com/pigeonbox/charts) | Kubernetes Helm chart (frontend + server split deployments, multi-replica public/admin topology) | pigeonbox-2.0.11 |

Dependency direction (CI-enforced): `server / fnos / openwrt / qnap ──► core ──► contracts`; frontend: `shell & platform-repo web/ ──► frontend-core (tgz) ──► contracts (TS d.ts)`; `core` and `p2p` consume `kit` on demand (kit is a zero-ecosystem-dep foundation); `p2p` is a leaf repo with a zero-dep business chain; desktop connects over HTTP with no build-time dependency.

## Highlights

- **Share text or files anonymously** with pickup codes, expiry by time and/or download count, optional access password (bcrypt).
- **Chunked uploads** with resume + instant upload (SHA-256 dedup) + presigned direct upload.
- **Storage backends**: 14 hot-switchable drivers persisted across restarts — local disk, S3/MinIO, cloud vendor presets (Aliyun OSS, Tencent COS, Baidu BOS, Kingsoft KS3, Huawei OBS), WebDAV, FTP/FTPS, SFTP, GCS, Azure Blob, HDFS, OneDrive.
- **Admin console**: dashboard, file/user management, audit log, site config persisted in DB, transfer logs.
- **User system**: quotas, API keys, OIDC SSO login, notifications (in-app + webhook + SMTP).
- **Federated P2P (opt-in)**: multi-node federation with passcode-based routing; end-to-end encrypted device-to-device direct transfer (p2pc protocol v4: multi-file manifests, zstd, IPv6 + port mapping, relay fallback) via the desktop client's p2pc sidecar; MCP endpoint for AI clients.
- **Ops-ready**: Prometheus metrics, OpenTelemetry tracing (opt-in), health checks, Helm chart with ServiceMonitor, multi-arch images.
- Light by design: a parcel locker, not a cloud drive.

## Quick start

```bash
docker compose up -d          # or: BUILD=1 make compose-up (local build, run make setup first)
```

Frontend entry `http://localhost:12345` (`PB_API_PORT`, default 12345) — the frontend image also proxies the API, the server publishes no ports. `PB_HTTP_PORT` (default 80) only applies to the optional nginx profile. Default admin is `admin / admin123` — override with `PB_ADMIN_PASSWORD` in production (in production mode the server refuses to create the default admin without it; the `/setup` wizard is the escape hatch).

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
