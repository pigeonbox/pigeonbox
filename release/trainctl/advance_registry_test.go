package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// registryHasTag 的判据必须能区分「存在」与「不存在」。
//
// 关键：registry 对「包存在但要认证」返回 401/403 ⇒ **401/403 也算存在**
// （否则私有包永远判「未发布」⇒ 列车永远卡在 tagged）。
//
// ⚠️ 本测试打的是**真实函数**（registryHasTagAt，baseURL 可注入）——
// 若只测「另写一份同逻辑的副本」⇒ 真实代码改了它照样全绿 ⇒ 门禁是摆设。

func TestRegistryHasTag_DistinguishesExistFromMissing(t *testing.T) {
	cases := []struct {
		name   string
		status int
		want   bool
	}{
		{"200 存在", http.StatusOK, true},
		{"401 存在但需认证", http.StatusUnauthorized, true},
		{"403 存在但需认证", http.StatusForbidden, true},
		{"404 不存在", http.StatusNotFound, false},
		{"500 服务端错（判不存在）", http.StatusInternalServerError, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var gotPath string
			srv := httptest.NewServer(http.HandlerFunc(
				func(w http.ResponseWriter, r *http.Request) {
					gotPath = r.URL.Path
					w.WriteHeader(c.status)
				}))
			defer srv.Close()

			got := registryHasTagAt(srv.URL, "pigeonbox", "server", "4.6.4")
			if got != c.want {
				t.Errorf("registryHasTagAt(%d) = %v，期望 %v", c.status, got, c.want)
			}
			// 路径必须打对（打错路径 ⇒ 恒 404 ⇒ 恒判「不存在」）
			if want := "/v2/pigeonbox/server/manifests/4.6.4"; gotPath != want {
				t.Errorf("请求路径 = %q，期望 %q", gotPath, want)
			}
		})
	}
}

// TestRegistryHasTag_SendsAcceptHeader 钉住 Accept 头：
// 不带 Accept 时 registry 可能回 404/406（而不是 200）⇒ 误判「未发布」。
func TestRegistryHasTag_SendsAcceptHeader(t *testing.T) {
	var accept string
	srv := httptest.NewServer(http.HandlerFunc(
		func(w http.ResponseWriter, r *http.Request) {
			accept = r.Header.Get("Accept")
			w.WriteHeader(http.StatusOK)
		}))
	defer srv.Close()

	registryHasTagAt(srv.URL, "pigeonbox", "server", "4.6.4")
	for _, want := range []string{
		"application/vnd.oci.image.index.v1+json",
		"application/vnd.docker.distribution.manifest.list.v2+json",
	} {
		if !strings.Contains(accept, want) {
			t.Errorf("Accept 头缺 %q（实际 %q）——registry 会回 404/406 ⇒ 误判未发布",
				want, accept)
		}
	}
}
