package main

import "testing"

// TestDisplayVersion verifies the version renders with exactly one leading "v"
// whether it was injected bare ("1.1.1", as the Makefile does) or already
// prefixed ("v1.1.1", as the release workflow's -X main.version=v1.1.1 does).
// This guards against the "vv1.1.1" double-prefix regression.
func TestDisplayVersion(t *testing.T) {
	orig := version
	defer func() { version = orig }()

	cases := []struct {
		in   string
		want string
	}{
		{"1.1.1", "v1.1.1"},  // Makefile injection (bare)
		{"v1.1.1", "v1.1.1"}, // release workflow injection (prefixed)
		{"1.2.0", "v1.2.0"},
	}
	for _, c := range cases {
		version = c.in
		if got := displayVersion(); got != c.want {
			t.Errorf("displayVersion() with version=%q = %q, want %q", c.in, got, c.want)
		}
	}
}
