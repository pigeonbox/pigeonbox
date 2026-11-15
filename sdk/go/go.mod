module github.com/pigeonbox/pigeonbox/sdk/go

go 1.26.5

// 契约钉版：请求/响应模型与错误码直接复用 contracts 生成物。
// 升这个版本 = 契约破坏性变更在本模块编译期报红（而不是线上 404/400）。
require github.com/pigeonbox/contracts v0.25.0

require github.com/apache/thrift v0.24.0 // indirect
