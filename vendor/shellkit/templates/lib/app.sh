#!/usr/bin/env bash
#
# 应用装配层：定配置路径、加载全部命令、放共用函数。
# 命令文件自己在末尾调用 cli_cmd 注册，因此这里不需要任何命令清单。

APP_CONF="${APP_CONF:-$APP_ROOT/config}"
export APP_CONF

# app_conf_load —— 让后续 conf_get / conf_set 都落到 APP_CONF
app_conf_load() {
  conf_init "$APP_CONF" || return $?
}

for __app_cmd_file in "$APP_ROOT"/commands/*.sh; do
  if [ -r "$__app_cmd_file" ]; then
    . "$__app_cmd_file"
  fi
done

if [ -n "${__app_cmd_file:-}" ]; then
  unset __app_cmd_file
fi
