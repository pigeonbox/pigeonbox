package main

import "testing"

// TestFirstJSONVersion 取 JSON 里第一个 version 字段的值。
func TestFirstJSONVersion(t *testing.T) {
	cases := []struct{ name, in, want string }{
		{"普通", `{"name":"x","version":"3.3.31","type":"module"}`, "3.3.31"},
		{"带空格", "{\n  \"version\" : \"3.3.30\"\n}", "3.3.30"},
		{"没有 version", `{"name":"x"}`, ""},
		{"空内容", "", ""},
	}
	for _, c := range cases {
		if got := firstJSONVersion(c.in); got != c.want {
			t.Errorf("%s: firstJSONVersion = %q, 期望 %q", c.name, got, c.want)
		}
	}
}
