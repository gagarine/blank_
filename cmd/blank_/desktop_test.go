package main

import (
	"context"
	"encoding/json"
	"testing"

	"writer/internal/document"
)

func TestDocumentWindowsKeepIndependentSessions(t *testing.T) {
	first := testApp(t, "First document.")
	second := testApp(t, "Second document.")
	d := &Desktop{sessions: map[uint]*App{11: first, 22: second}}
	call := func(id uint, method string, params any) (string, error) {
		raw, _ := json.Marshal(params)
		return d.callWindow(id, method, string(raw))
	}
	firstSnapshot := first.docs.Snapshot()
	tx := document.Transaction{ProjectID: firstSnapshot.ID, Expected: map[string]uint64{"main.typ": 1}, Edits: []document.Edit{{Path: "main.typ", Start: 0, End: 5, Text: "Changed"}}, Origin: "user"}
	if _, err := call(11, "document.applyEdits", tx); err != nil {
		t.Fatal(err)
	}
	if second.docs.Snapshot().Files["main.typ"].Text != "Second document." {
		t.Fatal("edit leaked into other window")
	}
	if _, err := call(22, "document.applyEdits", tx); err == nil {
		t.Fatal("accepted another window's transaction")
	}
	if _, err := call(11, "document.undo", map[string]any{}); err != nil {
		t.Fatal(err)
	}
	if first.docs.Snapshot().Files["main.typ"].Text != "First document." {
		t.Fatal("undo used the wrong history")
	}
	// Closing one window must reject old calls and leave the other session usable.
	d.closeWindow(11)
	if _, err := call(11, "project.read", map[string]any{}); err == nil {
		t.Fatal("closed window still addressable")
	}
	if _, err := first.Call("project.read", "{}"); err == nil {
		t.Fatal("closed session still accepts in-flight calls")
	}
	result, err := call(22, "project.read", map[string]any{})
	if err != nil {
		t.Fatal(err)
	}
	var actual document.Snapshot
	if err := json.Unmarshal([]byte(result), &actual); err != nil {
		t.Fatal(err)
	}
	if actual.Files["main.typ"].Text != "Second document." {
		t.Fatal("surviving window lost its document")
	}
	if _, err := d.Call(context.Background(), "project.read", "{}"); err == nil {
		t.Fatal("bound call did not require a native window context")
	}
}
