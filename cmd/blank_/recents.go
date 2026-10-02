package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"time"

	"writer/internal/document"
)

// All windows share this small index, never document contents or undo state.
var recentsMu sync.Mutex

type recentDocument struct {
	Path      string    `json:"path"`
	Name      string    `json:"name"`
	Folder    string    `json:"folder"`
	Opened    time.Time `json:"opened"`
	Available bool      `json:"available"`
}

func (a *App) readRecents() []recentDocument {
	result := []recentDocument{}
	data, err := os.ReadFile(filepath.Join(a.dataDir, "recent-documents.json"))
	if err == nil {
		_ = json.Unmarshal(data, &result)
	}
	if result == nil {
		result = []recentDocument{}
	}
	return result
}

func (a *App) writeRecents(items []recentDocument) error {
	data, err := json.Marshal(items)
	if err != nil {
		return err
	}
	if err = os.MkdirAll(a.dataDir, 0700); err != nil {
		return err
	}
	file, err := os.CreateTemp(a.dataDir, ".recents-*")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	if _, err = file.Write(data); err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(file.Name(), filepath.Join(a.dataDir, "recent-documents.json"))
}

func (a *App) rememberDocument(s document.Snapshot, previous string) {
	if s.ID == "" || s.Unsaved {
		return
	}
	recentsMu.Lock()
	defer recentsMu.Unlock()
	path := filepath.Join(s.Root, s.Entry)
	items := []recentDocument{{Path: path, Name: filepath.Base(s.Entry), Folder: filepath.Dir(path), Opened: time.Now(), Available: true}}
	for _, item := range a.readRecents() {
		if item.Path != path && item.Path != previous && len(items) < 10 {
			items = append(items, item)
		}
	}
	// A recent-list failure must never turn a successful document open/save into an error.
	_ = a.writeRecents(items)
}

func (a *App) recentDocuments() []recentDocument {
	recentsMu.Lock()
	defer recentsMu.Unlock()
	items := a.readRecents()
	for i := range items {
		info, err := os.Stat(items[i].Path)
		items[i].Available = err == nil && info.Mode().IsRegular()
	}
	return items
}

func (a *App) forgetDocument(path string) error {
	recentsMu.Lock()
	defer recentsMu.Unlock()
	items := a.readRecents()
	kept := []recentDocument{}
	for _, item := range items {
		if item.Path != path {
			kept = append(kept, item)
		}
	}
	return a.writeRecents(kept)
}
