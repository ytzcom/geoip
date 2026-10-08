package main

import (
	"bytes"
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// TestDownloadDatabaseResume verifies that downloadDatabase resumes a partial
// download (HTTP Range / 206) instead of restarting, and completes to the full
// content. The first request is answered with a short body to simulate an
// interruption; the second (a Range request) serves the remainder.
func TestDownloadDatabaseResume(t *testing.T) {
	const total = 5 * 1024 * 1024
	full := make([]byte, total)
	for i := range full {
		full[i] = byte((i * 7) % 251)
	}

	var reqs int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&reqs, 1)
		rng := r.Header.Get("Range")
		if rng == "" {
			// First attempt: declare the full length but send only 1MB, then
			// return so the connection closes -> client gets an unexpected EOF.
			w.Header().Set("Content-Length", strconv.Itoa(total))
			w.WriteHeader(http.StatusOK)
			w.Write(full[:1024*1024])
			return
		}
		var start int
		fmt.Sscanf(rng, "bytes=%d-", &start)
		if start >= total {
			w.WriteHeader(http.StatusRequestedRangeNotSatisfiable)
			return
		}
		w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, total-1, total))
		w.Header().Set("Content-Length", strconv.Itoa(total-start))
		w.WriteHeader(http.StatusPartialContent)
		w.Write(full[start:])
	}))
	defer srv.Close()

	logger := &Logger{quiet: true}
	cfg := &Config{TargetDir: t.TempDir(), Timeout: 60 * time.Second, MaxRetries: 3}
	g := &GeoIPUpdater{
		config:     cfg,
		httpClient: newHTTPClient(cfg.Timeout, cfg.MaxRetries, logger),
		logger:     logger,
	}

	res := g.downloadDatabase(context.Background(), "test.bin", srv.URL)
	if res.Error != nil {
		t.Fatalf("downloadDatabase error: %v (after %d requests)", res.Error, atomic.LoadInt32(&reqs))
	}
	got, err := os.ReadFile(filepath.Join(cfg.TargetDir, "test.bin"))
	if err != nil {
		t.Fatalf("read result: %v", err)
	}
	if len(got) != total {
		t.Fatalf("final size %d != %d", len(got), total)
	}
	if !bytes.Equal(got, full) {
		t.Fatal("content mismatch after resume")
	}
	if n := atomic.LoadInt32(&reqs); n < 2 {
		t.Fatalf("expected >=2 requests (interrupt + resume), got %d", n)
	}
	t.Logf("resumed and completed: %d bytes across %d requests", len(got), atomic.LoadInt32(&reqs))
}

func TestInstallAfterStageReplacedKeepsOwnData(t *testing.T) {
	dir := t.TempDir()
	stage := filepath.Join(dir, "x.bin.part")
	target := filepath.Join(dir, "x.bin")
	out, err := os.OpenFile(stage, os.O_RDWR|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	out.WriteString("complete")
	os.Remove(stage)
	os.WriteFile(stage, []byte("par"), 0o644)

	g := &GeoIPUpdater{logger: &Logger{quiet: true}}
	if err := g.install(out, stage, target); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(target); string(got) != "complete" {
		t.Fatalf("target = %q", got)
	}
	if got, _ := os.ReadFile(stage); string(got) != "par" {
		t.Fatalf("other run's stage = %q", got)
	}
	entries, _ := os.ReadDir(dir)
	if len(entries) != 2 {
		t.Fatalf("leftovers: %v", entries)
	}
}

func TestOpenStageFallsBackToPrivateFileWhenPartIsHeld(t *testing.T) {
	cases := []struct {
		removeErr error
		private   bool
	}{
		{nil, false},
		{os.ErrNotExist, false},
		{&os.PathError{Op: "remove", Path: "x", Err: os.ErrPermission}, true},
	}
	for _, c := range cases {
		dir := t.TempDir()
		f, err := openStage(dir, "x.bin", func(string) error { return c.removeErr })
		if err != nil {
			t.Fatal(err)
		}
		f.Close()
		shared := f.Name() == filepath.Join(dir, "x.bin.part")
		if shared == c.private {
			t.Errorf("remove error %v: stage %s", c.removeErr, f.Name())
		}
		if c.private && !strings.HasPrefix(filepath.Base(f.Name()), "x.bin.part.") {
			t.Errorf("private stage %s", f.Name())
		}
	}
}

func TestRangeNotSatisfiableWithoutETagRestarts(t *testing.T) {
	full := bytes.Repeat([]byte("abcdefgh"), 64*1024)
	var reqs int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n := atomic.AddInt32(&reqs, 1)
		if r.Header.Get("Range") != "" {
			w.WriteHeader(http.StatusRequestedRangeNotSatisfiable)
			return
		}
		w.Header().Set("Content-Length", strconv.Itoa(len(full)))
		w.WriteHeader(http.StatusOK)
		if n == 1 {
			w.Write(full[:1024])
			return
		}
		w.Write(full)
	}))
	defer srv.Close()

	logger := &Logger{quiet: true}
	cfg := &Config{TargetDir: t.TempDir(), Timeout: 60 * time.Second, MaxRetries: 3}
	g := &GeoIPUpdater{config: cfg, httpClient: newHTTPClient(cfg.Timeout, cfg.MaxRetries, logger), logger: logger}

	if res := g.downloadDatabase(context.Background(), "x.bin", srv.URL); res.Error != nil {
		t.Fatal(res.Error)
	}
	if got, _ := os.ReadFile(filepath.Join(cfg.TargetDir, "x.bin")); !bytes.Equal(got, full) {
		t.Fatalf("got %d bytes, want %d", len(got), len(full))
	}
	if n := atomic.LoadInt32(&reqs); n != 3 {
		t.Fatalf("requests = %d, want 3", n)
	}
}
