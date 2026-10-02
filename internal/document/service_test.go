package document

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func fixture(t *testing.T, text string) (*Service, Snapshot) {
	t.Helper()
	root := t.TempDir()
	os.WriteFile(filepath.Join(root, "main.typ"), []byte(text), 0600)
	s := New(t.TempDir(), nil, nil)
	p, e := s.Open(root)
	if e != nil {
		t.Fatal(e)
	}
	t.Cleanup(s.Close)
	return s, p
}
func tx(p Snapshot, path string, start, end int, text, origin string) Transaction {
	return Transaction{ProjectID: p.ID, Expected: map[string]uint64{path: p.Files[path].Revision}, Edits: []Edit{{path, start, end, text}}, Origin: origin}
}
func TestNoOpPreservesBytes(t *testing.T) {
	input := "// a comment\r\n#let custom(x) = [#x]\r\n\r\n= Héllo\r\n\r\n*bold* \\#literal $ α + β $\n"
	s, p := fixture(t, input)
	_, e := s.Apply(tx(p, "main.typ", 0, 0, "", "user"))
	if e != nil {
		t.Fatal(e)
	}
	s.Save()
	data, _ := os.ReadFile(filepath.Join(p.Root, "main.typ"))
	if string(data) != input {
		t.Fatal("source changed without an edit")
	}
}
func TestRevisionAndUTF8Validation(t *testing.T) {
	s, p := fixture(t, "aé😀z")
	if _, e := s.Apply(tx(p, "main.typ", 2, 2, "!", "agent")); e == nil {
		t.Fatal("accepted split UTF8")
	}
	p2, e := s.Apply(tx(p, "main.typ", 3, 7, "🌱", "agent"))
	if e != nil {
		t.Fatal(e)
	}
	if p2.Files["main.typ"].Text != "aé🌱z" {
		t.Fatal(p2)
	}
	if _, e = s.Apply(tx(p, "main.typ", 0, 1, "b", "agent")); e == nil {
		t.Fatal("accepted stale edit")
	}
}
func TestTransactionIsAtomic(t *testing.T) {
	s, p := fixture(t, "hello")
	transaction := tx(p, "main.typ", 0, 1, "H", "agent")
	transaction.Edits = append(transaction.Edits, Edit{"another.typ", 0, 99, "invalid"})
	transaction.Expected["another.typ"] = 0
	if _, e := s.Apply(transaction); e == nil {
		t.Fatal("accepted invalid transaction")
	}
	if s.Snapshot().Files["main.typ"].Text != "hello" {
		t.Fatal("partial transaction applied")
	}
}
func TestExternalMergeAndUndo(t *testing.T) {
	s, p := fixture(t, "alpha beta gamma")
	p, e := s.Apply(tx(p, "main.typ", 0, 5, "ALPHA", "agent"))
	if e != nil {
		t.Fatal(e)
	}
	os.WriteFile(filepath.Join(p.Root, "main.typ"), []byte("alpha beta GAMMA"), 0600)
	p = s.Rescan()
	if p.Files["main.typ"].Text != "ALPHA beta GAMMA" {
		t.Fatal(p.Files["main.typ"])
	}
	p, e = s.Undo("agent")
	if e != nil {
		t.Fatal(e)
	}
	if p.Files["main.typ"].Text != "alpha beta GAMMA" {
		t.Fatal("undo discarded external edit")
	}
}
func TestOverlappingExternalEditPreserved(t *testing.T) {
	s, p := fixture(t, "hello world")
	s.Apply(tx(p, "main.typ", 0, 5, "local", "user"))
	os.WriteFile(filepath.Join(p.Root, "main.typ"), []byte("remote world"), 0600)
	p = s.Rescan()
	if p.Files["main.typ"].Conflict == nil {
		t.Fatal("missing conflict")
	}
	s.Save()
	data, _ := os.ReadFile(filepath.Join(p.Root, "main.typ"))
	if string(data) != "remote world" {
		t.Fatal("overwrote conflicting disk version")
	}
	p, e := s.Resolve("main.typ", "merged world")
	if e != nil {
		t.Fatal(e)
	}
	if p.Files["main.typ"].Conflict != nil {
		t.Fatal("conflict not resolved")
	}
}
func TestAgentUndoPreservesLaterUserChanges(t *testing.T) {
	s, p := fixture(t, "one two three")
	p, _ = s.Apply(tx(p, "main.typ", 0, 3, "ONE", "agent"))
	p, _ = s.Apply(tx(p, "main.typ", 8, 13, "THREE", "user"))
	p, e := s.Undo("agent")
	if e != nil {
		t.Fatal(e)
	}
	if p.Files["main.typ"].Text != "one two THREE" {
		t.Fatal(p.Files["main.typ"])
	}
	p, e = s.Redo()
	if e != nil || p.Files["main.typ"].Text != "ONE two THREE" {
		t.Fatal(p, e)
	}
}
func TestOverlappingUndoRejected(t *testing.T) {
	s, p := fixture(t, "one two")
	p, _ = s.Apply(tx(p, "main.typ", 0, 3, "ONE", "agent"))
	p, _ = s.Apply(tx(p, "main.typ", 0, 3, "Uno", "user"))
	if _, e := s.Undo("agent"); e == nil {
		t.Fatal("undo overwrote later user change")
	}
}
func TestRecoveryMergesDiskChanges(t *testing.T) {
	s, p := fixture(t, "one two")
	s.Apply(tx(p, "main.typ", 0, 3, "ONE", "user"))
	s.Close()
	os.WriteFile(filepath.Join(p.Root, "main.typ"), []byte("one TWO"), 0600)
	second := New(s.journal, nil, nil)
	defer second.Close()
	p, e := second.Open(p.Root)
	if e != nil {
		t.Fatal(e)
	}
	if p.Files["main.typ"].Text != "ONE TWO" {
		t.Fatal(p.Files["main.typ"])
	}
}
func TestPathEscape(t *testing.T) {
	s, p := fixture(t, "safe")
	external := t.TempDir()
	os.Symlink(external, filepath.Join(p.Root, "escape"))
	for _, path := range []string{"../secret.typ", "/etc/passwd", "escape/secret.typ"} {
		transaction := tx(p, "main.typ", 0, 0, "x", "agent")
		transaction.Edits[0].Path = path
		transaction.Expected[path] = 0
		if _, e := s.Apply(transaction); e == nil {
			t.Fatal("accepted ", path)
		}
	}
}
func TestAtomicReplacementReload(t *testing.T) {
	s, p := fixture(t, "old")
	AtomicWrite(filepath.Join(p.Root, "main.typ"), []byte("new"))
	p = s.Rescan()
	if p.Files["main.typ"].Text != "new" || p.Files["main.typ"].Dirty {
		t.Fatal(p.Files["main.typ"])
	}
}
func TestDeletionDoesNotDiscardBuffer(t *testing.T) {
	s, p := fixture(t, "important")
	os.Remove(filepath.Join(p.Root, "main.typ"))
	p = s.Rescan()
	if p.Files["main.typ"].Text != "important" || p.Files["main.typ"].Conflict == nil || !p.Files["main.typ"].Conflict.Deleted {
		t.Fatal(p.Files["main.typ"])
	}
}
func TestMergeMultipleChanges(t *testing.T) {
	cases := []struct {
		base, local, remote, want string
		ok                        bool
	}{{"a b c d", "A b C d", "a B c D", "A B C D", true}, {"abc", "aXbc", "aYbc", "", false}, {"abc", "Abc", "aBc", "ABc", true}, {"aé😀z", "Aé😀z", "aé🌱z", "Aé🌱z", true}}
	for _, c := range cases {
		got, ok := Merge(c.base, c.local, c.remote)
		if ok != c.ok || (ok && got != c.want) {
			t.Fatalf("%+v => %q %v", c, got, ok)
		}
	}
}
func BenchmarkThesisEdit(b *testing.B) {
	text := strings.Repeat("A carefully considered sentence about research. ", 25000)
	for i := 0; i < b.N; i++ {
		_, ok := Merge(text, "X"+text, text+"Y")
		if !ok {
			b.Fatal("merge")
		}
	}
}

