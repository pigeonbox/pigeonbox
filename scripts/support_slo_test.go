package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"gopkg.in/yaml.v3"
)

// TestSupportPolicyAndSLO 是 #387/#384 的治理门禁：
//
//   - release/support.json（支持窗口/PigeonBeam 兼容期的机器声明）必须与
//     release/train.yaml 的 train/lib.p2p 一致，日期按窗口公式自洽；
//   - SECURITY.md / docs/SUPPORT.md 的表格必须与声明逐项一致（bump 生成，防止漂移）；
//   - docs/SLO.md 与 deploy/k8s/base/prometheusrule.yaml 的指标名必须真实存在于
//     core 源码（REQUIRE_SOURCE_METRICS=1 时缺 core 判红，不做「没扫到=通过」）；
//   - K8s base 的 /metrics 抓取链路（PB_METRICS_ADDR / metrics 端口 / ServiceMonitor）
//     必须完整，否则 SLO 告警永远没有数据。
func TestSupportPolicyAndSLO(t *testing.T) {
	root := repoRoot(t)
	support := loadSupportPolicy(t, root)
	train := loadTrainFacts(t, root)

	t.Run("support-matches-train", func(t *testing.T) {
		if support.Train != train.Train {
			t.Fatalf("release/support.json train=%s 与 train.yaml train=%s 不一致", support.Train, train.Train)
		}
		if want := majorMinor(train.Train); support.Minor != want {
			t.Fatalf("support.minor=%s 应为 %s", support.Minor, want)
		}
		if support.Pigeonbeam.P2PPin != train.P2P {
			t.Fatalf("support.pigeonbeam.p2p_pin=%s 与 train.yaml lib.p2p=%s 不一致", support.Pigeonbeam.P2PPin, train.P2P)
		}
	})

	t.Run("support-dates", func(t *testing.T) {
		start, err := time.Parse("2006-01-02", support.WindowStart)
		if err != nil {
			t.Fatalf("window_start: %v", err)
		}
		var current, firstCritical *supportLine
		for i := range support.Lines {
			l := &support.Lines[i]
			if l.Status == "supported" {
				current = l
			}
			if l.Status == "critical" && firstCritical == nil {
				firstCritical = l
			}
			if l.Status == "critical" && l.Until < support.WindowStart {
				t.Errorf("critical 线 %s 已过期（%s < %s）却未标 EOL", l.Version, l.Until, support.WindowStart)
			}
			if l.Status == "eol" && l.Until > support.WindowStart {
				t.Errorf("eol 线 %s 的截止日 %s 晚于当前窗口起算 %s（EOL 日期不得在未来）", l.Version, l.Until, support.WindowStart)
			}
		}
		if current == nil {
			t.Fatal("缺当前维护线（status=supported）")
		}
		wantCurrent := start.AddDate(0, 0, support.Policy.CurrentSecurityDays).Format("2006-01-02")
		if current.Until != wantCurrent {
			t.Errorf("当前线 %s until=%s，按 %d 天窗口应为 %s", current.Version, current.Until, support.Policy.CurrentSecurityDays, wantCurrent)
		}
		if firstCritical == nil {
			t.Fatal("缺上一 minor（status=critical）")
		}
		wantPrev := start.AddDate(0, 0, support.Policy.PreviousSecurityDays).Format("2006-01-02")
		if firstCritical.Until != wantPrev {
			t.Errorf("上一 minor %s until=%s，按 %d 天窗口应为 %s", firstCritical.Version, firstCritical.Until, support.Policy.PreviousSecurityDays, wantPrev)
		}
		compat, err := time.Parse("2006-01-02", support.Pigeonbeam.CompatUntil)
		if err != nil {
			t.Fatalf("compat_until: %v", err)
		}
		cur, _ := time.Parse("2006-01-02", current.Until)
		if compat.Before(cur) {
			t.Errorf("PigeonBeam compat_until=%s 短于当前线安全支持截止 %s", support.Pigeonbeam.CompatUntil, current.Until)
		}
	})

	t.Run("support-docs", func(t *testing.T) {
		security := readFile(t, filepath.Join(root, "SECURITY.md"))
		if !strings.Contains(security, "<!-- support-window:begin -->") || !strings.Contains(security, "<!-- support-window:end -->") {
			t.Fatal("SECURITY.md 缺 support-window 生成块")
		}
		doc := readFile(t, filepath.Join(root, "docs/SUPPORT.md"))
		if !strings.Contains(doc, "<!-- support-matrix:begin -->") || !strings.Contains(doc, "<!-- support-matrix:end -->") {
			t.Fatal("docs/SUPPORT.md 缺 support-matrix 生成块")
		}
		if !strings.Contains(doc, "<!-- support-beam:begin -->") || !strings.Contains(doc, "<!-- support-beam:end -->") {
			t.Fatal("docs/SUPPORT.md 缺 support-beam 生成块（PigeonBeam 兼容期必须由 bump 同步）")
		}
		for _, l := range support.Lines {
			for _, blob := range []string{security, doc} {
				if !strings.Contains(blob, l.Version) || !strings.Contains(blob, l.Until) {
					t.Errorf("支持表缺行 %s / %s", l.Version, l.Until)
				}
			}
		}
		for _, want := range []string{
			"当前维护线：**" + support.Minor + ".x（列车 " + support.Train + "）**",
			support.WindowStart,
			"PigeonBeam", "wire", support.Pigeonbeam.WireProtocol,
			support.Pigeonbeam.P2PPin, support.Pigeonbeam.CompatUntil,
			"N-1", support.Pigeonbeam.NMinusOneSince,
		} {
			if !strings.Contains(doc, want) {
				t.Errorf("docs/SUPPORT.md 缺 %q", want)
			}
		}
	})

	t.Run("slo-metrics-real", func(t *testing.T) {
		core := filepath.Join(root, "core")
		required := os.Getenv("REQUIRE_SOURCE_METRICS") == "1"
		if _, err := os.Stat(core); err != nil {
			if required {
				t.Fatalf("REQUIRE_SOURCE_METRICS=1 但 core 仓不在位（%s）——不能把「没扫到」当通过", core)
			}
			t.Skip("core 仓不在位，跳过源码核验（CI docs-consistency job 会带 core 重跑）")
		}
		mustContain(t, filepath.Join(core, "pkg/middleware/metrics.go"), `Name: "http_requests_total"`, "http_requests_total")
		mustContain(t, filepath.Join(core, "pkg/middleware/metrics.go"), `Name:    "http_request_duration_seconds"`, "http_request_duration_seconds")
		mustContain(t, filepath.Join(core, "pkg/metrics/business.go"), `Name: "pb_share_created_total"`, "pb_share_created_total")
		mustContain(t, filepath.Join(core, "pkg/metrics/business.go"), `Name: "pb_upload_rejected_total"`, "pb_upload_rejected_total")
		mustContain(t, filepath.Join(core, "bootstrap/handlers_public.go"), "func metricsHandler", "/metrics handler")
		// 路由路径（与 docs/SLO.md 的 path 正则逐项对齐）。
		mustContain(t, filepath.Join(core, "gen/router/share/share.go"), `"/download"`, "GET /share/download")
		mustContain(t, filepath.Join(core, "gen/router/share/share.go"), `"/select"`, "GET /share/select/")
		mustContain(t, filepath.Join(core, "gen/router/share/share.go"), `"/file"`, "POST /share/file/")
		mustContain(t, filepath.Join(core, "gen/router/share/share.go"), `"/text"`, "POST /share/text/")
		mustContain(t, filepath.Join(core, "gen/router/chunk/chunk.go"), `"/complete"`, "POST /chunk/upload/complete/:id")
		mustContain(t, filepath.Join(core, "gen/router/presign/presign.go"), `"/complete"`, "POST /api/v1/presign/complete")
		mustContain(t, filepath.Join(core, "gen/handler/publicapi/public_api_service.go"), "multi-direct", "POST /api/v1/share/multi-direct")
		mustContain(t, filepath.Join(core, "gen/handler/publicapi/public_api_service.go"), "multi-bind", "POST /api/v1/share/multi-bind")
	})

	t.Run("prometheus-rule", func(t *testing.T) {
		rulePath := filepath.Join(root, "deploy/k8s/base/prometheusrule.yaml")
		raw, err := os.ReadFile(rulePath)
		if err != nil {
			t.Fatalf("读 %s: %v", rulePath, err)
		}
		var rf promRuleFile
		if err := yaml.Unmarshal(raw, &rf); err != nil {
			t.Fatalf("prometheusrule.yaml YAML 解析失败: %v", err)
		}
		if rf.Kind != "PrometheusRule" || rf.APIVersion != "monitoring.coreos.com/v1" {
			t.Fatalf("规则文件类型错误: %s %s", rf.APIVersion, rf.Kind)
		}
		if len(rf.Spec.Groups) == 0 {
			t.Fatal("PrometheusRule 无 groups")
		}
		records := map[string]bool{}
		alerts := map[string]bool{}
		allowedMetrics := map[string]bool{
			"http_requests_total":                  true,
			"http_request_duration_seconds_bucket": true,
			"http_request_duration_seconds_count":  true,
			"pb_share_created_total":               true,
			"pb_upload_rejected_total":             true,
			"pb_upload_bytes_total":                true,
		}
		metricRe := regexp.MustCompile(`\b(?:pb_[a-zA-Z0-9_]+|http_[a-zA-Z0-9_]+)\b`)
		recordRe := regexp.MustCompile(`\bslo:[a-zA-Z0-9_:]+\b`)
		for _, g := range rf.Spec.Groups {
			if g.Name == "" {
				t.Error("规则组缺 name")
			}
			for _, r := range g.Rules {
				if strings.TrimSpace(r.Expr) == "" {
					t.Errorf("规则 %q 缺 expr", r.Record+r.Alert)
				}
				if r.Record != "" {
					if records[r.Record] {
						t.Errorf("recording rule 重名: %s", r.Record)
					}
					records[r.Record] = true
				}
				if r.Alert != "" {
					if alerts[r.Alert] {
						t.Errorf("alert 重名: %s", r.Alert)
					}
					alerts[r.Alert] = true
					if r.For == "" {
						t.Errorf("alert %s 缺 for（燃烧率必须带持续时间）", r.Alert)
					}
					if r.Labels["severity"] == "" {
						t.Errorf("alert %s 缺 severity label", r.Alert)
					}
					if r.Annotations["runbook_url"] == "" {
						t.Errorf("alert %s 缺 runbook_url", r.Alert)
					}
				}
				for _, m := range metricRe.FindAllString(r.Expr, -1) {
					if !allowedMetrics[m] {
						t.Errorf("expr 引用了未核实/未允许的指标 %q（规则 %s）", m, r.Record+r.Alert)
					}
				}
			}
		}
		if len(records) == 0 || len(alerts) == 0 {
			t.Fatalf("recording=%d alerts=%d，规则文件不完整", len(records), len(alerts))
		}
		// alert 引用的 recording rule 必须真实存在。
		for _, g := range rf.Spec.Groups {
			for _, r := range g.Rules {
				if r.Alert == "" {
					continue
				}
				for _, ref := range recordRe.FindAllString(r.Expr, -1) {
					if !records[ref] {
						t.Errorf("alert %s 引用了不存在的 recording rule %s", r.Alert, ref)
					}
				}
			}
		}
		for _, want := range []string{"PigeonBoxShareCreateErrorBudgetBurnFast", "PigeonBoxPickupErrorBudgetBurnFast", "PigeonBoxUploadCompleteLatencyBudgetBurnFast"} {
			if !alerts[want] {
				t.Errorf("缺燃烧率告警 %s", want)
			}
		}
	})

	t.Run("slo-doc-and-scrape-wiring", func(t *testing.T) {
		slo := readFile(t, filepath.Join(root, "docs/SLO.md"))
		for _, want := range []string{
			"http_requests_total", "http_request_duration_seconds",
			"/share/file/?", "/share/text/?", "/api/v1/share/multi-direct",
			"/api/v1/share/multi-bind", "/chunk/upload/complete/:id",
			"/api/v1/presign/complete", "/share/select/?", "/share/download",
			"99.5%", "99.9%", "2.5s", "错误预算", "燃烧率",
			"GC 积压", "备份恢复成功率", "升级成功率", "未埋点",
		} {
			if !strings.Contains(slo, want) {
				t.Errorf("docs/SLO.md 缺 %q", want)
			}
		}
		cm := readFile(t, filepath.Join(root, "deploy/k8s/base/configmap.yaml"))
		if !strings.Contains(cm, `PB_METRICS_ADDR: "0.0.0.0:9090"`) {
			t.Error("configmap 缺 PB_METRICS_ADDR=0.0.0.0:9090（跨 Pod 抓取必需）")
		}
		dep := readFile(t, filepath.Join(root, "deploy/k8s/base/deployment.yaml"))
		if !strings.Contains(dep, "containerPort: 9090") || !strings.Contains(dep, "name: metrics") {
			t.Error("deployment 缺 metrics 9090 端口")
		}
		svc := readFile(t, filepath.Join(root, "deploy/k8s/base/service.yaml"))
		if !strings.Contains(svc, "name: metrics") || !strings.Contains(svc, "port: 9090") || !strings.Contains(svc, "app: pigeonbox") {
			t.Error("service 缺 metrics 端口或 app 标签（ServiceMonitor selector 依赖）")
		}
		sm := readFile(t, filepath.Join(root, "deploy/k8s/base/servicemonitor.yaml"))
		if !strings.Contains(sm, "port: metrics") || !strings.Contains(sm, "targetLabels:") {
			t.Error("servicemonitor 未指向 metrics 端口或未透传 app 标签")
		}
	})
}

