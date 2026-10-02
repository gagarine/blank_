package main

import (
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"writer/internal/document"
)

func TestImportFiguresPreservesOriginals(t *testing.T) {
	a := testApp(t, "A figure.\n")
	svg := []byte(`<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"><rect width="100" height="100" fill="green"/></svg>`)
	first, e := a.importAsset("research.svg", svg)
	if e != nil {
		t.Fatal(e)
	}
	same, e := a.importAsset("research.svg", svg)
	if e != nil || same != first {
		t.Fatal("identical import duplicated")
	}
	second, e := a.importAsset("research.svg", []byte(strings.ReplaceAll(string(svg), "green", "blue")))
	if e != nil || second == first {
		t.Fatal("collision overwrote original")
	}
	original, e := os.ReadFile(filepath.Join(a.docs.Snapshot().Root, first))
	if e != nil || string(original) != string(svg) {
		t.Fatal("original lost")
	}
	if _, e = a.importAsset("code.typ", svg); e == nil {
		t.Fatal("non-image allowed")
	}
	if _, e = a.importAsset("fake.png", svg); e == nil {
		t.Fatal("invalid PNG allowed")
	}
	if _, e = a.readAsset("../outside.svg"); e == nil {
		t.Fatal("path escape")
	}
	p := a.docs.Snapshot()
	_, e = a.docs.Apply(document.Transaction{ProjectID: p.ID, Expected: map[string]uint64{"main.typ": 1}, Edits: []document.Edit{{Path: "main.typ", End: len(p.Files["main.typ"].Text), Text: `#figure(image("assets/research.svg", width: 85%, alt: "Green square"), caption: [A square])`}}})
	if e != nil {
		t.Fatal(e)
	}
	if _, e = os.Stat(filepath.Join(repositoryRoot(t), "helper/target/release/writer-helper")); e == nil {
		out, e := a.compile()
		if e != nil || out["pdf"] == nil {
			t.Fatal("image compile", out, e)
		}
		pdf, _ := base64.StdEncoding.DecodeString(out["pdf"].(string))
		path, e := a.importAsset("figure.pdf", pdf)
		if e != nil {
			t.Fatal(e)
		}
		p = a.docs.Snapshot()
		a.docs.Apply(document.Transaction{ProjectID: p.ID, Expected: map[string]uint64{"main.typ": p.Files["main.typ"].Revision}, Edits: []document.Edit{{Path: "main.typ", End: len(p.Files["main.typ"].Text), Text: `#figure(image("` + path + `",page:1),caption:[PDF figure])`}}})
		out, e = a.compile()
		if e != nil || out["pdf"] == nil {
			t.Fatal("PDF figure compile", out, e)
		}
	}
}
func TestNewTemplatesCompile(t *testing.T) {
	if _, e := os.Stat(filepath.Join(repositoryRoot(t), "helper/target/release/writer-helper")); e != nil {
		t.Skip("build helper")
	}
	for _, kind := range []string{"article", "thesis"} {
		t.Run(kind, func(t *testing.T) {
			a := testApp(t, "ignored")
			if _, e := a.newProject(t.TempDir(), kind); e != nil {
				t.Fatal(e)
			}
			out, e := a.compile()
			if e != nil || out["pdf"] == nil {
				t.Fatal(out, e)
			}
		})
	}
}
