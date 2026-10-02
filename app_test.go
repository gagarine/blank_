package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"writer/internal/document"
	"writer/internal/engine"
	"writer/internal/zotero"
)

func testApp(t *testing.T, text string) *App {
	t.Helper()
	root := t.TempDir()
	if e := os.WriteFile(filepath.Join(root, "main.typ"), []byte(text), 0600); e != nil {
		t.Fatal(e)
	}
	t.Setenv("WRITER_DATA_DIR", t.TempDir())
	a := NewApp("")
	a.helper = engine.New(filepath.Join(mustCwd(t), "helper/target/release/writer-helper"))
	if _, e := a.docs.Open(root); e != nil {
		t.Fatal(e)
	}
	t.Cleanup(func() { a.docs.Close(); a.helper.Close() })
	return a
}
func mustCwd(t *testing.T) string {
	s, e := os.Getwd()
	if e != nil {
		t.Fatal(e)
	}
	return s
}
func dispatchTest(t *testing.T, a *App, method string, args any, agent bool) (any, error) {
	t.Helper()
	raw, _ := json.Marshal(args)
	return a.dispatch(method, raw, agent)
}
func TestAgentContract(t *testing.T) {
	a := testApp(t, "Hello world")
	if _, e := dispatchTest(t, a, "project.read", map[string]any{}, true); e == nil {
		t.Fatal("access should be disabled")
	}
	a.docs.SetAgent(true)
	p := a.docs.Snapshot()
	tx := document.Transaction{ProjectID: p.ID, Expected: map[string]uint64{"main.typ": 1}, Edits: []document.Edit{{Path: "main.typ", Start: 0, End: 5, Text: "Welcome"}}, Origin: "spoofed"}
	if _, e := dispatchTest(t, a, "document.applyEdits", tx, true); e != nil {
		t.Fatal(e)
	}
	if a.docs.Snapshot().LastOrigin != "agent" {
		t.Fatal("origin")
	}
	if _, e := dispatchTest(t, a, "document.applyEdits", tx, true); e == nil {
		t.Fatal("stale accepted")
	}
	if _, e := dispatchTest(t, a, "project.open", map[string]string{"path": t.TempDir()}, true); e == nil {
		t.Fatal("agent project boundary")
	}
	p = a.docs.Snapshot()
	a.docs.SetSelection(document.Selection{Path: "main.typ", Start: 1, End: 3, Revision: p.Files["main.typ"].Revision})
	v, e := dispatchTest(t, a, "context.selection", map[string]any{}, true)
	if e != nil || v.(document.Selection).Start != 1 {
		t.Fatal(v, e)
	}
	if _, e := dispatchTest(t, a, "preview.exportPDF", map[string]string{"path": "main.typ"}, true); e == nil {
		t.Fatal("non-PDF export")
	}
	if _, e := dispatchTest(t, a, "preview.exportPDF", map[string]string{"path": "../outside.pdf"}, true); e == nil {
		t.Fatal("escape export")
	}
}
func TestCompileSnapshotFailureAndRestart(t *testing.T) {
	if _, e := os.Stat("helper/target/release/writer-helper"); e != nil {
		t.Skip("build the helper first")
	}
	a := testApp(t, "= Disk title\n\nOriginal.\n")
	p := a.docs.Snapshot()
	a.docs.Apply(document.Transaction{ProjectID: p.ID, Expected: map[string]uint64{"main.typ": 1}, Edits: []document.Edit{{Path: "main.typ", End: len(p.Files["main.typ"].Text), Text: "= Unsaved title\n\nWorking draft.\n"}}, Origin: "user"})
	good, e := a.compile()
	if e != nil || good["pdf"] == nil {
		t.Fatal(good, e)
	}
	if good["revision"] != float64(a.docs.Snapshot().Revision) {
		t.Fatal("revision")
	}
	if good["projectId"] != a.docs.Snapshot().ID {
		t.Fatal("preview is missing its project identity")
	}
	p = a.docs.Snapshot()
	a.docs.Apply(document.Transaction{ProjectID: p.ID, Expected: map[string]uint64{"main.typ": p.Files["main.typ"].Revision}, Edits: []document.Edit{{Path: "main.typ", Start: 0, End: 0, Text: "#nonexistent-function()\n"}}})
	bad, e := a.compile()
	if e != nil || bad["pdf"] != nil || bad["previousPdf"] != good["pdf"] {
		t.Fatal("last good preview not preserved", e)
	}
	if _, e = dispatchTest(t, a, "preview.exportPDF", map[string]string{"path": filepath.Join(p.Root, "bad.pdf")}, false); e == nil {
		t.Fatal("exported failing revision")
	}
	if _, e = os.Stat(filepath.Join(p.Root, "bad.pdf")); !os.IsNotExist(e) {
		t.Fatal("failed export touched file")
	}
	a.docs.Undo("")
	a.helper.Close()
	// A replacement helper reuses authoritative buffers, never a separate document session.
	a.helper = engine.New(filepath.Join(mustCwd(t), "helper/target/release/writer-helper"))
	recovered, e := a.compile()
	if e != nil || recovered["pdf"] == nil {
		t.Fatal("restart", e)
	}
	exportRevision := a.docs.Snapshot().Revision
	result, e := dispatchTest(t, a, "preview.exportPDF", map[string]string{"path": filepath.Join(p.Root, "good.pdf")}, false)
	if e != nil {
		t.Fatal(e)
	}
	if result.(map[string]any)["revision"] != exportRevision {
		t.Fatal("export revision")
	}
}
func TestCitationTransactionOfflineAndStableKeys(t *testing.T) {
	a := testApp(t, "A citation: ")
	title := "First title"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasPrefix(r.URL.Path, "/api/groups/42/items/ABCDEFGH") {
			t.Error(r.URL.Path)
		}
		w.Write([]byte("@article{temporary,\n title={" + title + "},\n author={Example, Ada},\n date={2025},\n}\n"))
	}))
	a.zotero = &zotero.Client{Base: srv.URL + "/api", HTTP: srv.Client()}
	p := a.docs.Snapshot()
	request := citationRequest{ProjectID: p.ID, Path: "main.typ", Start: 12, End: 12, Revision: 1, Items: []zotero.Result{{Library: "groups/42", Key: "ABCDEFGH", Title: title}}, Locator: "p. 4", Form: "prose"}
	got, e := a.insertCitation(request)
	if e != nil {
		t.Fatal(e)
	}
	key := "zotero-groups-42-ABCDEFGH"
	if !strings.Contains(got.Files["main.typ"].Text, key) || !strings.Contains(got.Files["writer-zotero.bib"].Text, key) {
		t.Fatal("citation metadata missing")
	}
	title = "Changed title"
	refreshed, e := a.refreshCitations()
	if e != nil {
		t.Fatal(e)
	}
	if !strings.Contains(refreshed.Files["writer-zotero.bib"].Text, title) || !strings.Contains(refreshed.Files["writer-zotero.bib"].Text, key) {
		t.Fatal("refresh key changed")
	}
	srv.Close()
	before := a.docs.Snapshot()
	if _, e = a.refreshCitations(); e == nil || !strings.Contains(e.Error(), "Allow other applications on this computer to communicate with Zotero") {
		t.Fatal("outage setup guidance missing", e)
	}
	if a.docs.Snapshot().Files["writer-zotero.bib"].Text != before.Files["writer-zotero.bib"].Text {
		t.Fatal("metadata lost on outage")
	}
	request.Revision = before.Files["main.typ"].Revision
	if _, e = a.insertCitation(request); e == nil || !strings.Contains(e.Error(), "Settings → Advanced") {
		t.Fatal("insertion outage setup guidance missing", e)
	}
	if a.docs.Snapshot().Revision != before.Revision {
		t.Fatal("failed Zotero actions changed the document")
	}
	if _, e = a.docs.Apply(document.Transaction{ProjectID: before.ID, Expected: map[string]uint64{"main.typ": before.Files["main.typ"].Revision}, Edits: []document.Edit{{Path: "main.typ", Start: 0, End: 0, Text: "Still writing.\n"}}, Origin: "user"}); e != nil {
		t.Fatal("editing while Zotero is unavailable", e)
	}
	if _, e = os.Stat("helper/target/release/writer-helper"); e == nil {
		result, e := a.compile()
		if e != nil || result["pdf"] == nil {
			t.Fatal("offline compile", result, e)
		}
	}
}
func TestMCPUnavailableAndSchemas(t *testing.T) {
	t.Setenv("WRITER_SOCKET", filepath.Join(t.TempDir(), "missing.sock"))
	if _, e := callSocket("project.read", json.RawMessage(`{}`)); e == nil || !strings.Contains(e.Error(), "app_unavailable") {
		t.Fatal(e)
	}
	for _, tool := range toolList() {
		if required, exists := tool.InputSchema["required"]; exists && required == nil {
			t.Fatal("invalid null required")
		}
	}
}
