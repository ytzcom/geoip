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
		tempDir:    t.TempDir(),
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
