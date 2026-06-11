package main

import (
	"testing"
	"time"
)

// TestTimeoutValueSet verifies that --timeout/-t accepts both Go duration
// strings (as the GitHub Action forwards, e.g. "5m") and bare integers
// interpreted as seconds (as older callers pass, e.g. "1800"), and that
// garbage still errors.
func TestTimeoutValueSet(t *testing.T) {
	cases := []struct {
		in      string
		want    time.Duration
		wantErr bool
	}{
		{"5m", 300 * time.Second, false},    // action default
		{"300s", 300 * time.Second, false},  // documented duration form
		{"1800", 1800 * time.Second, false}, // bare integer = seconds (back-compat)
		{"90s", 90 * time.Second, false},
		{" 5m ", 300 * time.Second, false}, // surrounding whitespace tolerated
		{"0", 0, false},
		{"5x", 0, true},  // not a valid duration unit
		{"", 0, true},    // empty
		{"abc", 0, true}, // garbage
	}

	for _, c := range cases {
		var tv timeoutValue
		err := tv.Set(c.in)
		if c.wantErr {
			if err == nil {
				t.Errorf("Set(%q): expected error, got nil (d=%v)", c.in, tv.d)
			}
			continue
		}
		if err != nil {
			t.Errorf("Set(%q): unexpected error: %v", c.in, err)
			continue
		}
		if tv.d != c.want {
			t.Errorf("Set(%q): got %v, want %v", c.in, tv.d, c.want)
		}
	}
}

// TestTimeoutValueDefault confirms the effective default is unchanged at 1800s
// (30m) for callers that omit the flag entirely.
func TestTimeoutValueDefault(t *testing.T) {
	tv := &timeoutValue{d: defaultTimeout * time.Second}
	if want := 1800 * time.Second; tv.d != want {
		t.Fatalf("default timeout = %v, want %v", tv.d, want)
	}
	if got, want := tv.String(), "30m0s"; got != want {
		t.Fatalf("default String() = %q, want %q", got, want)
	}
}
