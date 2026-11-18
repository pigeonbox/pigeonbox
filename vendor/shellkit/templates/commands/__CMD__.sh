#!/usr/bin/env bash
#
# {{CMD}} 子命令。新增命令只要复制本文件改名，分发器不用动。
# 注册发生在 source 时，所以 cli_cmd 必须写在文件末尾。

cmd_{{CMD}}() {
  local __target __force=""

  cli_opt_init
  cli_opt __force --force -f
  cli_opt __target --target -t 1
  cli_opts "$@" || return $?

  app_conf_load || return $?
  if [ -z "$__target" ]; then
    __target=$(conf_get TARGET "localhost")
  fi

  log_info "$(_t 'running'): {{CMD}}"
  log_info "$(_t 'target'): $__target"
  if [ "$__force" = "1" ]; then
    log_warn "$(_t 'force flag is set')"
  fi

  # TODO: 这里写真正的逻辑。日志走 stderr，stdout 只留数据。
  log_ok "{{CMD}} $(_t 'finished')"
  return "$SK_OK"
}

# 描述不套 _t：msgid 里带占位符必然匹配不到任何译文，只会留下一条死键。
# 工程自己的命令名怎么描述，是工程自己的事。
cli_cmd {{CMD}} "{{CMD}} command" "{{CMD}} [<options>]"
