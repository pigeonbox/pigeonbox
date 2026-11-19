<!-- 生成物：由 tools/ai_doc.sh 拼装，请勿手改。改 docs/ai/project.head.md 再跑 shellkit docs。 -->

# 这个工程：{{NAME}}

这是一个 shellkit 工程。库在 `{{VENDOR_DIR}}/`，随工程走，不改全局环境。

## 结构

    bin/{{NAME}}          入口：定位自身 -> 加载库与应用 -> cli_run
    lib/app.sh            装配层：配置路径 + 加载 commands/*.sh
    commands/*.sh         每个子命令一个文件，末尾 cli_cmd 注册自己
    {{VENDOR_DIR}}/      库副本（版本见 {{VENDOR_DIR}}/VERSION）
    tests/                断言库 + 逐文件执行器
    config.example        配置模板

## 加一个子命令：改两处，分发器不用动

1. 新建 `commands/<cmd>.sh`，复制 `commands/{{CMD}}.sh` 改名，改函数名 `cmd_<cmd>` 与
   末尾的 `cli_cmd <cmd> "描述" "<cmd> [选项]"`。
2. 新命令属于另一个分组时，在 `cli_cmd` 前加一行 `cli_group "分组名"`。
3. `make test`。

命令名带短横会自动派发到下划线函数名（`install-self` -> `cmd_install_self`）。

## 改行为之前先看这里

- 配置读写一律 `conf_get_any` / `conf_set`，不要自己 `grep` 配置文件。
- 日志一律 `log_*`（走 stderr），不要 `echo` 到 stdout。
- 想改 `{{VENDOR_DIR}}/` 里的东西？它是镜像，**会被下一次 vendor 覆盖**。
  需要新能力就升级库版本，而不是就地改。

## 验证

    make test          # 必须绿
    make lint          # shellcheck（装了才跑）
    ./bin/{{NAME}} --help

## 通用规则：用 shellkit 写 Bash

shellkit 是一个 Bash 库加脚手架：日志、配置、下载校验、重试、单实例锁、CLI 框架、i18n
都已经写好且测过。**你要做的是装配，不是重新实现一遍。**

### 三条硬事实

1. **基线是 Bash 3.2+**（macOS 自带的 /bin/bash 就是 3.2.57）。不是 4.x，不是 5.x。
2. **stdout 只给数据，日志一律 stderr。** 所以 `v=$(conf_get KEY)` 永远是干净的。
3. **出参用 `printf -v "$var"`，函数不直接改调用方变量。** 3.2 没有 nameref。

### 禁用语法对照

写之前先看这张表。左边这些**在 3.2 上直接崩**，不是风格问题。

| 别写 | 写这个 | 在 3.2 上会怎样 |
|---|---|---|
| `declare -A m` | `case` 分派，或两个平行数组 | 报 `declare: -A: invalid option` |
| `${v^^}` / `${v,,}` | `printf '%s' "$v" \| tr a-z A-Z` | `bad substitution` |
| `local -n ref=$1` | 出参：`printf -v "$outvar" '%s'` | 报无效选项 |
| `mapfile -t a < f` | `while IFS= read -r l; do ...; done < f` | `command not found` |
| `[[ -v x ]]` | `[ -n "${x:-}" ]` | 条件表达式语法错 |
| `"${arr[@]}"`（数组可能为空） | `${arr[@]+"${arr[@]}"}` | `set -u` 下 unbound variable |
| `arr+=(x)` | `arr[${#arr[@]}]=x` | 能跑，但别和空数组展开混用 |

其余注意：`local -a` 声明数组可以，但未赋值的空数组在 `set -u` 下遍历会报错，
一律写成 `${arr[@]+"${arr[@]}"}`。

### 动手前

1. **先找现成的。** 需要的能力大概率已经在 `lib/core/` 里：日志、配置、下载、校验、
   重试、锁、清理、交互、CLI、i18n。不要先写一版再想着替换。
2. **不确定签名就查 `docs/REFERENCE.md`，不要发明函数名。** 幻觉出来的 API
   （比如 `conf_require`、`log_success`）会让脚本在运行时才炸，而且错误信息看不懂。
3. **写完就跑验证命令**（见下）。不要声称"应该能跑"。

### 常见任务的落点

| 你想到的事 | 用什么 |
|---|---|
| 打一条日志 | `log_info` / `log_ok` / `log_warn` / `log_error` / `log_debug` / `log_section` |
| 失败就退出并给退出码 | `die` / `fail` / `require_cmd` / `require_root` / `require_file` |
| 读配置，环境变量优先 | `conf_init` 之后用 `conf_get_any KEY DEFAULT` |
| 改配置且要幂等 | `conf_set`；改任意文件用 `fs_ensure_line` / `fs_ensure_block` |
| 写文件不想写坏 | `fs_atomic_write`（写内容）；搬文件用 `fs_atomic_copy`（逐字节一致）；备份用 `fs_backup` |
| 下载并校验 | `net_download URL DEST [SHA256]`，镜像回退已内置 |
| 解开 tar / zip 包 | `archive_extract ARCHIVE DEST [SHA256]`（挡路径穿越与软链逃逸，失败不留半份）；先看内容用 `archive_list` |
| 只想演练不想落盘 | `SHELLKIT_DRY_RUN_FILES=1`：`fs_*` / `conf_*` 的写原语只打印计划不写盘（`SHELLKIT_DRY_RUN` 只管 `run` / `svc`） |
| 等端口 / 等 HTTP | `net_wait_port` / `net_wait_http` |
| 跑命令，失败即停 | `run systemctl restart nginx`；`SHELLKIT_DRY_RUN=1` 只打印 |
| 命令行里有口令/令牌 | `run` 的日志自动脱敏；启发式认不出来的用 `run --secret-arg N` / `run --redact-value V` 显式声明 |
| 跑命令但要自己判成败 | `run --no-die cmd`（默认的 `run` 失败即 `die`，`die` 的 `exit` 不受 `if`/`||` 约束） |
| 失败重试几次 | `retry 5 curl -fsS "$url" -o x` |
| 保证同时只跑一个实例 | `lock_acquire deploy 30`，拿到即入清理栈 |
| 退出时一定要收尾 | `trap_push 'rm -rf "$workdir"'` + `trap_install` |
| 问用户一个问题 | `ask` / `ask_yn` / `ask_choice` / `confirm`（都支持超时与默认值） |
| 加一个子命令 | `cli_cmd` 注册 + `cmd_<name>` 实现，分发器不用动 |
| 输出中文/英文 | `_t 'english msgid'`，译文在 `locale/` |
| 调 HTTP 接口 | `net_request GET URL [--header 'K: V'] [--json BODY]`（`SK_HTTP_CODE` / `SK_HTTP_BODY` / `SK_HTTP_HEADERS`）；要 JSON 就 `net_json ... --path a.b.c` |
| 读 dotenv | `conf_load_dotenv FILE`（只进配置层）；要导出给子进程用 `conf_source FILE` |
| 同一条命令并发跑 N 份 | `run_concurrent 8 -- ./deploy.sh`（stdout 给成功数，stderr 逐实例标注） |
| 起/停/查系统服务 | `svc_start` / `svc_restart` / `svc_is_active`（写类动作吃 `SHELLKIT_DRY_RUN`；macOS 上写类动作返回 3） |
| 比较版本号 | `ver_cmp` / `ver_gt` / `ver_lt` / `ver_eq`（纯 bash 分段比较，别用 `sort -V`；非法输入返回 2，不伪装成「相等」） |
| 输出机器可读状态 | `SHELLKIT_STATUS_MODE=machine` + `status_emit STATE 人类文案`（再按需 `status_version` / `status_extra`） |
| 日志要能进采集系统 | `SHELLKIT_LOG_FORMAT=json`；按级别过滤用 `SHELLKIT_LOG_LEVEL=warn`；落文件用 `SHELLKIT_LOG_FILE=/var/log/x.log` |
| 新工程要带自定义变量 | `shellkit new ./x --set KEY=VALUE`；变量声明在模板的 `template.config` |
| 已有工程跟上模板更新 | `shellkit upgrade ./x`（本地改过的文件会跳过并告警） |

### 交付前自检

    bash -n 改过的脚本            # 语法
    shellcheck -S warning -x ...  # 有则跑
    make test                     # 工程里的测试
    ./bin/<name> --help           # 帮助能不能出来

三条判据要同时成立才算过：**退出码为 0**、**没有 FAIL 行**、**你自己看过输出**。
只看退出码会漏掉"命令根本没跑"，只看输出会漏掉静默失效。

### 退出码

| 码 | 含义 |
|---|---|
| 0 | 成功 |
| 1 | 一般错误 |
| 2 | 用法错（参数不对） |
| 3 | 前置条件不满足（缺命令、非 root、该交互却没有默认值） |
| 4 | 网络失败 |
| 5 | 校验失败（sha256 不匹配、文档与代码不一致） |

返回码就是接口的一部分：**不要用 `exit 1` 糊弄所有失败**。
