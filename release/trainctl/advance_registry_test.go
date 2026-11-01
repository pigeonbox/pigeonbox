package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// registryHasTag 的判据必须能区分「存在」与「不存在」。
//
// ⚠️ 2026-10-31 实测的**假绿**（本轮最隐蔽的一个）：
//
//	ghcr 对**不带 token** 的 manifest 请求**恒回 401**
//	（实测：4.6.4 已存在 ⇒ 401；4.6.5 未发布 ⇒ 也是 401）
//	⇒ 旧实现把 401 当「算存在」⇒ **这个探测恒为真 ⇒ 从来没真的检查过镜像**
//	⇒ 列车据此报「镜像在位」⇒ **会在镜像还没推完时就发车**
//	（实测 4.6.5：server 镜像 manifest 仍是 404，列车却报「在位」）。
//
// ⇒ 现在的口径：**先取匿名 pull token，再带 token 探 manifest**；
//	只有 200 算「已发布」；404/401/403/5xx/取不到 token 一律判「不存在」。
//
// ⚠️ 本测试打的是**真实函数**（registryHasTagAt，baseURL 可注入）——
// 若只测「另写一份同逻辑的副本」⇒ 真实代码改了它照样全绿 ⇒ 门禁是摆设。

// fakeRegistry 起一个假 registry：
//   - /token            → 匿名 pull token（可关掉以模拟「取不到 token」）
//   - /v2/.../manifests → 按 manifestStatus 回；带 Authorization 时回 tokenStatus
type fakeRegistry struct {
	tokenOK        bool
	manifestStatus int // 带 token 时的状态
	anonStatus     int // 不带 token 时的状态（ghcr 的真实行为 = 401）
	sawToken       bool
	sawAuthHeader  bool
	manifestPath   string
}

func (f *fakeRegistry) handler() http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/token") {
			if !f.tokenOK {
				w.WriteHeader(http.StatusForbidden)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(map[string]string{"token": "anon-token"})
			return
		}
		f.manifestPath = r.URL.Path
		if r.Header.Get("Authorization") != "" {
			f.sawAuthHeader = true
			w.WriteHeader(f.manifestStatus)
			return
		}
		f.sawToken = true
		w.WriteHeader(f.anonStatus)
	}
}

func TestRegistryHasTag_DistinguishesExistFromMissing(t *testing.T) {
	cases := []struct {
		name   string
		status int
		want   bool
	}{
		{"200 存在", http.StatusOK, true},
		{"404 不存在", http.StatusNotFound, false},
		{"401 token 无效（判不存在）", http.StatusUnauthorized, false},
		{"403（判不存在）", http.StatusForbidden, false},
		{"500 服务端错（判不存在）", http.StatusInternalServerError, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := &fakeRegistry{tokenOK: true, manifestStatus: c.status, anonStatus: 401}
			srv := httptest.NewServer(f.handler())
			defer srv.Close()

			got := registryHasTagAt(srv.URL, "pigeonbox", "server", "4.6.4")
			if got != c.want {
				t.Errorf("registryHasTagAt(%d) = %v，期望 %v", c.status, got, c.want)
			}
			// 路径必须打对（打错路径 ⇒ 恒 404 ⇒ 恒判「不存在」）
			if want := "/v2/pigeonbox/server/manifests/4.6.4"; f.manifestPath != want {
				t.Errorf("请求路径 = %q，期望 %q", f.manifestPath, want)
			}
		})
	}
}

// ★ 回归判据：ghcr 的真实行为 = **不带 token 恒 401**。
// 旧实现（401 ⇒ 算存在）在这个假 registry 下会判「存在」⇒ 假绿。
func TestRegistryHasTag_Anonymous401MustNotMeanExists(t *testing.T) {
	f := &fakeRegistry{tokenOK: true, manifestStatus: http.StatusNotFound, anonStatus: 401}
	srv := httptest.NewServer(f.handler())
	defer srv.Close()

	if got := registryHasTagAt(srv.URL, "pigeonbox", "server", "4.6.5"); got {
		t.Fatal("未发布的镜像被判成已发布 ⇒ 探测恒为真（ghcr 匿名恒 401）")
	}
	if !f.sawAuthHeader {
		t.Fatal("探测必须带 Authorization（匿名请求恒 401 ⇒ 恒判假阳性）")
	}
}

// 取不到匿名 token ⇒ 无法判定 ⇒ 保守判「不存在」（不能放列车发车）
func TestRegistryHasTag_NoTokenMeansNotPublished(t *testing.T) {
	f := &fakeRegistry{tokenOK: false, manifestStatus: http.StatusOK, anonStatus: 401}
	srv := httptest.NewServer(f.handler())
	defer srv.Close()

	if got := registryHasTagAt(srv.URL, "pigeonbox", "server", "4.6.5"); got {
		t.Fatal("取不到 token 时应判「不存在」（保守），实际判成已发布")
	}
}

// TestRegistryHasTag_SendsAcceptHeader 钉住 Accept 头：
// 不带 Accept 时 registry 可能回 404/406（而不是 200）⇒ 误判「未发布」。
func TestRegistryHasTag_SendsAcceptHeader(t *testing.T) {
	var accept string
	srv := httptest.NewServer(http.HandlerFunc(
		func(w http.ResponseWriter, r *http.Request) {
			if strings.HasSuffix(r.URL.Path, "/token") {
				w.Header().Set("Content-Type", "application/json")
				_ = json.NewEncoder(w).Encode(map[string]string{"token": "anon-token"})
				return
			}
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
