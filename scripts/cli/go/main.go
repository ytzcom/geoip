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
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const (
	version           = "1.0.0"
	defaultEndpoint   = "REPLACE_WITH_DEPLOYED_API_GATEWAY_URL/auth"
	defaultTargetDir  = "./geoip"
	defaultRetries    = 3
	defaultTimeout    = 300
	defaultConcurrent = 4
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
}

// DownloadResult represents the result of a database download
type DownloadResult struct {
	Database string
	Size     int64
	Error    error
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

// HTTPClient wraps http.Client with retry logic
type HTTPClient struct {
	client     *http.Client
	maxRetries int
	logger     *Logger
}

func newHTTPClient(timeout time.Duration, maxRetries int, logger *Logger) *HTTPClient {
	return &HTTPClient{
		client: &http.Client{
			Timeout: timeout,
			Transport: &http.Transport{
				TLSClientConfig: &tls.Config{
					MinVersion: tls.VersionTLS12,
				},
				MaxIdleConns:       100,
				IdleConnTimeout:    90 * time.Second,
				DisableCompression: false,
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
		case http.StatusOK:
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
	tempDir    string
}

func newGeoIPUpdater(config *Config, logger *Logger) (*GeoIPUpdater, error) {
	// Create temp directory
	tempDir, err := os.MkdirTemp("", "geoip-update-*")
	if err != nil {
		return nil, fmt.Errorf("failed to create temp directory: %w", err)
	}

	return &GeoIPUpdater{
		config:     config,
		httpClient: newHTTPClient(config.Timeout, config.MaxRetries, logger),
		logger:     logger,
		tempDir:    tempDir,
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

func (g *GeoIPUpdater) downloadDatabase(ctx context.Context, name, url string) DownloadResult {
	g.logger.Info("Downloading: %s", name)

	tempFile := filepath.Join(g.tempDir, name)
	targetFile := filepath.Join(g.config.TargetDir, name)

	// Create request with context
	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return DownloadResult{Database: name, Error: fmt.Errorf("failed to create request: %w", err)}
	}

	// Download file
	resp, err := g.httpClient.doWithRetry(req)
	if err != nil {
		return DownloadResult{Database: name, Error: err}
	}
	defer resp.Body.Close()

	// Create temp file
	out, err := os.Create(tempFile)
	if err != nil {
		return DownloadResult{Database: name, Error: fmt.Errorf("failed to create temp file: %w", err)}
	}
	defer out.Close()

	// Copy data
	size, err := io.Copy(out, resp.Body)
	if err != nil {
		return DownloadResult{Database: name, Error: fmt.Errorf("failed to download: %w", err)}
	}

	// Validate file
	if size == 0 {
		return DownloadResult{Database: name, Error: fmt.Errorf("downloaded file is empty")}
	}

	// Basic validation for MMDB files
	if strings.HasSuffix(name, ".mmdb") {
		if err := g.validateMMDB(tempFile); err != nil {
			g.logger.Warn("MMDB validation warning for %s: %v", name, err)
		}
	}

	// Move to target location
	if err := os.Rename(tempFile, targetFile); err != nil {
		// If rename fails (cross-device), copy instead
		if err := g.copyFile(tempFile, targetFile); err != nil {
			return DownloadResult{Database: name, Error: fmt.Errorf("failed to move file: %w", err)}
		}
		os.Remove(tempFile)
	}

	return DownloadResult{Database: name, Size: size}
}

func (g *GeoIPUpdater) validateMMDB(path string) error {
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()

	// Read first 4KB to check for MMDB marker
	buf := make([]byte, 4096)
	n, err := file.Read(buf)
	if err != nil && err != io.EOF {
		return err
	}

	if !bytes.Contains(buf[:n], []byte("MMDB")) {
		return fmt.Errorf("missing MMDB marker")
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
			} else {
				atomic.AddInt32(&successCount, 1)
				g.logger.Success("Successfully downloaded: %s (%d bytes)", result.Database, result.Size)
			}
		}(name, url)
	}

	// Wait for all downloads
	wg.Wait()
	close(results)

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

func (g *GeoIPUpdater) cleanup() {
	if g.tempDir != "" {
		g.logger.Info("Cleaning up temporary files")
		os.RemoveAll(g.tempDir)
	}
}

func parseFlags() (*Config, error) {
	config := &Config{}

	// Define flags
	flag.StringVar(&config.APIKey, "api-key", os.Getenv("GEOIP_API_KEY"), "API key (or use GEOIP_API_KEY env var)")
	flag.StringVar(&config.APIKey, "k", os.Getenv("GEOIP_API_KEY"), "API key (short)")
	
	flag.StringVar(&config.APIEndpoint, "endpoint", getEnvOrDefault("GEOIP_API_ENDPOINT", defaultEndpoint), "API endpoint URL")
	flag.StringVar(&config.APIEndpoint, "e", getEnvOrDefault("GEOIP_API_ENDPOINT", defaultEndpoint), "API endpoint URL (short)")
	
	flag.StringVar(&config.TargetDir, "directory", getEnvOrDefault("GEOIP_TARGET_DIR", defaultTargetDir), "Target directory")
	flag.StringVar(&config.TargetDir, "d", getEnvOrDefault("GEOIP_TARGET_DIR", defaultTargetDir), "Target directory (short)")
	
	databases := flag.String("databases", "all", "Comma-separated database list or 'all'")
	flag.StringVar(databases, "b", "all", "Databases (short)")
	
	flag.StringVar(&config.LogFile, "log-file", os.Getenv("GEOIP_LOG_FILE"), "Log file path")
	flag.StringVar(&config.LogFile, "l", os.Getenv("GEOIP_LOG_FILE"), "Log file (short)")
	
	flag.IntVar(&config.MaxRetries, "retries", defaultRetries, "Max retries")
	flag.IntVar(&config.MaxRetries, "r", defaultRetries, "Max retries (short)")
	
	timeout := flag.Int("timeout", defaultTimeout, "Download timeout in seconds")
	flag.IntVar(timeout, "t", defaultTimeout, "Timeout (short)")
	
	flag.IntVar(&config.MaxConcurrent, "concurrent", defaultConcurrent, "Max concurrent downloads")
	
	flag.BoolVar(&config.Quiet, "quiet", false, "Quiet mode")
	flag.BoolVar(&config.Quiet, "q", false, "Quiet mode (short)")
	
	flag.BoolVar(&config.Verbose, "verbose", false, "Verbose output")
	flag.BoolVar(&config.Verbose, "v", false, "Verbose (short)")
	
	flag.BoolVar(&config.NoLock, "no-lock", false, "Don't use lock file")
	flag.BoolVar(&config.NoLock, "n", false, "No lock (short)")
	
	showVersion := flag.Bool("version", false, "Show version")
	
	flag.Parse()

	// Handle version flag
	if *showVersion {
		fmt.Printf("GeoIP Update Go v%s\n", version)
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

	// Convert timeout to duration
	config.Timeout = time.Duration(*timeout) * time.Second

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
	if len(key) < 20 || len(key) > 64 {
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
	lock := newLockFile(config.NoLock)
	if err := lock.Acquire(); err != nil {
		logger.Error("Failed to acquire lock: %v", err)
		os.Exit(1)
	}
	defer lock.Release()

	// Create updater
	updater, err := newGeoIPUpdater(config, logger)
	if err != nil {
		logger.Error("Failed to initialize updater: %v", err)
		os.Exit(1)
	}
	defer updater.cleanup()

	// Run update
	if err := updater.updateDatabases(); err != nil {
		logger.Error("Update failed: %v", err)
		os.Exit(1)
	}

	logger.Success("GeoIP update completed successfully")
}