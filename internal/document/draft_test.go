package document

import (
	"os"
	"path/filepath"
	"testing"
)

func draftFixture(t *testing.T) (*Service, Snapshot) {
	s, p := fixture(t, "Original guide.\n")
	if err := os.WriteFile(filepath.Join(p.Root, ".blank-draft"), []byte("unsaved"), 0600); err != nil {
		t.Fatal(err)
	}
	s.Close()
	p, err := s.Open(p.Root)
	if err != nil || !p.Unsaved {
		t.Fatal(p, err)
	}
	return s, p
}
func TestSaveDraftRetainsEditsAssetsAndUndo(t *testing.T) {
	s, p := draftFixture(t)
	os.MkdirAll(filepath.Join(p.Root, "assets"), 0700)
	os.WriteFile(filepath.Join(p.Root, "assets/figure.svg"), []byte("<svg/>"), 0600)
	edited, err := s.Apply(tx(p, p.Entry, 0, 8, "Edited", "user"))
	if err != nil {
		t.Fatal(err)
	}
	s.SetSelection(Selection{Path: p.Entry, Start: 2, End: 2, Revision: edited.Files[p.Entry].Revision})
	destination := filepath.Join(t.TempDir(), "My guide.typ")
	saved, err := s.SaveDraftAs(destination)
	if err != nil {
		t.Fatal(err)
	}
	if saved.Unsaved || saved.ID == p.ID || saved.Entry != "My guide.typ" || saved.AgentEnabled {
		t.Fatal(saved)
	}
	data, err := os.ReadFile(destination)
	if err != nil || string(data) != "Edited guide.\n" {
		t.Fatal(string(data), err)
	}
	image, err := os.ReadFile(filepath.Join(saved.Root, "assets/figure.svg"))
	if err != nil || string(image) != "<svg/>" {
		t.Fatal(string(image), err)
	}
	if s.Selection().Path != saved.Entry {
		t.Fatal("selection path did not follow saved file")
	}
	undone, err := s.Undo("")
	if err != nil || undone.Files[saved.Entry].Text != "Original guide.\n" {
		t.Fatal(undone, err)
	}
	redone, err := s.Redo()
	if err != nil || redone.Files[saved.Entry].Text != "Edited guide.\n" {
		t.Fatal(redone, err)
	}
	if _, err := os.Stat(filepath.Join(saved.Root, ".blank-draft")); !os.IsNotExist(err) {
		t.Fatal("saved copy retained draft marker")
	}
}
func TestDraftSavePreflightsEveryCollision(t *testing.T) {
	for _, conflict := range []string{"Saved.typ", "assets/figure.svg"} {
		t.Run(conflict, func(t *testing.T) {
			s, p := draftFixture(t)
			os.MkdirAll(filepath.Join(p.Root, "assets"), 0700)
			os.WriteFile(filepath.Join(p.Root, "assets/figure.svg"), []byte("new image"), 0600)
			destination := t.TempDir()
			os.MkdirAll(filepath.Dir(filepath.Join(destination, conflict)), 0700)
			os.WriteFile(filepath.Join(destination, conflict), []byte("existing user data"), 0600)
			if _, err := s.SaveDraftAs(filepath.Join(destination, "Saved.typ")); err == nil {
				t.Fatal("overwrote existing data")
			}
			data, _ := os.ReadFile(filepath.Join(destination, conflict))
			if string(data) != "existing user data" || !s.Snapshot().Unsaved {
				t.Fatal("existing data or draft lost")
			}
			if conflict != "Saved.typ" {
				if _, err := os.Stat(filepath.Join(destination, "Saved.typ")); !os.IsNotExist(err) {
					t.Fatal("partial save before collision check")
				}
			}
		})
	}
}
