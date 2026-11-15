# Platform Compatibility Matrix（六适配平台兼容矩阵）

> **本文件由 scripts/gen-platform-matrix.sh 从
> deploy/platforms/capabilities.yaml 生成，禁止手改**（CI 对账：生成物 == 生成结果）。
> 能力判据与实测由 scripts/check-platform-capabilities.sh 把关（pigeonbox#365）。

## 能力矩阵

| 能力 | fnos | qnap | openwrt | synology | ugreen | terramaster |
|---|---|---|---|---|---|---|
| native_sso | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ |
| lifecycle_hooks | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| backup_hook | ✅ | ✅ | ✅ | ✅ | ❌ | ❌ |
| local_file_import | ✅ | ✅ | ✅ | ❓unknown | ❓unknown | ❓unknown |
| p2p_client | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| container_runtime | ❌ | ❌ | ❌ | ✅ | ✅ | ✅ |

## 平台元数据

| 平台 | 仓库 | 架构 | OS | 安装包格式 | 升级路径 | 真机验证 |
|---|---|---|---|---|---|---|
| fnos | pigeonbox/fnos | x86_64, arm64 | fnOS（飞牛） | fpk | 应用中心升级（install/upgrade/uninstall 回调） | ✅ 真机已验 |
| qnap | pigeonbox/qnap | x86_64, arm64 | QTS 4.5+ | qpkg | QTS 套件升级（package_routines 钩子） | 🟡 部分已验 |
| openwrt | pigeonbox/openwrt | x86_64, aarch64_generic | OpenWrt/iStoreOS 22.03/23.05、25.12+ | ipk + apk | opkg/apk 升级（preupgrade 快照钩子） | ⏳ 待真机 |
| synology | pigeonbox/synology | noarch | DSM 7.2+ | spk | 套件中心升级（preupgrade/postupgrade 钩子） | ⏳ 待真机 |
| ugreen | pigeonbox/ugreen | any | UGOS Pro（1281+） | zip（compose；upk 二期） | 改 .env 版本 tag 重部署（无包管理钩子） | ⏳ 待真机 |
| terramaster | pigeonbox/terramaster | any | TOS 5/6/7 | zip（compose；tos7 tpk 二期） | 改 .env 版本 tag 重部署（无包管理钩子） | ⏳ 待真机 |

## 未决项（unknown ⇒ 必须有 TODO）

- **synology / local_file_import**：TODO(hub#365): 仓内无 local_file_import 直接证据（能力随官方 server 镜像）；待镜像内容断言或 env 样例补 PB_LOCAL_IMPORT_* 后转 true
- **ugreen / local_file_import**：TODO(hub#365): 仓内无 local_file_import 直接证据（能力随官方 server 镜像）；待镜像内容断言或 env 样例补 PB_LOCAL_IMPORT_* 后转 true
- **terramaster / local_file_import**：TODO(hub#365): 仓内无 local_file_import 直接证据（能力随官方 server 镜像）；待镜像内容断言或 env 样例补 PB_LOCAL_IMPORT_* 后转 true

## 判据索引（每字段的验收判据，CI 实测）

| 平台 | 能力 | 值 | 判据 |
|---|---|---|---|
| fnos | native_sso | True | grep:adapter/sso/sso.go:X-Trim |
| fnos | lifecycle_hooks | True | file:fnos/cmd/upgrade_callback |
| fnos | backup_hook | True | grep:fnos/cmd/upgrade_callback:bak- |
| fnos | local_file_import | True | grep:fnos/app/www/openapi.json:本地文件免上传导入 |
| fnos | p2p_client | True | grep:DEPS.env:P2PC_REF |
| fnos | container_runtime | False | nogrep:docker-compose |
| qnap | native_sso | True | grep:adapter/sso/sso.go:NAS_SID |
| qnap | lifecycle_hooks | True | file:qpkg/package_routines |
| qnap | backup_hook | True | grep:qpkg/package_routines:bak- |
| qnap | local_file_import | True | grep:qpkg/shared/www/openapi.json:本地文件免上传导入 |
| qnap | p2p_client | True | grep:DEPS.env:P2PC_REF |
| qnap | container_runtime | False | absent:docker-compose.yml |
| openwrt | native_sso | False | absent:adapter/sso/sso.go |
| openwrt | lifecycle_hooks | True | file:openwrt/pigeonbox.postinst |
| openwrt | backup_hook | True | grep:openwrt/preupgrade_backup:bak- |
| openwrt | local_file_import | True | grep:web/dist/openapi.json:本地文件免上传导入 |
| openwrt | p2p_client | True | grep:DEPS.env:P2PC_REF |
| openwrt | container_runtime | False | absent:docker-compose.yml |
| synology | native_sso | False | absent:adapter/sso/sso.go |
| synology | lifecycle_hooks | True | file:spk/scripts/postupgrade |
| synology | backup_hook | True | grep:spk/scripts/preupgrade:bak- |
| synology | local_file_import | unknown | todo: TODO(hub#365): 仓内无 local_file_import 直接证据（能力随官方 server 镜像）；待 |
| synology | p2p_client | True | grep:README.md:随包 p2pc |
| synology | container_runtime | True | file:spk/package/compose.yml |
| ugreen | native_sso | False | absent:adapter/sso/sso.go |
| ugreen | lifecycle_hooks | False | nogrep:postinst|preupgrade|postupgrade |
| ugreen | backup_hook | False | nogrep:bak- |
| ugreen | local_file_import | unknown | todo: TODO(hub#365): 仓内无 local_file_import 直接证据（能力随官方 server 镜像）；待 |
| ugreen | p2p_client | True | grep:README.md:随包 p2pc |
| ugreen | container_runtime | True | file:deploy/compose.yml |
| terramaster | native_sso | False | absent:adapter/sso/sso.go |
| terramaster | lifecycle_hooks | False | nogrep:postinst|preupgrade|postupgrade |
| terramaster | backup_hook | False | nogrep:bak- |
| terramaster | local_file_import | unknown | todo: TODO(hub#365): 仓内无 local_file_import 直接证据（能力随官方 server 镜像）；待 |
| terramaster | p2p_client | True | grep:README.md:随包 p2pc |
| terramaster | container_runtime | True | file:deploy/compose.yml |

