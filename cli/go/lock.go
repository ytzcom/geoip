package main

import (
	"fmt"
	"os"
	"time"
)

func acquireSharedLock(path string, timeout int, logger *Logger) (*os.File, error) {
	for waited := 0; ; waited++ {
		f, err := openLockFile(path)
		if err == nil {
			if err = tryLock(f); err == nil {
				host, _ := os.Hostname()
				werr := f.Truncate(0)
				if werr == nil {
					_, werr = fmt.Fprintf(f, "pid=%d host=%s started=%s\n", os.Getpid(), host, time.Now().UTC().Format("2006-01-02T15:04:05Z"))
				}
				if werr != nil {
					logger.Warn("Could not write lock details to %s: %v", path, werr)
				}
				return f, nil
			}
			f.Close()
			if !lockBusy(err) {
				return nil, fmt.Errorf("failed to lock %s: %w", path, err)
			}
		} else if !lockBusy(err) {
			return nil, err
		}
		if waited >= timeout {
			return nil, fmt.Errorf("Timed out after %d s waiting for lock %s", timeout, path)
		}
		time.Sleep(time.Second)
	}
}
