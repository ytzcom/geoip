package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// Version is injected at build time via -ldflags -X. The Makefile injects a
// bare "1.2.0" while the release workflow injects a "v1.2.0" tag, so callers
// must use displayVersion() to render it with exactly one leading "v".
var version = "1.2.0"

// displayVersion returns version with exactly one leading "v", regardless of
// whether it was injected with or without the prefix (avoids "vv1.2.0").
func displayVersion() string {
	return "v" + strings.TrimPrefix(version, "v")
}

const (
	defaultEndpoint    = "https://geoipdb.net/auth"
	defaultTargetDir   = "./geoip"
	defaultRetries     = 3
	defaultTimeout     = 1800 // overall ceiling; downloadIdleTimeout is the stall guard
	defaultConcurrent  = 2    // bandwidth-bound: fewer streams finish large files sooner
	defaultLockTimeout = 1800
)

// Config holds the application configuration
type Config struct {
	APIKey        string
	APIEndpoint   string
	TargetDir     string
	Databases     []string
	LogFile       string
	MaxRetries    int
	Timeout       time.Duration
	MaxConcurrent int
	Quiet         bool
	Verbose       bool
	NoLock        bool
	OnlyChanged   bool
	Force         bool
	LockFile      string
	LockTimeout   int
}

// DownloadResult represents the result of a database download
type DownloadResult struct {
	Database  string
	Size      int64
	Unchanged bool
	Error     error
}

// Logger handles logging with different levels
type Logger struct {
	quiet   bool
	verbose bool
	file    *os.File
	mu      sync.Mutex
}

func newLogger(config *Config) (*Logger, error) {
	l := &Logger{
		quiet:   config.Quiet,
		verbose: config.Verbose,
	}

	if config.LogFile != "" {
		// Create log directory if needed
		logDir := filepath.Dir(config.LogFile)
		if err := os.MkdirAll(logDir, 0755); err != nil {
			return nil, fmt.Errorf("failed to create log directory: %w", err)
		}

		// Open log file
		file, err := os.OpenFile(config.LogFile, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0644)
		if err != nil {
			return nil, fmt.Errorf("failed to open log file: %w", err)
		}
		l.file = file
	}

	return l, nil
}

func (l *Logger) log(level, message string) {
	l.mu.Lock()
	defer l.mu.Unlock()

	timestamp := time.Now().Format("2006-01-02 15:04:05")
	logLine := fmt.Sprintf("[%s] [%s] %s", timestamp, level, message)

	// Write to file if configured
	if l.file != nil {
		fmt.Fprintln(l.file, logLine)
	}

	// Write to console based on level and settings
	if !l.quiet {
		switch level {
		case "ERROR":
			fmt.Fprintf(os.Stderr, "\033[0;31m[%s]\033[0m %s\n", level, message)
		case "WARN":
			fmt.Fprintf(os.Stderr, "\033[1;33m[%s]\033[0m %s\n", level, message)
		case "SUCCESS":
			fmt.Printf("\033[0;32m[%s]\033[0m %s\n", level, message)
		case "INFO":
			if l.verbose {
				fmt.Printf("\033[0;34m[%s]\033[0m %s\n", level, message)
			}
		default:
			fmt.Printf("[%s] %s\n", level, message)
		}
	} else if level == "ERROR" {
		// Always output errors
		fmt.Fprintf(os.Stderr, "[%s] %s\n", timestamp, message)
	}
}

func (l *Logger) Info(format string, args ...interface{}) {
	l.log("INFO", fmt.Sprintf(format, args...))
}

func (l *Logger) Warn(format string, args ...interface{}) {
	l.log("WARN", fmt.Sprintf(format, args...))
}

func (l *Logger) Error(format string, args ...interface{}) {
	l.log("ERROR", fmt.Sprintf(format, args...))
}

func (l *Logger) Success(format string, args ...interface{}) {
	l.log("SUCCESS", fmt.Sprintf(format, args...))
}

func (l *Logger) Close() {
	if l.file != nil {
		l.file.Close()
	}
}

// LockFile manages process locking
type LockFile struct {
	path   string
	noLock bool
}

func newLockFile(noLock bool) *LockFile {
	lockPath := filepath.Join(os.TempDir(), "geoip-update.lock")
	return &LockFile{
		path:   lockPath,
		noLock: noLock,
	}
}

func (l *LockFile) Acquire() error {
	if l.noLock {
		return nil
	}

	// Check if lock file exists
	if data, err := os.ReadFile(l.path); err == nil {
		// Parse PID
		if pid, err := strconv.Atoi(strings.TrimSpace(string(data))); err == nil {
			// Check if process is running
			if isProcessRunning(pid) {
				return fmt.Errorf("another instance is already running (PID: %d)", pid)
			}
		}
		// Remove stale lock
		os.Remove(l.path)
	}

	// Create new lock
	pid := os.Getpid()
	return os.WriteFile(l.path, []byte(strconv.Itoa(pid)), 0644)
}

func (l *LockFile) Release() {
	if l.noLock {
		return
	}

	// Only remove if it's our lock
	if data, err := os.ReadFile(l.path); err == nil {
		if pid, err := strconv.Atoi(strings.TrimSpace(string(data))); err == nil {
			if pid == os.Getpid() {
				os.Remove(l.path)
			}
		}
	}
}

func isProcessRunning(pid int) bool {
	// Platform-specific process checking
	switch runtime.GOOS {
	case "windows":
		// On Windows, we can't easily check, so assume it's running
		return true
	default:
		// Unix-like systems
		process, err := os.FindProcess(pid)
		if err != nil {
			return false
		}
		// Send signal 0 to check if process exists
		err = process.Signal(os.Signal(nil))
		return err == nil
	}
}

// downloadIdleTimeout aborts a download whose body read stalls for this long.
// This is a stall timeout, not an absolute deadline, so a slow-but-progressing
// download of a large database is not killed mid-transfer.
const downloadIdleTimeout = 120 * time.Second

// idleTimeoutReader wraps a response body and cancels the request (via cancel)
// if no data is read for idle. The timer is reset on every read that returns
// bytes, so only a genuine stall trips it.
type idleTimeoutReader struct {
	rc    io.Reader
	timer *time.Timer
	idle  time.Duration
}