type supportPolicy struct {
	Schema      string `json:"schema"`
	Train       string `json:"train"`
	Minor       string `json:"minor"`
	WindowStart string `json:"window_start"`
	Policy      struct {
		CurrentSecurityDays  int `json:"current_security_days"`
		PreviousSecurityDays int `json:"previous_security_days"`
	} `json:"policy"`
	Lines      []supportLine `json:"lines"`
	Pigeonbeam struct {
		WireProtocol   string `json:"wire_protocol"`
		P2PPin         string `json:"p2p_pin"`
		NMinusOneSince string `json:"n_minus_one_since"`
		CompatUntil    string `json:"compat_until"`
	} `json:"pigeonbeam"`
}

type supportLine struct {
	Version  string `json:"version"`
	Status   string `json:"status"`
	Security string `json:"security"`
	Until    string `json:"until"`
	Note     string `json:"note"`
}

type trainFacts struct {
	Train string
	Core  string
	P2P   string
}

type promRuleFile struct {
	APIVersion string `yaml:"apiVersion"`
	Kind       string `yaml:"kind"`
	Spec       struct {
		Groups []struct {
			Name  string `yaml:"name"`
			Rules []struct {
				Record      string            `yaml:"record"`
				Alert       string            `yaml:"alert"`
				Expr        string            `yaml:"expr"`
				For         string            `yaml:"for"`
				Labels      map[string]string `yaml:"labels"`
				Annotations map[string]string `yaml:"annotations"`
			} `yaml:"rules"`
		} `yaml:"groups"`
	} `yaml:"spec"`
}

