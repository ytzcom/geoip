package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

const manifestName = ".geoip-update.json"

type manifestEntry struct {
	ETag         string `json:"etag"`
	LastModified string `json:"last_modified"`
	Size         int64  `json:"size"`
}

func loadManifest(dir string) map[string]manifestEntry {
	data, err := os.ReadFile(filepath.Join(dir, manifestName))
	if err != nil {
		return map[string]manifestEntry{}
	}
	var doc struct {
		Files map[string]manifestEntry `json:"files"`
	}
	if json.Unmarshal(data, &doc) != nil || doc.Files == nil {
		return map[string]manifestEntry{}
	}
	return doc.Files
}

func safeValue(s string) bool {
	return !strings.ContainsAny(s, "\"\\|") && !strings.ContainsFunc(s, func(r rune) bool { return r < 32 || r == 127 })
}

func writeManifest(dir string, entries map[string]manifestEntry) error {
	names := make([]string, 0, len(entries))
	for n, e := range entries {
		if safeValue(n) && safeValue(e.ETag) && safeValue(e.LastModified) {
			names = append(names, n)
		}
	}
	sort.Strings(names)
	var b strings.Builder
	b.WriteString("{\n  \"version\": 1,\n  \"files\": {\n")
	for i, n := range names {
		e := entries[n]
		comma := ","
		if i == len(names)-1 {
			comma = ""
		}
		fmt.Fprintf(&b, "    \"%s\": {\"etag\": \"%s\", \"last_modified\": \"%s\", \"size\": %d}%s\n", n, e.ETag, e.LastModified, e.Size, comma)
	}
	b.WriteString("  }\n}\n")
	part := filepath.Join(dir, manifestName+".part")
	if err := os.WriteFile(part, []byte(b.String()), 0o644); err != nil {
		os.Remove(part)
		return err
	}
	if err := os.Rename(part, filepath.Join(dir, manifestName)); err != nil {
		os.Remove(part)
		return err
	}
	return nil
}
