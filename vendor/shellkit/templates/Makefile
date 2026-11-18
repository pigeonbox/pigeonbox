# {{NAME}} 的构建入口。不依赖 make 也能跑：bash tests/run.sh

SHELL := /bin/bash

# 工程自带的 shellkit 副本。工程可能被 vendor 到别的机器上，
# 那时 PATH 上不一定有 shellkit —— 有自带副本就用它。
VENDOR_CLI := vendor/shellkit/shellkit

.PHONY: help test lint fmt upgrade completion version vendor

help:
	@printf '%s\n' \
	  'make test        {{MSG_HELP_TEST}}' \
	  'make lint        {{MSG_HELP_LINT}}' \
	  'make fmt         {{MSG_HELP_FMT}}' \
	  'make upgrade     {{MSG_HELP_UPGRADE}}' \
	  'make completion  {{MSG_HELP_COMPLETION}}' \
	  'make version     {{MSG_HELP_VERSION}}' \
	  'make vendor      {{MSG_HELP_VENDOR}}'

test:
	@bash tests/run.sh

lint:
	@if command -v shellcheck >/dev/null 2>&1; then \
	  shellcheck -S warning -x bin/*{{NAME}} lib/*.sh commands/*.sh tests/*.sh; \
	  else echo "shellcheck not installed, skipping"; fi

fmt:
	@if command -v shfmt >/dev/null 2>&1; then \
	  shfmt -d -i 2 -ci bin/*{{NAME}} lib/*.sh commands/*.sh tests/*.sh; \
	  else echo "shfmt not installed, skipping"; fi

# 升级与镜像的逻辑在 shellkit 这个命令里，不在库里，所以要一个能跑的 shellkit：
# 先用工程自带的副本，没有就退回 PATH 上的 shellkit，都没有就报前置条件错。
# 找不到 shellkit 时库恰恰不可用 —— 这条文案没法在运行期翻译，
# 是生成工程时按生成器的语言塞进 MSG_* 变量的（--set 可覆盖）。
upgrade:
	@if [ -f "$(VENDOR_CLI)" ]; then \
	  bash "$(VENDOR_CLI)" upgrade "$(CURDIR)"; \
	elif command -v shellkit >/dev/null 2>&1; then \
	  shellkit upgrade "$(CURDIR)"; \
	else \
	  printf '%s\n' "{{MSG_NO_SHELLKIT}}" >&2; \
	  exit 3; \
	fi

# 把库镜像进工程。镜像落在 vendor/shellkit/，就是工程自带副本的位置。
vendor:
	@if [ -f "$(VENDOR_CLI)" ]; then \
	  bash "$(VENDOR_CLI)" vendor "$(CURDIR)"; \
	elif command -v shellkit >/dev/null 2>&1; then \
	  shellkit vendor "$(CURDIR)"; \
	else \
	  printf '%s\n' "{{MSG_NO_SHELLKIT}}" >&2; \
	  exit 3; \
	fi

# 补全脚本：优先用工程自己的入口生成 —— 程序名与子命令都取自本工程，
# 新增子命令后重跑一次即可。工程入口不在时再退回 shellkit 副本或 PATH 上的 shellkit。
completion:
	@if [ -f "bin/{{NAME}}" ]; then \
	  bash "bin/{{NAME}}" --completion bash; \
	elif [ -f "$(VENDOR_CLI)" ]; then \
	  bash "$(VENDOR_CLI)" completion bash; \
	elif command -v shellkit >/dev/null 2>&1; then \
	  shellkit completion bash; \
	else \
	  printf '%s\n' "{{MSG_NO_COMPLETION}}" >&2; \
	  exit 3; \
	fi
	@printf '%s\n' \
	  "{{MSG_COMPLETION_SYSTEM}}" \
	  "{{MSG_COMPLETION_USER}}" >&2

# 工程用的库版本：库副本在 vendor/shellkit/ 里，版本号写在 VERSION 文件里。
version:
	@if [ ! -r vendor/shellkit/VERSION ]; then \
	  printf '%s\n' "{{MSG_NO_VENDOR}}" >&2; \
	  exit 3; \
	fi; \
	printf 'library %s\n' "$$(tr -d '[:space:]' <vendor/shellkit/VERSION)"; \
	__tpl=$$(sed -n 's/^template_version=//p' .shellkit-manifest 2>/dev/null | tr -d '[:space:]'); \
	if [ -n "$$__tpl" ]; then printf 'template %s\n' "$$__tpl"; fi