func newIdleTimeoutReader(rc io.Reader, idle time.Duration, cancel context.CancelFunc) *idleTimeoutReader {
	return &idleTimeoutReader{rc: rc, idle: idle, timer: time.AfterFunc(idle, cancel)}
}

func (r *idleTimeoutReader) Read(p []byte) (int, error) {
	n, err := r.rc.Read(p)
	if n > 0 {
		r.timer.Reset(r.idle)
	}
	return n, err
}

func (r *idleTimeoutReader) Stop() { r.timer.Stop() }

// HTTPClient wraps http.Client with retry logic
type HTTPClient struct {
	client     *http.Client
	maxRetries int
	logger     *Logger
}

func newHTTPClient(timeout time.Duration, maxRetries int, logger *Logger) *HTTPClient {
	return &HTTPClient{
		client: &http.Client{
			// Generous overall ceiling. The per-read stall guard
			// (downloadIdleTimeout) is what aborts a dead transfer; this just
			// bounds a pathologically slow one. Connect/TLS/header are bounded
			// explicitly below so removing a tight total timeout can't hang.
			Timeout: timeout,
			Transport: &http.Transport{
				TLSClientConfig: &tls.Config{
					MinVersion: tls.VersionTLS12,
				},
				DialContext:           (&net.Dialer{Timeout: 30 * time.Second}).DialContext,
				TLSHandshakeTimeout:   15 * time.Second,
				ResponseHeaderTimeout: 30 * time.Second,
				MaxIdleConns:          100,
				IdleConnTimeout:       90 * time.Second,
				DisableCompression:    false,
			},
		},
		maxRetries: maxRetries,
		logger:     logger,
	}
}

func (h *HTTPClient) doWithRetry(req *http.Request) (*http.Response, error) {
	var lastErr error
	retryDelay := time.Second

	for attempt := 0; attempt < h.maxRetries; attempt++ {
		if attempt > 0 {
			h.logger.Info("Retrying in %v... (attempt %d/%d)", retryDelay, attempt+1, h.maxRetries)
			time.Sleep(retryDelay)
			retryDelay = minDuration(retryDelay*2, 60*time.Second)
		}

		resp, err := h.client.Do(req)
		if err != nil {
			lastErr = err
			h.logger.Warn("Request failed: %v", err)
			continue
		}

		// Check status code
		switch resp.StatusCode {
		case http.StatusOK, http.StatusPartialContent, http.StatusRequestedRangeNotSatisfiable:
			// 200 full, 206 resumed range, 416 range-not-satisfiable (already complete)
			return resp, nil
		case http.StatusTooManyRequests:
			resp.Body.Close()
			if retryAfter := resp.Header.Get("Retry-After"); retryAfter != "" {
				if seconds, err := strconv.Atoi(retryAfter); err == nil {
					retryDelay = time.Duration(seconds) * time.Second
				}
			}
			h.logger.Warn("Rate limited (429)")
			lastErr = fmt.Errorf("rate limited")
		case http.StatusUnauthorized:
			resp.Body.Close()
			return nil, fmt.Errorf("authentication failed (401) - check your API key")
		case http.StatusForbidden:
			resp.Body.Close()
			return nil, fmt.Errorf("access forbidden (403) - check your permissions")
		default:
			body, _ := io.ReadAll(resp.Body)
			resp.Body.Close()
			lastErr = fmt.Errorf("HTTP %d: %s", resp.StatusCode, string(body))
			h.logger.Warn("HTTP error %d", resp.StatusCode)
		}
	}

	return nil, fmt.Errorf("failed after %d attempts: %w", h.maxRetries, lastErr)
}

// GeoIPUpdater handles the database update process
type GeoIPUpdater struct {
	config     *Config
	httpClient *HTTPClient
	logger     *Logger
	manifest   map[string]manifestEntry
	updates    map[string]manifestEntry
	mu         sync.Mutex
}

func newGeoIPUpdater(config *Config, logger *Logger) (*GeoIPUpdater, error) {
	return &GeoIPUpdater{
		config:     config,
		httpClient: newHTTPClient(config.Timeout, config.MaxRetries, logger),
		logger:     logger,
		manifest:   map[string]manifestEntry{},
		updates:    map[string]manifestEntry{},
	}, nil
}

func (g *GeoIPUpdater) authenticate() (map[string]string, error) {
	g.logger.Info("Authenticating with API endpoint")

	// Prepare request body
	body := map[string]interface{}{
		"databases": "all",
	}
	if len(g.config.Databases) > 0 && g.config.Databases[0] != "all" {
		body["databases"] = g.config.Databases
	}

	jsonBody, err := json.Marshal(body)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal request: %w", err)
	}

	// Create request
	req, err := http.NewRequest("POST", g.config.APIEndpoint, bytes.NewReader(jsonBody))
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}

	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-API-Key", g.config.APIKey)
	req.Header.Set("User-Agent", fmt.Sprintf("GeoIP-Update-Go/%s", version))

	// Make request
	resp, err := g.httpClient.doWithRetry(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	// Parse response
	var urls map[string]string
	if err := json.NewDecoder(resp.Body).Decode(&urls); err != nil {
		return nil, fmt.Errorf("failed to parse response: %w", err)
	}

	g.logger.Info("Received URLs for %d databases", len(urls))
	return urls, nil
}

func unquoteETag(s string) string {
	s = strings.TrimSpace(s)
	if len(s) >= 2 && strings.HasPrefix(s, `"`) && strings.HasSuffix(s, `"`) {
		return s[1 : len(s)-1]
	}
	return s
}

func isWeakETag(etag string) bool {
	return strings.HasPrefix(etag, "W/")
}

func (g *GeoIPUpdater) precheck(url, etag string) (status int, respETag string, lastModified string, total int64, err error) {
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return 0, "", "", 0, err
	}
	req.Header.Set("Range", "bytes=0-0")
	if etag != "" {
		req.Header.Set("If-None-Match", `"`+etag+`"`)
	}
	resp, err := g.httpClient.client.Do(req)
	if err != nil {
		return 0, "", "", 0, err
	}
	resp.Body.Close()
	if cr := resp.Header.Get("Content-Range"); cr != "" {
		total, _ = strconv.ParseInt(cr[strings.LastIndex(cr, "/")+1:], 10, 64)
	}
	return resp.StatusCode, unquoteETag(resp.Header.Get("ETag")), resp.Header.Get("Last-Modified"), total, nil
}

