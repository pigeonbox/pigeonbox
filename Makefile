.PHONY: setup update build test vet lint smoke smoke-full docker compose-up compose-down nas-check nas-sync trainctl train-verify train-bump train-bump-local train-tag train-advance train-finalize clean

# PigeonBox umbrella —— 一次 clone 拉齐全部模块并统一构建。
# 模块仓库(contracts/core/server/frontend/fnos/openwrt/p2p/kit + NAS 打包四仓
# synology/qnap/ugreen/terramaster)由 scripts/setup.sh 拉入本目录,
# go.work 联编本地改动(打包四仓纯 shell 不参与);各模块亦可独立构建(go.mod 均为正式版本依赖)。

SERVER_IMAGE ?= pigeonbox-server:dev

# go.work 引用的模块目录缺失时,go 命令只会报晦涩的 "go.work 解析错误"——
# 先探目录,缺了给明确指引(build/test/vet 共用)。
WORKSPACE_GUARD = for d in $$(awk '/^use \($$/,/^\)$$/' go.work | grep -oE '\./[A-Za-z0-9_-]+'); do \
	  if [ ! -d "$$d" ]; then \
	    echo "✗ 模块目录 $$d 不存在——go.work 需要它:若曾用 SETUP_<名>=0 跳过拉取,先跑 make setup;或手动移除 go.work 里对应的 use 行" >&2; exit 1; fi; done

## 全流程:拉模块 → 全仓测试 → 构建 server 二进制
all: setup test build

setup:            ## 拉齐/更新十三个模块仓库(幂等;SETUP_<名>=0 可跳过任一)
	./scripts/setup.sh

update: setup

build:            ## workspace 联编 Go 模块(产物 bin/)
	@$(WORKSPACE_GUARD)
	go build -o bin/ ./contracts/... ./core/... ./server/... ./p2p/... ./kit/...
	@echo "✓ build OK → bin/"

test:             ## 全仓 Go 测试 + 前端双仓(typecheck+core 单测)
	@$(WORKSPACE_GUARD)
	go test ./contracts/... ./core/... ./server/... ./fnos/... ./openwrt/... ./qnap/... ./p2p/... ./kit/...
	cd frontend-core && ([ -d node_modules ] || npm ci) && npm run typecheck && npm test
	cd frontend && ([ -d node_modules ] || npm ci) && npm run typecheck

vet:
	@$(WORKSPACE_GUARD)
	go vet ./contracts/... ./core/... ./server/... ./fnos/... ./openwrt/... ./qnap/... ./p2p/... ./kit/...

lint:             ## golangci-lint 各 Go 模块（CI 同款门禁；本地提交前建议跑，防 lint 溜进 CI）
	@command -v golangci-lint >/dev/null || { echo "golangci-lint 未安装: brew install golangci-lint"; exit 1; }
	for m in contracts core server fnos openwrt qnap p2p kit; do echo "── $$m"; (cd $$m && golangci-lint run ./...); done
	@echo "✓ lint OK"

smoke: build      ## 本地起 server 并跑冒烟(健康检查/admin 登录;全量断言见 scripts/smoke-full.sh)
	cd server && mkdir -p data logs && (PB_JWT_SECRET=$$(openssl rand -hex 32) \
	  go run ./cmd/server --config ./configs/config.yaml & echo $$! > /tmp/pb.pid; \
	  sleep 8; \
	  curl -sf http://localhost:12345/live && \
	  curl -sf -X POST http://localhost:12345/admin/login -H 'Content-Type: application/json' \
	    -d '{"username":"admin","password":"admin123"}' | head -c 80 && echo "" && \
	  echo "✓ smoke OK"; kill $$(cat /tmp/pb.pid) 2>/dev/null; true)

smoke-full:       ## 全能力真机冒烟(46 项断言;独立端口/临时数据目录/临时 Redis,跑完即清理)
	bash scripts/smoke-full.sh

docker:           ## 本地构建双镜像: server(纯后端) + frontend(nginx 静态+反代)
	docker build -f server/Dockerfile -t $(SERVER_IMAGE) .
	docker build -f frontend/Dockerfile -t ghcr.io/pigeonbox/frontend:latest frontend/

compose-up:       ## docker compose 起前后端分离栈(默认拉 ghcr 镜像;BUILD=1 本地构建;NGINX=1 加反代)
	docker compose up -d $${BUILD:+--build} $${NGINX:+--profile nginx}

compose-down:
	docker compose --profile nginx down

nas-check:         ## NAS 打包三仓共享资产漂移校验(对 deploy/nas/ 模板;qnap 已切原生不消费)
	bash deploy/nas/sync.sh check --all

nas-sync:          ## hub 模板物化到 NAS 打包三仓(改模板后跑;CI 有漂移门禁兜底)
	bash deploy/nas/sync.sh sync --all

# ── 发布列车 v2(trainctl 状态机编排器;设计稿 docs/specs/2026-10-12-release-train-v2-design.md)──
# 常规发版全部在 hub CI 跑(train-orchestrator 工作流);本地目标=薄壳 dispatch + 应急逃生门。
# v1 bash(scripts/release-train.sh)过渡期保留作回退,1.20.0 首航 shipped 后删除。

trainctl:          ## 构建编排器 → bin/trainctl
	cd release/trainctl && GOWORK=off go build -o ../../bin/trainctl .

train-verify: trainctl ## 发布列车对账(CI 同款 train-verify 工作流;漂移即失败)
	./bin/trainctl verify

train-bump:        ## 开新列车(CI 执行): make train-bump TRAIN=1.20.0 [SET="core=v0.19.0 core_pin=v0.19.0"] [HOTFIX=true]
	gh workflow run train-orchestrator.yml -R pigeonbox/pigeonbox -f phase=bump -f train=$(TRAIN) $(if $(SET),-f set="$(SET)") $(if $(HOTFIX),-f hotfix=$(HOTFIX))
	@echo "已 dispatch;跟进度: gh run list -R pigeonbox/pigeonbox --workflow train-orchestrator.yml --limit 3"

train-bump-local: trainctl ## 应急逃生门:本地直跑 bump(缺省 dry-run 零落盘;ARGS="--push" 实际执行)
	./bin/trainctl bump TRAIN=$(TRAIN) $(ARGS)

train-tag: trainctl  ## 手动推 tag 阶段(通常由 advance 自动衔接,仅应急单独跑)
	./bin/trainctl tag

train-advance: trainctl ## 手动推进状态机(回调/sweep 之外的应急唤醒)
	./bin/trainctl advance

train-finalize: train-advance ## 别名:终验并出 hub v<train> Latest 快照(advance 能进则进)

clean:
	rm -rf bin/
