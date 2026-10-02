package main

import (
	"os"
	"path/filepath"
	"testing"
	"writer/internal/document"
)

func TestNewDocumentStartsUnsavedAndFirstSaveRetainsWriting(t *testing.T) {
	a := testApp(t, "Existing document.\n")
	existing := a.docs.Snapshot()
	value, err := dispatchTest(t, a, "document.new", nil, false)
	if err != nil {
		t.Fatal(err)
	}
	draft := value.(document.Snapshot)
	if !draft.Unsaved || draft.Entry != "Untitled.typ" || draft.Files[draft.Entry].Text != "\n" {
		t.Fatalf("New Document must start blank and unsaved: %+v", draft)
	}
	_, err = a.docs.Apply(document.Transaction{ProjectID: draft.ID, Expected: map[string]uint64{draft.Entry: 1}, Edits: []document.Edit{{Path: draft.Entry, Start: 0, End: 1, Text: "Writing before choosing a filename.\n"}}, Origin: "user"})
	if err != nil {
		t.Fatal(err)
	}
	// Background saving retains a recovery copy without naming the document.
	if saved, err := a.docs.Save(); err != nil || !saved.Unsaved {
		t.Fatal("autosave must not promote the draft", err)
	}
	value, err = dispatchTest(t, a, "document.new", nil, false)
	if err != nil {
		t.Fatal(err)
	}
	second := value.(document.Snapshot)
	if second.ID == draft.ID || second.Root == draft.Root || second.Files[second.Entry].Text != "\n" {
		t.Fatal("new drafts must be independent")
	}
	if _, err := a.open(draft.Root); err != nil {
		t.Fatal(err)
	}
	destination := filepath.Join(t.TempDir(), "My paper.typ")
	value, err = dispatchTest(t, a, "document.save", map[string]string{"path": destination}, false)
	if err != nil || value.(document.Snapshot).Unsaved {
		t.Fatal("first explicit save failed", value, err)
	}
	data, err := os.ReadFile(destination)
	if err != nil || string(data) != "Writing before choosing a filename.\n" {
		t.Fatal("first save lost writing", string(data), err)
	}
	data, err = os.ReadFile(filepath.Join(existing.Root, existing.Entry))
	if err != nil || string(data) != "Existing document.\n" {
		t.Fatal("New Document changed the previous document", err)
	}
}

func TestTutorialCopiesAreIndependentAndCompileOffline(t *testing.T) {
	a := testApp(t, "Existing document.\n")
	first, err := a.openDemo()
	if err != nil || !first.Unsaved || first.Entry != "Tutorial.typ" || first.Files[first.Entry].Text != tutorialSource {
		t.Fatal(first, err)
	}
	changed := "// My own notes\n" + tutorialSource
	_, err = a.docs.Apply(document.Transaction{ProjectID: first.ID, Expected: map[string]uint64{first.Entry: 1}, Edits: []document.Edit{{Path: first.Entry, Start: 0, End: len(tutorialSource), Text: changed}}, Origin: "user"})
	if err != nil {
		t.Fatal(err)
	}
	second, err := a.openDemo()
	if err != nil || second.ID == first.ID || second.Root == first.Root || second.Files[second.Entry].Text != tutorialSource {
		t.Fatal(second, err)
	}
	old, err := os.ReadFile(filepath.Join(first.Root, first.Entry))
	if err != nil || string(old) != changed {
		t.Fatal("previous copy was not retained", err)
	}
	result, err := a.compile()
	if err != nil || result["pdf"] == nil {
		t.Fatal(result, err)
	}
	t.Logf("Tutorial preview: %v pages", result["pages"])
	if _, err := dispatchTest(t, a, "document.save", map[string]string{}, false); err == nil {
		t.Fatal("unsaved document bypassed save destination")
	}
	destination := filepath.Join(t.TempDir(), "Tutorial.typ")
	value, err := dispatchTest(t, a, "document.save", map[string]string{"path": destination}, false)
	if err != nil || value.(document.Snapshot).Unsaved {
		t.Fatal(value, err)
	}
	packaged, _ := os.ReadFile("examples/Tutorial.typ")
	if string(packaged) != tutorialSource {
		t.Fatal("packaged source changed")
	}
}
