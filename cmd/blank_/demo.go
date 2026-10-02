package main

import (
	"encoding/json"
	"os"
	"path/filepath"

	"writer/examples"
	"writer/internal/document"
)

var tutorialSource = examples.Tutorial

func (a *App) openDemo() (document.Snapshot, error) {
	return a.openDraft("Tutorial.typ", tutorialSource, "tutorial-")
}

func (a *App) openBlankDraft() (document.Snapshot, error) {
	return a.openDraft("Untitled.typ", "\n", "untitled-")
}

func (a *App) openDraft(entry, source, prefix string) (document.Snapshot, error) {
	folder := filepath.Join(a.dataDir, "drafts")
	if err := os.MkdirAll(folder, 0700); err != nil {
		return document.Snapshot{}, err
	}
	root, err := os.MkdirTemp(folder, prefix)
	if err != nil {
		return document.Snapshot{}, err
	}
	config, _ := json.Marshal(map[string]string{"entry": entry})
	for name, content := range map[string][]byte{entry: []byte(source), "writer.json": config, ".blank-draft": []byte("unsaved\n")} {
		if err := os.WriteFile(filepath.Join(root, name), content, 0600); err != nil {
			os.RemoveAll(root)
			return document.Snapshot{}, err
		}
	}
	return a.open(root)
}
