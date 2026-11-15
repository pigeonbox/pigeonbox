package main

import (
	"os"
	"path/filepath"
	"testing"
)

// section3HubPins 钉版判据夹具（hub#360 / hub#371）：
//
//   - hub#360：deploy/k8s/base 是被复制的模板——镜像停在 `:latest` + IfNotPresent
//     会让直接 `kubectl apply -k base` 或复制 base 做 overlay 的用户静默跑节点
//     缓存里的旧层（不拉新、不报错），且无从审计运行版本；
//   - hub#371：根 docker-compose.yml 是 README 快速开始入口——缺省 :-latest 不在
//     列车钉版射程，且 compose 对本地已存在的 latest 不会自动 re-pull。
//
// ⇒ 两者都必须与 train.yaml 的 images.server 同值（bump 同步改写）。
// 本测试给这些判据装牙齿：同值绿、回退 latest 红、落后车号红。
func TestSection3HubPinsFixtures(t *testing.T) {
	cases := []struct {
		name        string
		serverImg   string // deploy/k8s/base/deployment.yaml 的 image 行
		frontendImg string // deploy/k8s/base/frontend-deployment.yaml 的 image 行
		rootTag     string // 根 compose 的 ${PB_IMAGE_TAG:-<ver>} 缺省值
		wantFails   int
	}{
		{"全量与本车钉版同值", "ghcr.io/pigeonbox/server:5.8.0", "ghcr.io/pigeonbox/frontend:5.8.0", "5.8.0", 0},
		{"k8s base 回退 latest（#360 现场）", "ghcr.io/pigeonbox/server:latest", "ghcr.io/pigeonbox/frontend:5.8.0", "5.8.0", 1},
		{"k8s base 落后一车（bump 漏改）", "ghcr.io/pigeonbox/server:5.7.0", "ghcr.io/pigeonbox/frontend:5.8.0", "5.8.0", 1},
		{"根 compose 回退 latest（#371 现场）", "ghcr.io/pigeonbox/server:5.8.0", "ghcr.io/pigeonbox/frontend:5.8.0", "latest", 1},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			root := t.TempDir()
			files := map[string]string{
				trainFileRel: "schema: \"1\"\ntrain: 5.8.0\nstate: shipped\nimages.server: 5.8.0\n",
				// section3 的 deploy/nas / overlay 判据给足同值，
				// 保证 fails 只可能来自本次新增的两根判据。
				"deploy/nas/compose.yml":                      "image: ghcr.io/pigeonbox/server:${PB_IMAGE_TAG:-5.8.0}\n",
				"deploy/nas/env.example":                      "PB_IMAGE_TAG=5.8.0\n",
				"deploy/k8s/overlays/prod/kustomization.yaml": "images:\n  - name: ghcr.io/pigeonbox/server\n    newTag: 5.8.0\n",
				"docker-compose.yml": "    image: ghcr.io/pigeonbox/server:${PB_IMAGE_TAG:-" + c.rootTag + "}\n" +
					"    image: ghcr.io/pigeonbox/frontend:${PB_IMAGE_TAG:-5.8.0}\n",
				"deploy/k8s/base/deployment.yaml":          "        - name: pigeonbox\n          image: " + c.serverImg + "\n          imagePullPolicy: IfNotPresent\n",
				"deploy/k8s/base/frontend-deployment.yaml": "        - name: frontend\n          image: " + c.frontendImg + "\n          imagePullPolicy: IfNotPresent\n",
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
				t.Fatalf("fails = %d, 期望 %d（判据口径漂了）", v.fails, c.wantFails)
			}
		})
	}
}
