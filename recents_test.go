package main

import (
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"
	"writer/internal/document"
)

func TestRecentsPersistDeduplicateAndForgetWithoutDeletingFiles(t *testing.T) {
	a := &App{dataDir: t.TempDir()}
	root := t.TempDir()
	first := document.Snapshot{ID: "first", Root: root, Entry: "One.typ"}
	second := document.Snapshot{ID: "second", Root: root, Entry: "Two.typ"}
	for _, name := range []string{first.Entry, second.Entry} {
		if err := os.WriteFile(filepath.Join(root, name), []byte("Document."), 0600); err != nil {
			t.Fatal(err)
		}
	}
	a.rememberDocument(first, "")
	a.rememberDocument(second, "")
	a.rememberDocument(first, "")
	restarted := &App{dataDir: a.dataDir}
	items := restarted.recentDocuments()
	if len(items) != 2 || items[0].Name != "One.typ" || !items[0].Available {
		t.Fatalf("wrong recents: %+v", items)
	}
	if err := restarted.forgetDocument(items[0].Path); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(root, first.Entry)); err != nil {
		t.Fatal("forget removed document", err)
	}
	if len(a.recentDocuments()) != 1 {
		t.Fatal("forget was not persisted")
	}
}

func TestRecentsExcludeDraftsAndKeepMissingFilesRemovable(t *testing.T) {
	a := &App{dataDir: t.TempDir()}
	a.rememberDocument(document.Snapshot{ID: "guide", Root: t.TempDir(), Entry: "Tutorial.typ", Unsaved: true}, "")
	if len(a.recentDocuments()) != 0 {
		t.Fatal("Help draft polluted recents")
	}
	a.rememberDocument(document.Snapshot{ID: "missing", Root: t.TempDir(), Entry: "Moved.typ"}, "")
	items := a.recentDocuments()
	if len(items) != 1 || items[0].Available {
		t.Fatalf("missing path should stay visible as unavailable: %+v", items)
	}
}

func TestRecentsMergeConcurrentWindowsAndTrackRename(t *testing.T) {
	dir := t.TempDir()
	var wg sync.WaitGroup
	for i := 0; i < 6; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			a := &App{dataDir: dir}
			a.rememberDocument(document.Snapshot{ID: "document", Root: dir, Entry: time.Unix(int64(i), 0).Format("150405") + ".typ"}, "")
		}(i)
	}
	wg.Wait()
	a := &App{dataDir: dir}
	old := a.recentDocuments()
	if len(old) != 6 {
		t.Fatalf("concurrent update lost entries: %d", len(old))
	}
	a.rememberDocument(document.Snapshot{ID: "renamed", Root: dir, Entry: "Renamed.typ"}, old[0].Path)
	items := a.recentDocuments()
	if len(items) != 6 || items[0].Name != "Renamed.typ" {
		t.Fatalf("rename duplicated recent entry: %+v", items)
	}
}