func (g *GeoIPUpdater) isUnchanged(name, url, targetFile string) bool {
	entry, ok := g.manifest[name]
	if !ok || entry.ETag == "" {
		return false
	}
	fi, err := os.Stat(targetFile)
	if err != nil || fi.Size() != entry.Size {
		return false
	}
	status, _, _, _, err := g.precheck(url, entry.ETag)
	if err != nil {
		g.logger.Info("%s: change check failed: %v", name, err)
		return false
	}
	return status == http.StatusNotModified
}

func fileSize(f *os.File) int64 {
	if fi, err := f.Stat(); err == nil {
		return fi.Size()
	}
	return 0
}

func restartFile(f *os.File) error {
	if err := f.Truncate(0); err != nil {
		return err
	}
	_, err := f.Seek(0, io.SeekStart)
	return err
}

func ownsPath(f *os.File, path string) bool {
	a, err := f.Stat()
	if err != nil {
		return false
	}
	b, err := os.Stat(path)
	return err == nil && os.SameFile(a, b)
}

// openStage opens <name>.part fresh, or a private <name>.part.* when an
// existing <name>.part cannot be removed (held open by another run on Windows).
func openStage(dir, name string, remove func(string) error) (*os.File, error) {
	stage := filepath.Join(dir, name+".part")
	if err := remove(stage); err != nil && !os.IsNotExist(err) {
		return os.CreateTemp(dir, name+".part.*")
	}
	return os.OpenFile(stage, os.O_RDWR|os.O_CREATE|os.O_TRUNC, 0o644)
}

func (g *GeoIPUpdater) downloadDatabase(ctx context.Context, name, url string) DownloadResult {
	targetFile := filepath.Join(g.config.TargetDir, name)

	if g.config.OnlyChanged && !g.config.Force && g.isUnchanged(name, url, targetFile) {
		return DownloadResult{Database: name, Unchanged: true}
	}

	g.logger.Info("Downloading: %s", name)

	out, err := openStage(g.config.TargetDir, name, os.Remove)
	if err != nil {
		return DownloadResult{Database: name, Error: fmt.Errorf("failed to open staging file: %w", err)}
	}
	stageFile := out.Name()
	fail := func(err error) DownloadResult {
		owned := ownsPath(out, stageFile)
		out.Close()
		if owned {
			os.Remove(stageFile)
		}
		return DownloadResult{Database: name, Error: err}
	}

	// Resume on interruption/stall (HTTP Range) rather than restarting from
	// byte 0, so large databases complete on flaky links. Retry while the
	// transfer keeps making progress; give up only after a few consecutive
	// no-progress attempts.
	const maxNoProgress = 3
	const hardCap = 50
	noProgress := 0
	restarts := 0
	var etag, lastModified string
	var lastErr error

	for attempt := 1; ; attempt++ {
		if attempt > hardCap {
			return fail(fmt.Errorf("giving up after %d attempts: %w", hardCap, lastErr))
		}

		offset := fileSize(out)

		reqCtx, cancel := context.WithCancel(ctx)
		req, err := http.NewRequestWithContext(reqCtx, "GET", url, nil)
		if err != nil {
			cancel()
			return fail(fmt.Errorf("failed to create request: %w", err))
		}
		if offset > 0 {
			req.Header.Set("Range", fmt.Sprintf("bytes=%d-", offset))
			if etag != "" && !isWeakETag(etag) {
				req.Header.Set("If-Range", `"`+etag+`"`)
			}
			g.logger.Info("Resuming %s from %d bytes (attempt %d)", name, offset, attempt)
		}

		// doWithRetry handles transient/429 retries and fails fast on 401/403.
		resp, err := g.httpClient.doWithRetry(req)
		if err != nil {
			cancel()
			lastErr = err
			noProgress++
			if noProgress >= maxNoProgress {
				return fail(err)
			}
			time.Sleep(5 * time.Second)
			continue
		}

		// 416 => the byte range is past EOF, i.e. we already have the whole
		// file, unless no strong ETag ties those bytes to the current object.
		if resp.StatusCode == http.StatusRequestedRangeNotSatisfiable {
			resp.Body.Close()
			cancel()
			if etag != "" && !isWeakETag(etag) {
				break
			}
			restarts++
			g.logger.Warn("%s: cannot resume (HTTP %d) - restarting from scratch", name, resp.StatusCode)
			if restarts > g.config.MaxRetries {
				return fail(fmt.Errorf("giving up after %d restarts", g.config.MaxRetries))
			}
			if err := restartFile(out); err != nil {
				return fail(fmt.Errorf("failed to reset staging file: %w", err))
			}
			continue
		}

		// A 200 to a resume, or a 206 for a different object, means the
		// partial bytes cannot be kept.
		respETag := unquoteETag(resp.Header.Get("ETag"))
		changed := resp.StatusCode == http.StatusPartialContent && etag != "" && respETag != "" && respETag != etag
		if offset > 0 && (resp.StatusCode == http.StatusOK || changed) {
			restarts++
			g.logger.Warn("%s: cannot resume (HTTP %d) - restarting from scratch", name, resp.StatusCode)
			if restarts > g.config.MaxRetries {
				resp.Body.Close()
				cancel()
				return fail(fmt.Errorf("giving up after %d restarts", g.config.MaxRetries))
			}
			noProgress = 0
			if changed {
				resp.Body.Close()
				cancel()
				etag = ""
				if err := restartFile(out); err != nil {
					return fail(fmt.Errorf("failed to reset staging file: %w", err))
				}
				continue
			}
		}

		if resp.StatusCode == http.StatusOK {
			etag = respETag
			lastModified = resp.Header.Get("Last-Modified")
			offset = 0
			if err := restartFile(out); err != nil {
				resp.Body.Close()
				cancel()
				return fail(fmt.Errorf("failed to reset staging file: %w", err))
			}
		}

		// Copy through a stall guard: abort if no bytes arrive for
		// downloadIdleTimeout (slow-but-progressing transfers are unaffected).
		body := newIdleTimeoutReader(resp.Body, downloadIdleTimeout, cancel)
		_, copyErr := io.Copy(out, body)
		body.Stop()
		resp.Body.Close()
		cancel()

		if copyErr == nil {
			break // read through to EOF => complete
		}

		lastErr = copyErr
		cur := fileSize(out)
		if cur > offset {
			noProgress = 0
			g.logger.Warn("%s: transfer interrupted at %d bytes - resuming (%v)", name, cur, copyErr)
		} else {
			noProgress++
			g.logger.Warn("%s: no progress (attempt %d/%d): %v", name, noProgress, maxNoProgress, copyErr)
			if noProgress >= maxNoProgress {
				return fail(fmt.Errorf("failed to download: %w", copyErr))
			}
			time.Sleep(5 * time.Second)
		}
	}

	size := fileSize(out)
	if size == 0 {
		return fail(fmt.Errorf("downloaded file is empty"))
	}

	// Basic validation for MMDB files
	if strings.HasSuffix(name, ".mmdb") {
		if err := g.validateMMDB(out); err != nil {
			g.logger.Warn("MMDB validation warning for %s: %v", name, err)
		}
	}

	if err := g.install(out, stageFile, targetFile); err != nil {
		return DownloadResult{Database: name, Error: fmt.Errorf("failed to move file: %w", err)}
	}

	if g.config.OnlyChanged {
		g.mu.Lock()
		g.updates[name] = manifestEntry{ETag: etag, LastModified: lastModified, Size: size}
		g.mu.Unlock()
	}

	return DownloadResult{Database: name, Size: size}
}

