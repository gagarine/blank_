package document

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRenameKeepsContentHistoryAndProjectSettings(t *testing.T) {
	s, p := fixture(t, "Original.\n")
	os.WriteFile(filepath.Join(p.Root, "writer.json"), []byte(`{"entry":"main.typ","preference":"keep"}`), 0600)
	p, err := s.Apply(tx(p, p.Entry, 0, 8, "Edited", "user"))
	if err != nil {
		t.Fatal(err)
	}
	renamed, err := s.RenameEntry(p.ID, "Research")
	if err != nil {
		t.Fatal(err)
	}
	if renamed.Entry != "Research.typ" || renamed.ID == p.ID || renamed.Files[renamed.Entry].Text != "Edited.\n" {
		t.Fatal(renamed)
	}
	if _, err := os.Stat(filepath.Join(p.Root, "main.typ")); !os.IsNotExist(err) {
		t.Fatal("old name remains", err)
	}
	config, _ := os.ReadFile(filepath.Join(p.Root, "writer.json"))
	if !strings.Contains(string(config), `"Research.typ"`) || !strings.Contains(string(config), `"keep"`) {
		t.Fatal(string(config))
	}
	if _, err := s.Apply(tx(p, p.Entry, 0, 0, "stale", "agent")); err == nil {
		t.Fatal("accepted stale project identity")
	}
	undone, err := s.Undo("")
	if err != nil || undone.Files[renamed.Entry].Text != "Original.\n" {
		t.Fatal(undone, err)
	}
	redone, err := s.Redo()
	if err != nil || redone.Files[renamed.Entry].Text != "Edited.\n" {
		t.Fatal(redone, err)
	}
	s.Save()
	s.Close()
	reopened, err := s.Open(p.Root)
	if err != nil || reopened.Entry != renamed.Entry {
		t.Fatal(reopened, err)
	}
}
func TestRenameRejectsCollisionsAndPaths(t *testing.T) {
	s, p := fixture(t, "Keep source.")
	os.WriteFile(filepath.Join(p.Root, "Existing.typ"), []byte("Keep target."), 0600)
	for _, name := range []string{"Existing.typ", "../escape.typ", "", "folder/name.typ"} {
		if _, err := s.RenameEntry(p.ID, name); err == nil {
			t.Fatal("accepted", name)
		}
	}
	original, _ := os.ReadFile(filepath.Join(p.Root, "main.typ"))
	target, _ := os.ReadFile(filepath.Join(p.Root, "Existing.typ"))
	if string(original) != "Keep source." || string(target) != "Keep target." {
		t.Fatal("overwrote content")
	}
}
