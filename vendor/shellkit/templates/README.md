# {{NAME}}

{{DESCRIPTION}}

用 [shellkit](https://github.com/yi-nology/shellkit) 生成的 shell 工具骨架。

## 结构

    bin/{{NAME}}       入口，只负责装配
    lib/app.sh         装配层：配置路径 + 加载命令
    commands/*.sh      每个子命令一个文件，末尾用 cli_cmd 注册
    vendor/shellkit/   随工程走的库副本（版本 {{SHELLKIT_VERSION}}）
    tests/             断言库 + 逐文件执行器

## 常用

    make test        # 全部测试
    make lint        # shellcheck
    make fmt         # shfmt 只检查不改
    make upgrade     # 升级到当前模板
    make completion  # 输出 bash 补全脚本
    make version     # 打印工程用的库版本
    ./bin/{{NAME}} --help

## 加一个子命令

    cp commands/{{CMD}}.sh commands/newcmd.sh   # 改函数名与 cli_cmd 行
    make test

## 模板变量

模板目录下的 `template.config` 声明变量，一行一个 `KEY=VALUE`：

    DESCRIPTION=一行说明

模板里用 `{{DESCRIPTION}}` 引用。生成工程时可以覆盖：

    shellkit new ./mytool --set DESCRIPTION="我的工具"

## 钩子

模板目录下的 `template.hooks.d/pre` 与 `post` 是可执行脚本，
分别在落盘前与落盘后运行。它们拿到的环境变量有
`SHELLKIT_PROJECT_DIR`、`SHELLKIT_PROJECT_NAME`、`SHELLKIT_PROJECT_COMMANDS`、
`SHELLKIT_TEMPLATE_VERSION`，以及每个模板变量。

钩子失败会让生成失败 —— 这是故意的：钩子没做成的工程不算生成成功。

## 升级

生成的工程里有一份 `.shellkit-manifest`，记着模板版本与每个文件的指纹：

    make upgrade                                # 更新没被你改过的文件
    shellkit upgrade /path/to/project           # 同上，直接调 CLI
    shellkit upgrade /path/to/project --check   # 只看会改什么，不动文件

你改过的文件一律留着不动，并告诉你哪些被跳过了。

`make upgrade` 优先用工程自带的 `vendor/shellkit/shellkit`，没有才退回 PATH 上的
`shellkit` —— 工程被 vendor 到别的机器上、PATH 上没装 shellkit 时也能跑。

## 补全

    make completion > /etc/bash_completion.d/{{NAME}}

补全脚本从本工程自己的注册表生成：程序名是 `{{NAME}}`，子命令是你写的那些。
新增子命令后重跑一次即可。

不想装到系统目录就装给自己：

    make completion > ~/.local/share/bash-completion/completions/{{NAME}}

也可以直接问入口要：`./bin/{{NAME}} --completion bash`（zsh 用 `--completion zsh`）。

## 版本

    make version

打印两行：`library` 是工程里那份库副本的版本（`vendor/shellkit/VERSION`），
`template` 是生成工程时用的模板版本。两个号对不上说明模板与库不是同一版了 ——
跑一次 `make upgrade` 追平。