// install closes out and moves the staged download to target.
func (g *GeoIPUpdater) install(out *os.File, stage, target string) error {
	if !ownsPath(out, stage) {
		// Another run replaced stage: install from our own handle.
		tmp, err := os.CreateTemp(filepath.Dir(stage), filepath.Base(stage)+".*")
		if err != nil {
			out.Close()
			return err
		}
		if _, err = out.Seek(0, io.SeekStart); err == nil {
			_, err = io.Copy(tmp, out)
		}
		out.Close()
		if cerr := tmp.Close(); err == nil {
			err = cerr
		}
		if err == nil {
			err = os.Rename(tmp.Name(), target)
		}
		if err != nil {
			os.Remove(tmp.Name())
		}
		return err
	}
	out.Close()
	if err := os.Rename(stage, target); err != nil {
		// If rename fails, copy instead
		err = g.copyFile(stage, target)
		os.Remove(stage)
		return err
	}
	return nil
}

func (g *GeoIPUpdater) validateMMDB(file *os.File) error {
	// Get file size
	stat, err := file.Stat()
	if err != nil {
		return err
	}
	size := stat.Size()

	// MMDB files have metadata at the end with marker \xab\xcd\xef followed by MaxMind.com
	// Read the last 100KB to find the metadata section
	readSize := int64(100000)
	if size < readSize {
		readSize = size
	}

	// Seek to the position to start reading
	_, err = file.Seek(size-readSize, 0)
	if err != nil {
		return err
	}

	// Read the last portion of the file
	buf := make([]byte, readSize)
	n, err := file.Read(buf)
	if err != nil && err != io.EOF {
		return err
	}

	// Look for the MMDB metadata marker
	marker := []byte("\xab\xcd\xefMaxMind.com")
	if !bytes.Contains(buf[:n], marker) {
		return fmt.Errorf("missing MaxMind metadata marker")
	}

	return nil
}

func (g *GeoIPUpdater) copyFile(src, dst string) error {
	source, err := os.Open(src)
	if err != nil {
		return err
	}
	defer source.Close()

	destination, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer destination.Close()

	_, err = io.Copy(destination, source)
	return err
}

func (g *GeoIPUpdater) updateDatabases() error {
	g.logger.Info("Starting GeoIP database update")
	g.logger.Info("Target directory: %s", g.config.TargetDir)

	// Ensure target directory exists
	if err := os.MkdirAll(g.config.TargetDir, 0755); err != nil {
		return fmt.Errorf("failed to create target directory: %w", err)
	}

	if g.config.OnlyChanged {
		g.manifest = loadManifest(g.config.TargetDir)
	}

	// Get download URLs
	urls, err := g.authenticate()
	if err != nil {
		return fmt.Errorf("authentication failed: %w", err)
	}

	if len(urls) == 0 {
		g.logger.Warn("No databases to download")
		return nil
	}

	// Download databases concurrently
	ctx := context.Background()
	results := make(chan DownloadResult, len(urls))
	semaphore := make(chan struct{}, g.config.MaxConcurrent)
	var wg sync.WaitGroup
	var successCount, failCount int32

	for name, url := range urls {
		wg.Add(1)
		go func(name, url string) {
			defer wg.Done()

			// Acquire semaphore
			semaphore <- struct{}{}
			defer func() { <-semaphore }()

			result := g.downloadDatabase(ctx, name, url)
			results <- result

			if result.Error != nil {
				atomic.AddInt32(&failCount, 1)
				g.logger.Error("Failed to download %s: %v", result.Database, result.Error)
			} else if result.Unchanged {
				atomic.AddInt32(&successCount, 1)
				g.logger.Success("Unchanged: %s", result.Database)
			} else {
				atomic.AddInt32(&successCount, 1)
				g.logger.Success("Successfully downloaded: %s (%d bytes)", result.Database, result.Size)
			}
		}(name, url)
	}

	// Wait for all downloads
	wg.Wait()
	close(results)

	if g.config.OnlyChanged {
		for name, entry := range g.updates {
			if entry.ETag == "" || isWeakETag(entry.ETag) {
				delete(g.manifest, name)
			} else {
				g.manifest[name] = entry
			}
		}
		if err := writeManifest(g.config.TargetDir, g.manifest); err != nil {
			g.logger.Error("Failed to write manifest: %v", err)
		}
	}

	// Summary
	total := len(urls)
	success := int(atomic.LoadInt32(&successCount))
	failed := int(atomic.LoadInt32(&failCount))

	g.logger.Info("Download summary: %d successful, %d failed out of %d", success, failed, total)

	if failed > 0 {
		return fmt.Errorf("failed to download %d databases", failed)
	}

	return nil
}