func repoRoot(t *testing.T) string {
	t.Helper()
	wd, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	for d := wd; d != filepath.Dir(d); d = filepath.Dir(d) {
		if _, err := os.Stat(filepath.Join(d, "release", "train.yaml")); err == nil {
			return d
		}
	}
	t.Fatalf("找不到仓库根（从 %s 向上无 release/train.yaml）", wd)
	return ""
}

func readFile(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("读 %s: %v", path, err)
	}
	return string(b)
}

func loadSupportPolicy(t *testing.T, root string) supportPolicy {
	t.Helper()
	var p supportPolicy
	if err := json.Unmarshal([]byte(readFile(t, filepath.Join(root, "release/support.json"))), &p); err != nil {
		t.Fatalf("release/support.json 解析失败: %v", err)
	}
	if p.Schema != "1" || p.Train == "" || p.Minor == "" || p.WindowStart == "" {
		t.Fatalf("release/support.json 缺必填字段: %+v", p)
	}
	return p
}

func loadTrainFacts(t *testing.T, root string) trainFacts {
	t.Helper()
	var f trainFacts
	for _, line := range strings.Split(readFile(t, filepath.Join(root, "release/train.yaml")), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		k, v, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		v = strings.TrimSpace(v)
		switch strings.TrimSpace(k) {
		case "train":
			f.Train = v
		case "lib.core":
			f.Core = v
		case "lib.p2p":
			f.P2P = v
		}
	}
	if f.Train == "" || f.P2P == "" {
		t.Fatalf("train.yaml 缺 train/lib.p2p: %+v", f)
	}
	return f
}

func mustContain(t *testing.T, path, needle, desc string) {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("读 %s: %v", path, err)
	}
	if !strings.Contains(string(b), needle) {
		t.Fatalf("%s 缺 %q（%s 不存在或不完整）", path, needle, desc)
	}
}

func majorMinor(v string) string {
	parts := strings.Split(strings.TrimPrefix(strings.TrimSpace(v), "v"), ".")
	if len(parts) < 2 {
		return ""
	}
	return parts[0] + "." + parts[1]
}
