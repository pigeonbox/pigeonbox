package main

import (
	"os"
	"path/filepath"
	"testing"
)

// hub#360：deploy/k8s/base 是被复制的模板——镜像停在 `:latest` + IfNotPresent
// 会让直接 `kubectl apply -k base` 或复制 base 做 overlay 的用户静默跑节点
// 缓存里的旧层（不拉新、不报错），且无从审计「跑的到底是哪个版本」。
//
// ⇒ base 必须钉版且与 train.yaml 的 images.server 同值（bump 同步改写）。
// 本测试给 section3HubPins 的 base 判据装牙齿：同值绿、latest 红、落后版本红。
func TestSection3K8sBasePins(t *testing.T) {
	cases := []struct {
		name        string
		serverImg   string // base/deployment.yaml 的 image 行
		frontendImg string // base/frontend-deployment.yaml 的 image 行
		wantFails   int
	}{
		{"与本车钉版同值", "ghcr.io/pigeonbox/server:5.8.0", "ghcr.io/pigeonbox/frontend:5.8.0", 0},
		{"回退 latest（issue 现场）", "ghcr.io/pigeonbox/server:latest", "ghcr.io/pigeonbox/frontend:5.8.0", 1},
		{"落后一车（bump 漏改）", "ghcr.io/pigeonbox/server:5.7.0", "ghcr.io/pigeonbox/frontend:5.8.0", 1},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			root := t.TempDir()
			files := map[string]string{
				trainFileRel: "schema: \"1\"\ntrain: 5.8.0\nstate: shipped\nimages.server: 5.8.0\n",
				// section3 的其余三根判据给足同值，保证 fails 只可能来自 base 判据。
				"deploy/nas/compose.yml":                      "image: ghcr.io/pigeonbox/server:${PB_IMAGE_TAG:-5.8.0}\n",
				"deploy/nas/env.example":                      "PB_IMAGE_TAG=5.8.0\n",
				"deploy/k8s/overlays/prod/kustomization.yaml": "images:\n  - name: ghcr.io/pigeonbox/server\n    newTag: 5.8.0\n",
				"deploy/k8s/base/deployment.yaml":             "        - name: pigeonbox\n          image: " + c.serverImg + "\n          imagePullPolicy: IfNotPresent\n",
				"deploy/k8s/base/frontend-deployment.yaml":    "        - name: frontend\n          image: " + c.frontendImg + "\n          imagePullPolicy: IfNotPresent\n",
				"go.work": "use (\n	.\n)\n",
			}
			for rel, body := range files {
				p := filepath.Join(root, rel)
				if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
					t.Fatalf("mkdir %s: %v", rel, err)
				}
				if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
					t.Fatalf("write %s: %v", rel, err)
				}
			}
			env := &Env{Root: root}
			tf, err := LoadTrainFile(env)
			if err != nil {
				t.Fatalf("LoadTrainFile: %v", err)
			}
			v := &verifier{env: env, tf: tf, state: tf.Get("state")}
			v.section3HubPins()
			if v.fails != c.wantFails {
				t.Fatalf("fails = %d, 期望 %d（base 判据口径漂了）", v.fails, c.wantFails)
			}
		})
	}
}