// timeoutValue is a flag.Value for --timeout/-t that accepts either a bare
// integer interpreted as seconds ("1800") or a Go duration string ("5m",
// "300s", "90s"). Plain integers keep existing callers working; duration
// strings let the GitHub Action forward its documented "5m / 300s" format
// straight through to the binary.
type timeoutValue struct {
	d time.Duration
}

func (t *timeoutValue) String() string {
	if t == nil {
		return ""
	}
	return t.d.String()
}

func (t *timeoutValue) Set(s string) error {
	s = strings.TrimSpace(s)
	// A bare integer means seconds (backward compatible with the old flag.Int).
	if n, err := strconv.Atoi(s); err == nil {
		t.d = time.Duration(n) * time.Second
		return nil
	}
	// Otherwise accept a Go duration string ("5m", "300s", "90s").
	d, err := time.ParseDuration(s)
	if err != nil {
		return fmt.Errorf("invalid value %q: want seconds (e.g. 1800) or a duration (e.g. 5m, 300s)", s)
	}
	t.d = d
	return nil
}

// envError is an invalid GEOIP_* value; it fails the run only when none of
// flags was given on the command line.
type envError struct {
	err   error
	flags []string
}

func envInt(key string, def int, envErrors *[]envError, flags ...string) int {
	value := os.Getenv(key)
	if value == "" {
		return def
	}
	n, err := strconv.Atoi(strings.TrimSpace(value))
	if err != nil {
		*envErrors = append(*envErrors, envError{fmt.Errorf("invalid %s %q: want an integer", key, value), flags})
		return def
	}
	return n
}

func parseFlags() (*Config, error) {
	config := &Config{}

	var envErrors []envError
	retries := envInt("GEOIP_MAX_RETRIES", defaultRetries, &envErrors, "retries", "r")
	concurrent := envInt("GEOIP_CONCURRENT", defaultConcurrent, &envErrors, "concurrent")
	lockTimeout := envInt("GEOIP_LOCK_TIMEOUT", defaultLockTimeout, &envErrors, "lock-timeout")
	timeout := &timeoutValue{d: defaultTimeout * time.Second}
	if value := os.Getenv("GEOIP_TIMEOUT"); value != "" {
		if err := timeout.Set(value); err != nil {
			envErrors = append(envErrors, envError{fmt.Errorf("invalid GEOIP_TIMEOUT: %w", err), []string{"timeout", "t"}})
		}
	}
	onlyChanged := false
	switch os.Getenv("GEOIP_ONLY_CHANGED") {
	case "true", "1", "yes":
		onlyChanged = true
	}

	// Define flags
	flag.StringVar(&config.APIKey, "api-key", os.Getenv("GEOIP_API_KEY"), "API key (or use GEOIP_API_KEY env var)")
	flag.StringVar(&config.APIKey, "k", os.Getenv("GEOIP_API_KEY"), "API key (short)")
	
	flag.StringVar(&config.APIEndpoint, "endpoint", getEnvOrDefault("GEOIP_API_ENDPOINT", defaultEndpoint), "API endpoint URL")
	flag.StringVar(&config.APIEndpoint, "e", getEnvOrDefault("GEOIP_API_ENDPOINT", defaultEndpoint), "API endpoint URL (short)")
	
	flag.StringVar(&config.TargetDir, "directory", getEnvOrDefault("GEOIP_TARGET_DIR", defaultTargetDir), "Target directory")
	flag.StringVar(&config.TargetDir, "d", getEnvOrDefault("GEOIP_TARGET_DIR", defaultTargetDir), "Target directory (short)")
	
	databases := flag.String("databases", getEnvOrDefault("GEOIP_DATABASES", "all"), "Comma-separated database list or 'all'")
	flag.StringVar(databases, "b", getEnvOrDefault("GEOIP_DATABASES", "all"), "Databases (short)")
	
	flag.StringVar(&config.LogFile, "log-file", os.Getenv("GEOIP_LOG_FILE"), "Log file path")
	flag.StringVar(&config.LogFile, "l", os.Getenv("GEOIP_LOG_FILE"), "Log file (short)")
	
	flag.IntVar(&config.MaxRetries, "retries", retries, "Max retries")
	flag.IntVar(&config.MaxRetries, "r", retries, "Max retries (short)")
	
	flag.Var(timeout, "timeout", "Download timeout: seconds (e.g. 1800) or duration (e.g. 5m, 300s)")
	flag.Var(timeout, "t", "Download timeout (short)")
	
	flag.IntVar(&config.MaxConcurrent, "concurrent", concurrent, "Max concurrent downloads")
	
	flag.BoolVar(&config.Quiet, "quiet", false, "Quiet mode")
	flag.BoolVar(&config.Quiet, "q", false, "Quiet mode (short)")
	
	flag.BoolVar(&config.Verbose, "verbose", false, "Verbose output")
	flag.BoolVar(&config.Verbose, "v", false, "Verbose (short)")
	
	flag.BoolVar(&config.NoLock, "no-lock", false, "Don't use lock file")
	flag.BoolVar(&config.NoLock, "n", false, "No lock (short)")

	flag.BoolVar(&config.OnlyChanged, "only-changed", onlyChanged, "Download only databases that changed since the last run")
	flag.BoolVar(&config.Force, "force", false, "Download everything even with --only-changed")
	flag.StringVar(&config.LockFile, "lock-file", os.Getenv("GEOIP_LOCK_FILE"), "Lock on a shared path instead of the PID lock")
	flag.IntVar(&config.LockTimeout, "lock-timeout", lockTimeout, "Seconds to wait for --lock-file")
	
	showVersion := flag.Bool("version", false, "Show version")
	listDatabases := flag.Bool("list-databases", false, "List all available databases and aliases")
	flag.BoolVar(listDatabases, "L", false, "List databases (short)")
	showExamples := flag.Bool("show-examples", false, "Show usage examples for database selection")
	flag.BoolVar(showExamples, "E", false, "Show examples (short)")
	checkNames := flag.Bool("check-names", false, "Validate database names with API without downloading")
	flag.BoolVar(checkNames, "C", false, "Check names (short)")
	validateOnly := flag.Bool("validate-only", false, "Validate existing database files")
	flag.BoolVar(validateOnly, "V", false, "Validate files (short)")
	
	flag.Parse()

	given := map[string]bool{}
	flag.Visit(func(f *flag.Flag) { given[f.Name] = true })
	for _, e := range envErrors {
		overridden := false
		for _, name := range e.flags {
			overridden = overridden || given[name]
		}
		if !overridden {
			return nil, e.err
		}
	}

	if config.LockFile != "" && config.NoLock {
		return nil, fmt.Errorf("--lock-file and --no-lock cannot be combined")
	}

	// Handle version flag
	if *showVersion {
		fmt.Printf("GeoIP Update Go %s\n", displayVersion())
		os.Exit(0)
	}

	// Handle list databases flag
	if *listDatabases {
		listDatabasesCmd()
		os.Exit(0)
	}

	// Handle show examples flag
	if *showExamples {
		showExamplesCmd()
		os.Exit(0)
	}

	// Handle check names flag
	if *checkNames {
		// Need API key for name checking
		if config.APIKey == "" {
			config.APIKey = os.Getenv("GEOIP_API_KEY")
		}
		if config.APIKey == "" {
			return nil, fmt.Errorf("API key required for name checking. Use --api-key or set GEOIP_API_KEY")
		}
		checkDatabaseNamesCmd(config, strings.Split(*databases, ","))
		os.Exit(0)
	}
	
	// Handle validate only flag (file validation)
	if *validateOnly {
		validateDatabaseFilesCmd(config)
		os.Exit(0)
	}

	// Parse databases
	if *databases != "all" {
		config.Databases = strings.Split(*databases, ",")
		for i := range config.Databases {
			config.Databases[i] = strings.TrimSpace(config.Databases[i])
		}
	} else {
		config.Databases = []string{"all"}
	}

	// timeoutValue already parsed seconds-or-duration into a time.Duration.
	config.Timeout = timeout.d

	// Clean and normalize the API endpoint
	config.APIEndpoint = strings.TrimRight(config.APIEndpoint, "/ \t\n\r")
	
	// Auto-append /auth if it's the base geoipdb.net domain
	if config.APIEndpoint == "https://geoipdb.net" || config.APIEndpoint == "http://geoipdb.net" {
		config.APIEndpoint = config.APIEndpoint + "/auth"
		log.Printf("Info: Appended /auth to endpoint: %s\n", config.APIEndpoint)
	}

	// Validate configuration
	if config.APIKey == "" {
		return nil, fmt.Errorf("API key not provided. Use --api-key or set GEOIP_API_KEY")
	}

	// Validate API key format
	if !isValidAPIKey(config.APIKey) {
		return nil, fmt.Errorf("invalid API key format")
	}

	if config.APIEndpoint == defaultEndpoint {
		log.Println("Warning: Using placeholder API endpoint. Please update with your actual API Gateway URL.")
	}

	return config, nil
}

