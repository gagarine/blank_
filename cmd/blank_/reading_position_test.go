package main

import (
	"os"
	"path/filepath"
	"testing"
	"unicode/utf8"

	"writer/internal/document"
)

func TestPreviewReadingMapIncludesChaptersAndRetainsLastSuccessfulMap(t *testing.T) {
	a := testApp(t, "= First\n\nOpening café.\n#pagebreak()\n#include \"chapter.typ\"\n")
	root := a.docs.Snapshot().Root
	chapter := "= Second\n\nRésumé 日本語.\n#pagebreak()\n= Third\n\nThe last passage.\n"
	if err := os.WriteFile(filepath.Join(root, "chapter.typ"), []byte(chapter), 0600); err != nil {
		t.Fatal(err)
	}
	p, err := a.open(root)
	if err != nil {
		t.Fatal(err)
	}
	result, err := a.compile()
	if err != nil || result["pdf"] == nil {
		t.Fatal(result, err)
	}
	anchors := result["sourceMap"].([]any)
	seen := map[int]string{}
	for _, raw := range anchors {
		anchor := raw.(map[string]any)
		path := anchor["path"].(string)
		start, end := int(anchor["start"].(float64)), int(anchor["end"].(float64))
		text := p.Files[path].Text
		if start < 0 || end < start || end > len(text) || !utf8.ValidString(text[:start]) || !utf8.ValidString(text[:end]) {
			t.Fatalf("invalid UTF-8 source range: %+v", anchor)
		}
		seen[int(anchor["page"].(float64))] = path
		y := anchor["y"].(float64)
		if y < 0 || y > 1 {
			t.Fatalf("invalid page position: %+v", anchor)
		}
	}
	if seen[1] != "main.typ" || seen[2] != "chapter.typ" || seen[3] != "chapter.typ" {
		t.Fatalf("wrong chapter/page mapping: %+v", seen)
	}
	if len(result["pageRatios"].([]any)) != 3 {
		t.Fatal("missing page geometry")
	}
	_, err = a.docs.Apply(document.Transaction{ProjectID: p.ID, Expected: map[string]uint64{p.Entry: 1}, Edits: []document.Edit{{Path: p.Entry, Start: 0, End: 0, Text: "#missing-function()\n"}}, Origin: "user"})
	if err != nil {
		t.Fatal(err)
	}
	failed, err := a.compile()
	if err != nil || failed["pdf"] != nil || failed["previousPdf"] == nil || len(failed["sourceMap"].([]any)) != len(anchors) {
		t.Fatal("failed compilation lost the displayed PDF's map", err)
	}
}
