package zotero

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestSearchAndExport(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.Contains(r.URL.RawQuery, "biblatex") {
			w.Write([]byte("@article{oldkey,\n title={A {nested} title}\n}"))
			return
		}
		w.Write([]byte(`[{"key":"ABCD1234","version":2,"data":{"itemType":"journalArticle","title":"Research","date":"2026-03","creators":[{"lastName":"Smith"}]}}]`))
	}))
	defer server.Close()
	c := New()
	c.Base = server.URL
	items, e := c.Search(context.Background(), "personal", "Research")
	if e != nil || len(items) != 1 {
		t.Fatal(items, e)
	}
	if items[0].CiteKey != "zotero-users-0-ABCD1234" {
		t.Fatal(items)
	}
	bib, e := c.Bib(context.Background(), "personal", "ABCD1234", items[0].CiteKey)
	if e != nil || !strings.Contains(bib, items[0].CiteKey) {
		t.Fatal(bib, e)
	}
}
func TestUpsertPreservesOtherEntries(t *testing.T) {
	input := "% my comment\n@book{other, title={Untouched}}\n@article{target, title={Old {nested} title}}\n% tail\n"
	got, e := Upsert(input, "target", "@article{target, title={New}}\n")
	if e != nil {
		t.Fatal(e)
	}
	want := "% my comment\n@book{other, title={Untouched}}\n@article{target, title={New}}\n% tail\n"
	if got != want {
		t.Fatalf("%q", got)
	}
}
func TestRejectInvalidLibraryAndKeys(t *testing.T) {
	c := New()
	if _, e := c.Search(context.Background(), "../secrets", ""); e == nil {
		t.Fatal("accepted traversal")
	}
	if _, e := c.Bib(context.Background(), "personal", "../x", "key"); e == nil {
		t.Fatal("accepted invalid key")
	}
}

func TestUnavailableAPIGivesSetupGuidance(t *testing.T) {
	for _, status := range []int{0, http.StatusForbidden, http.StatusNotFound} {
		t.Run(http.StatusText(status), func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				http.Error(w, "API unavailable", status)
			}))
			defer server.Close()
			c := New()
			c.Base = server.URL
			if status == 0 {
				server.Close()
			}
			operations := []func() error{
				func() error { _, err := c.Search(context.Background(), "personal", ""); return err },
				func() error { _, err := c.Groups(context.Background()); return err },
				func() error { _, err := c.Bib(context.Background(), "personal", "ABCD1234", "citation"); return err },
			}
			for _, operation := range operations {
				err := operation()
				if err == nil || !strings.Contains(err.Error(), "Settings → Advanced") || !strings.Contains(err.Error(), "Allow other applications on this computer to communicate with Zotero") {
					t.Fatalf("missing setup guidance: %v", err)
				}
			}
		})
	}
}