func getEnvOrDefault(key, defaultValue string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return defaultValue
}

func isValidAPIKey(key string) bool {
	// Allow shorter keys for testing (minimum 8 characters)
	if len(key) < 8 || len(key) > 64 {
		return false
	}
	for _, c := range key {
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-') {
			return false
		}
	}
	return true
}

func minDuration(a, b time.Duration) time.Duration {
	if a < b {
		return a
	}
	return b
}

// DatabaseInfo represents the /databases endpoint response
type DatabaseInfo struct {
	Total     int `json:"total"`
	Providers struct {
		MaxMind struct {
			Count     int `json:"count"`
			Databases []struct {
				Name    string   `json:"name"`
				Aliases []string `json:"aliases"`
			} `json:"databases"`
		} `json:"maxmind"`
		IP2Location struct {
			Count     int `json:"count"`
			Databases []struct {
				Name    string   `json:"name"`
				Aliases []string `json:"aliases"`
			} `json:"databases"`
		} `json:"ip2location"`
	} `json:"providers"`
	Examples struct {
		SingleDatabase    []string   `json:"single_database"`
		MultipleDatabases [][]string `json:"multiple_databases"`
		BulkSelection     []string   `json:"bulk_selection"`
	} `json:"examples"`
}

// fetchDatabasesInfo fetches database information from the /databases endpoint
func fetchDatabasesInfo(endpoint string) (*DatabaseInfo, error) {
	// Convert /auth endpoint to /databases endpoint
	databasesEndpoint := strings.Replace(endpoint, "/auth", "/databases", 1)
	
	client := &http.Client{
		Timeout: 10 * time.Second,
	}
	
	resp, err := client.Get(databasesEndpoint)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("database discovery not available (HTTP %d)", resp.StatusCode)
	}
	
	var dbInfo DatabaseInfo
	if err := json.NewDecoder(resp.Body).Decode(&dbInfo); err != nil {
		return nil, err
	}
	
	return &dbInfo, nil
}

