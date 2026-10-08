package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestManifestRoundTripIsCanonical(t *testing.T) {
	dir := t.TempDir()
	in := map[string]manifestEntry{
		"b.BIN":  {ETag: "e2-46", LastModified: "Mon, 23 Mar 2026 00:34:53 GMT", Size: 2},
		"a.mmdb": {ETag: "e1-16", LastModified: "Mon, 05 Oct 2026 00:38:39 GMT", Size: 1},
		"bad":    {ETag: "has\"quote", LastModified: "x", Size: 3},
	}
	if err := writeManifest(dir, in); err != nil {
		t.Fatal(err)
	}
	got, _ := os.ReadFile(filepath.Join(dir, manifestName))
	want := "{\n  \"version\": 1,\n  \"files\": {\n" +
		"    \"a.mmdb\": {\"etag\": \"e1-16\", \"last_modified\": \"Mon, 05 Oct 2026 00:38:39 GMT\", \"size\": 1},\n" +
		"    \"b.BIN\": {\"etag\": \"e2-46\", \"last_modified\": \"Mon, 23 Mar 2026 00:34:53 GMT\", \"size\": 2}\n" +
		"  }\n}\n"
	if string(got) != want {
		t.Fatalf("got\n%s\nwant\n%s", got, want)
	}
	if back := loadManifest(dir); len(back) != 2 || back["a.mmdb"].Size != 1 {
		t.Fatalf("round trip: %+v", back)
	}
}

func TestCorruptManifestIsEmpty(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, manifestName), []byte("{ not json"), 0o644)
	if len(loadManifest(dir)) != 0 {
		t.Fatal("corrupt manifest should be empty")
	}
}
