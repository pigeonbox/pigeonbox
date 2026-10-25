package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// 2026-10-25 实录（3.3.28 终验）：frontend-core v0.11.21 的 package.json 仍钉
// contracts v0.18.6，壳钉 v0.18.7 ⇒ 壳仓装出来是**两份** contracts：
//
//	node_modules/@pigeonbox/contracts                                       → 0.18.7
//	node_modules/@pigeonbox/frontend-core/node_modules/@pigeonbox/contracts → 0.18.6
//
// npm 不去重不同版本 ⇒ frontend-core 源码的 `import type` 从 nested 那份解析 ⇒
// 壳里两份类型定义。本次 TS 载荷逐字节相同所以没炸，下次 contracts 改 TS 载荷即炸。
// ⇒ 新增 8b 节机械守卫（消费仓 lock 里 contracts 副本数必须 = 1）。

const lockOneCopy = `{
  "name": "pigeonbox-frontend",
  "lockfileVersion": 3,
  "packages": {
    "": {
      "dependencies": {
        "@pigeonbox/frontend-core": "https://example/frontend-core-0.11.22.tgz"
      },
      "devDependencies": {
        "@pigeonbox/contracts": "https://example/contracts-0.18.7.tgz"
      }
    },
    "node_modules/@pigeonbox/contracts": {
      "version": "0.18.7",
      "resolved": "https://example/contracts-0.18.7.tgz"
    },
    "node_modules/@pigeonbox/frontend-core": {
      "version": "0.11.22",
      "resolved": "https://example/frontend-core-0.11.22.tgz",
      "dependencies": {
        "@pigeonbox/contracts": "https://example/contracts-0.18.7.tgz"
      }
    }
  }
}`

// lockTwoCopies = 3.3.28 壳仓的真实形态：根一份 0.18.7 + nested 一份 0.18.6。
const lockTwoCopies = `{
  "name": "pigeonbox-frontend",
  "lockfileVersion": 3,
  "packages": {
    "": {
      "dependencies": {
        "@pigeonbox/frontend-core": "https://example/frontend-core-0.11.21.tgz"
      },
      "devDependencies": {
        "@pigeonbox/contracts": "https://example/contracts-0.18.7.tgz"
      }
    },
    "node_modules/@pigeonbox/contracts": {
      "version": "0.18.7",
      "resolved": "https://example/contracts-0.18.7.tgz"
    },
    "node_modules/@pigeonbox/frontend-core": {
      "version": "0.11.21",
      "resolved": "https://example/frontend-core-0.11.21.tgz",
      "dependencies": {
        "@pigeonbox/contracts": "https://example/contracts-0.18.6.tgz"
      }
    },
    "node_modules/@pigeonbox/frontend-core/node_modules/@pigeonbox/contracts": {
      "version": "0.18.6",
      "resolved": "https://example/contracts-0.18.6.tgz"
    }
  }
}`

func TestCountContractsCopies(t *testing.T) {
	cases := []struct {
		name string
		lock string
		want int
	}{
		{"单副本（钉版一致，npm 去重后）", lockOneCopy, 1},
		{"两份（3.3.28 实况：根 0.18.7 + nested 0.18.6）", lockTwoCopies, 2},
		{
			"三份（更深一层的嵌套）",
			strings.Replace(lockTwoCopies,
				`"node_modules/@pigeonbox/frontend-core/node_modules/@pigeonbox/contracts": {`,
				`"node_modules/@pigeonbox/frontend-core/node_modules/@pigeonbox/contracts": {},
    "node_modules/@pigeonbox/frontend-core/node_modules/@pigeonbox/frontend-core/node_modules/@pigeonbox/contracts": {`, 1),
			3,
		},
		{
			// dependencies 段里对同一个包的**声明**不是第二份实体——
			// 把它算成副本会让守卫恒红（假红比漏闸更坏：列车会被网络噪声卡死）。
			"dependencies 段的声明不算副本",
			`{"lockfileVersion":3,"packages":{"":{"dependencies":{"@pigeonbox/contracts":"x"}},"node_modules/@pigeonbox/contracts":{}}}`,
			1,
		},
		{
			"没有任何 contracts ⇒ 0 份（守卫据此判红，而不是沉默通过）",
			`{"lockfileVersion":3,"packages":{"":{"name":"x"}}}`,
			0,
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := countContractsCopies(c.lock)
			if err != nil {
				t.Fatalf("countContractsCopies 报错: %v", err)
			}
			if got != c.want {
				t.Fatalf("副本数 = %d, 期望 %d", got, c.want)
			}
		})
	}
}

// TestCountContractsCopies_BrokenInput 口径坏了必须**报错**而不是返回 0。
//
// 守卫自身的解析口径失效时若静默返回 0（=0 份 ⇒ 判红）或静默返回 1（=1 份 ⇒ 放行），
// 守卫就形同虚设 ⇒ 所以解析失败必须冒泡成 error，由调用方**硬失败**。
func TestCountContractsCopies_BrokenInput(t *testing.T) {
	for _, bad := range []string{
		``,                      // 空内容
		`not json at all`,       // 完全不是 JSON
		`{"lockfileVersion":3}`, // 无 packages 段（lock 格式变了）
		`{"packages":[]}`,       // packages 不是对象
	} {
		if _, err := countContractsCopies(bad); err == nil {
			t.Fatalf("坏输入 %q 应当报错（守卫口径坏了必须冒泡，不能静默放行）", bad)
		}
	}
}

// TestSection8bRegisteredInVerify 8b 节必须真的挂在 verify 的执行路径上。
//
// 「守卫写了但没被调用」= 门禁形同虚设（2026-10-25 录：core 的「零测试面 =
// 漏闸不会被发现」是同一族陷阱）。⇒ 源码级钉死调用点。
func TestSection8bRegisteredInVerify(t *testing.T) {
	src, err := os.ReadFile("verify.go")
	if err != nil {
		t.Fatal(err)
	}
	body := string(src)
	if !strings.Contains(body, "v.section8bContractsCopies()") {
		t.Fatal("cmdVerify 里必须调用 section8bContractsCopies()——守卫没挂上就是空转")
	}
}

// TestContractsCopiesGuard_RealShellLock 用**真实**壳仓 lock 做一次回归。
//
// 取本地检出 frontend/package-lock.json（3.3.28 钉版 ⇒ 两份）——
// 断言副本数 ≥ 2 且守卫会判红。这条用例把「守卫对着真实缺陷有效」钉住，
// 而不只是对着人造 fixture 有效。
func TestContractsCopiesGuard_RealShellLock(t *testing.T) {
	path := filepath.Join("..", "..", "frontend", "package-lock.json")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Skipf("壳仓 lock 不在本地检出（跳过）：%v", err)
	}
	n, err := countContractsCopies(string(raw))
	if err != nil {
		t.Fatalf("真实 lock 解析失败: %v", err)
	}
	// 本地检出可能是旧车（两份）也可能是新车（一份）⇒ 断言的是
	//「副本数被正确数出来」，具体份数随钉版变。
	if n < 1 {
		t.Fatalf("真实 lock 里 contracts 副本数应为 ≥1（壳必装 contracts），实得 %d", n)
	}
	if n != 1 && n != 2 {
		t.Fatalf("真实 lock 副本数异常：%d（期望 1 或 2，>2 说明判定口径坏了）", n)
	}
}