// listDatabasesCmd lists all available databases and aliases
func listDatabasesCmd() {
	endpoint := getEnvOrDefault("GEOIP_API_ENDPOINT", defaultEndpoint)
	endpoint = strings.TrimRight(endpoint, "/ \t\n\r")
	
	dbInfo, err := fetchDatabasesInfo(endpoint)
	if err != nil {
		fmt.Println("Database discovery not available.")
		fmt.Println("Using legacy database list:")
		fmt.Println("  • GeoIP2-City.mmdb")
		fmt.Println("  • GeoIP2-Country.mmdb")
		fmt.Println("  • GeoIP2-ISP.mmdb")
		fmt.Println("  • GeoIP2-Connection-Type.mmdb")
		fmt.Println("  • IP-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN")
		fmt.Println("  • IPV6-COUNTRY-REGION-CITY-LATITUDE-LONGITUDE-ISP-DOMAIN-MOBILE-USAGETYPE.BIN")
		fmt.Println("  • IP2PROXY-IP-PROXYTYPE-COUNTRY.BIN")
		return
	}
	
	fmt.Println("Available GeoIP Databases:")
	fmt.Println("=========================")
	fmt.Println()
	fmt.Printf("Total databases: %d\n", dbInfo.Total)
	fmt.Println()
	
	// MaxMind databases
	fmt.Printf("MaxMind databases (%d):\n", dbInfo.Providers.MaxMind.Count)
	for _, db := range dbInfo.Providers.MaxMind.Databases {
		aliases := strings.Join(db.Aliases, ", ")
		fmt.Printf("  • %s (aliases: %s)\n", db.Name, aliases)
	}
	fmt.Println()
	
	// IP2Location databases
	fmt.Printf("IP2Location databases (%d):\n", dbInfo.Providers.IP2Location.Count)
	for _, db := range dbInfo.Providers.IP2Location.Databases {
		aliases := strings.Join(db.Aliases, ", ")
		fmt.Printf("  • %s (aliases: %s)\n", db.Name, aliases)
	}
	fmt.Println()
	
	fmt.Println("Bulk Selection Options:")
	fmt.Println("  • all - All databases")
	fmt.Println("  • maxmind/all - All MaxMind databases")
	fmt.Println("  • ip2location/all - All IP2Location databases")
	fmt.Println()
	fmt.Println("Usage Notes:")
	fmt.Println("  • Database names are case-insensitive")
	fmt.Println("  • File extensions are optional in most cases")
	fmt.Println("  • Use short aliases for easier selection")
}

// showExamplesCmd shows usage examples for database selection
func showExamplesCmd() {
	endpoint := getEnvOrDefault("GEOIP_API_ENDPOINT", defaultEndpoint)
	endpoint = strings.TrimRight(endpoint, "/ \t\n\r")
	
	dbInfo, err := fetchDatabasesInfo(endpoint)
	if err != nil {
		fmt.Println("Database Selection Examples (Legacy Mode):")
		fmt.Println("==========================================")
	} else {
		fmt.Println("Database Selection Examples:")
		fmt.Println("===========================")
		fmt.Println()
		
		if len(dbInfo.Examples.SingleDatabase) > 0 {
			fmt.Println("Single Database Selection:")
			for _, example := range dbInfo.Examples.SingleDatabase {
				fmt.Printf("  geoip-update --api-key YOUR_KEY --databases \"%s\"\n", example)
			}
			fmt.Println()
		}
		
		if len(dbInfo.Examples.MultipleDatabases) > 0 {
			fmt.Println("Multiple Database Selection:")
			for _, examples := range dbInfo.Examples.MultipleDatabases {
				dbs := strings.Join(examples, ",")
				fmt.Printf("  geoip-update --api-key YOUR_KEY --databases \"%s\"\n", dbs)
			}
			fmt.Println()
		}
		
		if len(dbInfo.Examples.BulkSelection) > 0 {
			fmt.Println("Bulk Selection:")
			for _, example := range dbInfo.Examples.BulkSelection {
				fmt.Printf("  geoip-update --api-key YOUR_KEY --databases \"%s\"\n", example)
			}
			fmt.Println()
		}
	}
	
	fmt.Println("Common Examples:")
	fmt.Println("  # Download all databases")
	fmt.Println("  geoip-update --api-key YOUR_KEY")
	fmt.Println()
	fmt.Println("  # Download specific databases using aliases")
	fmt.Println("  geoip-update --api-key YOUR_KEY --databases \"city,country\"")
	fmt.Println()
	fmt.Println("  # Download all MaxMind databases")
	fmt.Println("  geoip-update --api-key YOUR_KEY --databases \"maxmind/all\"")
	fmt.Println()
	fmt.Println("  # Case insensitive selection")
	fmt.Println("  geoip-update --api-key YOUR_KEY --databases \"CITY,ISP\"")
	fmt.Println()
	fmt.Println("  # Local testing with Docker API")
	fmt.Println("  geoip-update --api-key test-key-1 --endpoint http://localhost:8080/auth --databases \"city\"")
}

// checkDatabaseNamesCmd validates database names with API without downloading
func checkDatabaseNamesCmd(config *Config, databases []string) {
	if len(databases) == 0 || (len(databases) == 1 && databases[0] == "all") {
		fmt.Println("✓ Database selection 'all' is valid")
		return
	}
	
	// Clean databases
	for i := range databases {
		databases[i] = strings.TrimSpace(databases[i])
	}
	
	// Prepare request body
	body := map[string]interface{}{
		"databases": databases,
	}
	
	jsonBody, err := json.Marshal(body)
	if err != nil {
		fmt.Printf("✗ Validation failed: %v\n", err)
		os.Exit(1)
	}
	
	// Create request
	req, err := http.NewRequest("POST", config.APIEndpoint, bytes.NewReader(jsonBody))
	if err != nil {
		fmt.Printf("✗ Validation failed: %v\n", err)
		os.Exit(1)
	}
	
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("X-API-Key", config.APIKey)
	
	// Make request
	client := &http.Client{
		Timeout: 10 * time.Second,
	}
	
	resp, err := client.Do(req)
	if err != nil {
		fmt.Printf("✗ Validation failed: %v\n", err)
		os.Exit(1)
	}
	defer resp.Body.Close()
	
	if resp.StatusCode == http.StatusOK {
		var result map[string]string
		if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
			fmt.Printf("✗ Validation failed: %v\n", err)
			os.Exit(1)
		}
		
		fmt.Println("✓ All database names are valid")
		fmt.Printf("✓ Resolved to %d database(s)\n", len(result))
		
		// Show resolved databases
		dbs := make([]string, 0, len(result))
		for db := range result {
			dbs = append(dbs, db)
		}
		sort.Strings(dbs)
		for _, db := range dbs {
			fmt.Printf("  → %s\n", db)
		}
	} else {
		// Try to parse error message
		var errorResp struct {
			Detail string `json:"detail"`
		}
		if err := json.NewDecoder(resp.Body).Decode(&errorResp); err == nil && errorResp.Detail != "" {
			fmt.Printf("✗ Validation failed: %s\n", errorResp.Detail)
		} else {
			fmt.Printf("✗ Validation failed: HTTP %d\n", resp.StatusCode)
		}
		os.Exit(1)
	}
}

