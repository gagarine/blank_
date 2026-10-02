package document

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestInformationReportsDiskDatesAndUnsavedText(t *testing.T) {
	s, p := fixture(t, "Hello\n")
	path := filepath.Join(p.Root, "main.typ")
	past := time.Date(2024, 1, 2, 3, 4, 5, 0, time.UTC)
	if err := os.Chtimes(path, past, past); err != nil {
		t.Fatal(err)
	}
	before, err := s.Information()
	if err != nil {
		t.Fatal(err)
	}
	info := before.Files["main.typ"]
	if before.ProjectID != p.ID || before.Revision != p.Revision || info.Dirty || info.Missing || info.LastSaved == nil || !info.LastSaved.Equal(past) {
		t.Fatalf("incorrect initial metadata: %+v", before)
	}
	_, err = s.Apply(tx(p, "main.typ", 0, 5, "Héllo 😀", "user"))
	if err != nil {
		t.Fatal(err)
	}
	dirty, err := s.Information()
	if err != nil {
		t.Fatal(err)
	}
	if got := dirty.Files["main.typ"]; !got.Dirty || got.Bytes != len("Héllo 😀\n") || !got.LastSaved.Equal(past) {
		t.Fatalf("unsaved data changed disk metadata: %+v", got)
	}
	if _, err := s.Save(); err != nil {
		t.Fatal(err)
	}
	after, err := s.Information()
	if err != nil {
		t.Fatal(err)
	}
	got := after.Files["main.typ"]
	if got.Dirty || !got.LastSaved.After(past) {
		t.Fatalf("save metadata: %+v", got)
	}
	if info.Created != nil && (got.Created == nil || !got.Created.Equal(*info.Created)) {
		t.Fatalf("atomic save changed creation date: %v -> %v", info.Created, got.Created)
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	missing, err := s.Information()
	if err != nil {
		t.Fatal(err)
	}
	if got := missing.Files["main.typ"]; !got.Missing || got.Created != nil || got.LastSaved != nil {
		t.Fatalf("missing file metadata: %+v", got)
	}
}