func TestDependencyAndNewChapterDiscovery(t *testing.T) {
	root := t.TempDir()
	os.WriteFile(filepath.Join(root, "main.typ"), []byte("Hello"), 0600)
	s := New(t.TempDir(), nil, nil)
	defer s.Close()
	p, e := s.Open(root)
	if e != nil {
		t.Fatal(e)
	}
	os.MkdirAll(filepath.Join(root, "chapters"), 0700)
	os.WriteFile(filepath.Join(root, "chapters", "new.typ"), []byte("= New"), 0600)
	os.WriteFile(filepath.Join(root, "image.svg"), []byte("<svg/>"), 0600)
	got := s.Rescan()
	if got.Revision <= p.Revision || got.Files["chapters/new.typ"].Text != "= New" {
		t.Fatal("not discovered", got.Revision)
	}
	rev := got.Revision
	os.WriteFile(filepath.Join(root, "image.svg"), []byte("<svg>changed</svg>"), 0600)
	got = s.Rescan()
	if got.Revision <= rev {
		t.Fatal("asset failed to invalidate preview")
	}
}

func TestNewBufferDoesNotOverwriteUnloadedExistingFile(t *testing.T) {
	root := t.TempDir()
	os.WriteFile(filepath.Join(root, "main.typ"), []byte("Hello"), 0600)
	os.WriteFile(filepath.Join(root, "private.json"), []byte(`{"keep":true}`), 0600)
	s := New(t.TempDir(), nil, nil)
	defer s.Close()
	p, e := s.Open(root)
	if e != nil {
		t.Fatal(e)
	}
	_, e = s.Apply(Transaction{ProjectID: p.ID, Expected: map[string]uint64{"private.json": 0}, Edits: []Edit{{Path: "private.json", Text: "replacement"}}})
	if e == nil {
		t.Fatal("unloaded file mistaken for new buffer")
	}
	data, _ := os.ReadFile(filepath.Join(root, "private.json"))
	if string(data) != `{"keep":true}` {
		t.Fatal("existing file changed")
	}
}

func TestReopenKeepsDirtySessionAndEntrypointsHaveDistinctIdentities(t *testing.T) {
	root := t.TempDir()
	os.WriteFile(filepath.Join(root, "main.typ"), []byte("Main"), 0600)
	os.WriteFile(filepath.Join(root, "other.typ"), []byte("Other"), 0600)
	s := New(t.TempDir(), nil, nil)
	defer s.Close()
	p, e := s.Open(root)
	if e != nil {
		t.Fatal(e)
	}
	p, e = s.Apply(Transaction{ProjectID: p.ID, Expected: map[string]uint64{"main.typ": 1}, Edits: []Edit{{Path: "main.typ", End: 4, Text: "Unsaved"}}})
	if e != nil {
		t.Fatal(e)
	}
	again, e := s.Open(root)
	if e != nil || again.Files["main.typ"].Text != "Unsaved" || again.Revision != p.Revision {
		t.Fatal("reopen reset active session", again, e)
	}
	different, e := s.Open(filepath.Join(root, "other.typ"))
	if e != nil || different.ID == p.ID {
		t.Fatal("entrypoints share ambiguous identity", e)
	}
}