// validateDatabaseFilesCmd validates existing database files
func validateDatabaseFilesCmd(config *Config) {
	fmt.Println("Validating database files...")
	
	// Check if directory exists
	if _, err := os.Stat(config.TargetDir); os.IsNotExist(err) {
		fmt.Printf("✗ Directory does not exist: %s\n", config.TargetDir)
		os.Exit(1)
	}
	
	var totalFiles, validFiles, invalidFiles int
	var hasErrors bool
	
	// Validate MMDB files
	mmdbFiles, err := filepath.Glob(filepath.Join(config.TargetDir, "*.mmdb"))
	if err == nil {
		for _, file := range mmdbFiles {
			totalFiles++
			basename := filepath.Base(file)
			
			// Check file size
			info, err := os.Stat(file)
			if err != nil {
				fmt.Printf("  ❌ %s - Cannot read file: %v\n", basename, err)
				invalidFiles++
				hasErrors = true
				continue
			}
			
			if info.Size() < 1000 {
				fmt.Printf("  ❌ %s - File too small (%d bytes)\n", basename, info.Size())
				invalidFiles++
				hasErrors = true
				continue
			}
			
			// Validate MMDB format
			if err := validateMMDBFile(file); err != nil {
				fmt.Printf("  ❌ %s - Invalid MMDB format: %v\n", basename, err)
				invalidFiles++
				hasErrors = true
			} else {
				sizeMB := info.Size() / 1024 / 1024
				fmt.Printf("  ✅ %s (%dMB) - Valid MMDB format\n", basename, sizeMB)
				validFiles++
			}
		}
	}
	
	// Validate BIN files
	binFiles, err := filepath.Glob(filepath.Join(config.TargetDir, "*.BIN"))
	if err == nil {
		for _, file := range binFiles {
			totalFiles++
			basename := filepath.Base(file)
			
			// Check file size
			info, err := os.Stat(file)
			if err != nil {
				fmt.Printf("  ❌ %s - Cannot read file: %v\n", basename, err)
				invalidFiles++
				hasErrors = true
				continue
			}
			
			if info.Size() < 1000 {
				fmt.Printf("  ❌ %s - File too small (%d bytes)\n", basename, info.Size())
				invalidFiles++
				hasErrors = true
				continue
			}
			
			// Basic BIN validation - check if it's binary data
			if err := validateBINFile(file); err != nil {
				fmt.Printf("  ⚠️  %s - Could not verify BIN format: %v\n", basename, err)
				// Don't count as invalid since BIN validation is harder
			} else {
				sizeMB := info.Size() / 1024 / 1024
				fmt.Printf("  ✅ %s (%dMB) - Valid BIN format\n", basename, sizeMB)
				validFiles++
			}
		}
	}
	
	// Summary
	fmt.Println("\nValidation Summary:")
	fmt.Printf("  Total files: %d\n", totalFiles)
	fmt.Printf("  Valid files: %d\n", validFiles)
	fmt.Printf("  Invalid files: %d\n", invalidFiles)
	
	if totalFiles == 0 {
		fmt.Println("\n✗ No database files found!")
		os.Exit(1)
	}
	
	if hasErrors {
		fmt.Println("\n✗ Validation FAILED - some databases are invalid!")
		os.Exit(1)
	} else {
		fmt.Println("\n✓ Validation PASSED - all databases are valid!")
		os.Exit(0)
	}
}

// validateMMDBFile validates a single MMDB file
func validateMMDBFile(path string) error {
	// Reuse existing validateMMDB logic
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()
	
	// Get file size
	stat, err := file.Stat()
	if err != nil {
		return err
	}
	size := stat.Size()
	
	// MMDB files have metadata at the end with marker \xab\xcd\xef followed by MaxMind.com
	// Read the last 100KB to find the metadata section
	readSize := int64(100000)
	if size < readSize {
		readSize = size
	}
	
	// Seek to the position to start reading
	_, err = file.Seek(size-readSize, 0)
	if err != nil {
		return err
	}
	
	// Read the last portion of the file
	buf := make([]byte, readSize)
	n, err := file.Read(buf)
	if err != nil && err != io.EOF {
		return err
	}
	
	// Look for the MMDB metadata marker
	marker := []byte("\xab\xcd\xefMaxMind.com")
	if !bytes.Contains(buf[:n], marker) {
		return fmt.Errorf("missing MaxMind metadata marker")
	}
	
	return nil
}

// validateBINFile validates a BIN format file (IP2Location)
func validateBINFile(path string) error {
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()
	
	// Read first 10KB to check for IP2Location markers
	buf := make([]byte, 10000)
	n, err := file.Read(buf)
	if err != nil && err != io.EOF {
		return err
	}
	
	// Check if file contains binary data (not text)
	for i := 0; i < n && i < 100; i++ {
		if buf[i] < 0x20 && buf[i] != 0x09 && buf[i] != 0x0A && buf[i] != 0x0D {
			// Found non-printable character, likely binary
			return nil
		}
	}
	
	// If we get here, file might be text (error response)
	return fmt.Errorf("file appears to be text, not binary")
}

func main() {
	// Parse configuration
	config, err := parseFlags()
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}

	// Setup logger
	logger, err := newLogger(config)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to setup logger: %v\n", err)
		os.Exit(1)
	}
	defer logger.Close()

	logger.Info("GeoIP Update Script starting (v%s)", version)

	// Acquire lock
	if config.LockFile != "" {
		lockFile, err := acquireSharedLock(config.LockFile, config.LockTimeout, logger)
		if err != nil {
			logger.Error("%v", err)
			os.Exit(1)
		}
		defer lockFile.Close()
	} else {
		lock := newLockFile(config.NoLock)
		if err := lock.Acquire(); err != nil {
			logger.Error("Failed to acquire lock: %v", err)
			os.Exit(1)
		}
		defer lock.Release()
	}

	// Create updater
	updater, err := newGeoIPUpdater(config, logger)
	if err != nil {
		logger.Error("Failed to initialize updater: %v", err)
		os.Exit(1)
	}

	// Run update
	if err := updater.updateDatabases(); err != nil {
		logger.Error("Update failed: %v", err)
		os.Exit(1)
	}

	logger.Success("GeoIP update completed successfully")
}