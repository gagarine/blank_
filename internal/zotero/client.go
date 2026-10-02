package zotero

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"
)

type Client struct {
	Base string
	HTTP *http.Client
}

func New() *Client {
	return &Client{Base: "http://localhost:23119/api", HTTP: &http.Client{Timeout: 8 * time.Second}}
}

type Item struct {
	Key     string `json:"key"`
	Version int    `json:"version"`
	Library struct {
		ID   int    `json:"id"`
		Type string `json:"type"`
		Name string `json:"name"`
	} `json:"library"`
	Data struct {
		ItemType string `json:"itemType"`
		Title    string `json:"title"`
		Date     string `json:"date"`
		DOI      string `json:"DOI"`
		Creators []struct {
			FirstName string `json:"firstName"`
			LastName  string `json:"lastName"`
			Name      string `json:"name"`
		} `json:"creators"`
	} `json:"data"`
}
type Result struct {
	Key     string `json:"key"`
	Library string `json:"library"`
	Title   string `json:"title"`
	Author  string `json:"author"`
	Year    string `json:"year"`
	Version int    `json:"version"`
	CiteKey string `json:"citeKey"`
}

var keyPattern = regexp.MustCompile(`^[A-Z0-9]{8}$`)
var groupPattern = regexp.MustCompile(`^groups/[0-9]+$`)
var yearPattern = regexp.MustCompile(`\d{4}`)

func LibraryPath(library string) (string, error) {
	if library == "" || library == "personal" {
		return "users/0", nil
	}
	if groupPattern.MatchString(library) {
		return library, nil
	}
	return "", errors.New("invalid Zotero library")
}

const localAPIGuidance = `Open Zotero, then go to Settings → Advanced and enable “Allow other applications on this computer to communicate with Zotero”. Keep Zotero open, then try again.`

func (c *Client) get(ctx context.Context, path string) ([]byte, error) {
	req, e := http.NewRequestWithContext(ctx, "GET", c.Base+"/"+path, nil)
	if e != nil {
		return nil, e
	}
	req.Header.Set("Zotero-API-Version", "3")
	r, e := c.HTTP.Do(req)
	if e != nil {
		return nil, fmt.Errorf("Cannot access Zotero’s local HTTP API. %s (%w)", localAPIGuidance, e)
	}
	defer r.Body.Close()
	data, e := io.ReadAll(io.LimitReader(r.Body, 16*1024*1024))
	if e != nil {
		return nil, e
	}
	if r.StatusCode != 200 {
		return nil, fmt.Errorf("Zotero returned HTTP %d: %s. If the local HTTP API is disabled, %s", r.StatusCode, strings.TrimSpace(string(data)), localAPIGuidance)
	}
	return data, nil
}
func (c *Client) Search(ctx context.Context, library, query string) ([]Result, error) {
	p, e := LibraryPath(library)
	if e != nil {
		return nil, e
	}
	data, e := c.get(ctx, p+"/items/top?limit=40&includeTrashed=0&q="+url.QueryEscape(query)+"&qmode=titleCreatorYear")
	if e != nil {
		return nil, e
	}
	var items []Item
	if e = json.Unmarshal(data, &items); e != nil {
		return nil, e
	}
	out := []Result{}
	for _, i := range items {
		if i.Data.ItemType == "attachment" || i.Data.ItemType == "note" {
			continue
		}
		authors := []string{}
		for _, a := range i.Data.Creators {
			n := a.LastName
			if n == "" {
				n = a.Name
			}
			if n != "" {
				authors = append(authors, n)
			}
		}
		author := strings.Join(authors, ", ")
		if len(authors) > 2 {
			author = authors[0] + " et al."
		}
		identity := strings.ReplaceAll(p, "/", "-")
		out = append(out, Result{Key: i.Key, Library: library, Title: i.Data.Title, Author: author, Year: yearPattern.FindString(i.Data.Date), Version: i.Version, CiteKey: "zotero-" + identity + "-" + i.Key})
	}
	return out, nil
}
func (c *Client) Groups(ctx context.Context) (json.RawMessage, error) {
	data, e := c.get(ctx, "users/0/groups")
	return data, e
}
func (c *Client) Bib(ctx context.Context, library, key, citeKey string) (string, error) {
	p, e := LibraryPath(library)
	if e != nil {
		return "", e
	}
	if !keyPattern.MatchString(key) {
		return "", errors.New("invalid Zotero item key")
	}
	data, e := c.get(ctx, p+"/items/"+key+"?format=biblatex")
	if e != nil {
		return "", e
	}
	text := strings.TrimSpace(string(data))
	open := strings.Index(text, "{")
	comma := strings.Index(text, ",")
	if open < 1 || comma <= open {
		return "", errors.New("Zotero did not return a BibLaTeX entry")
	}
	return text[:open+1] + citeKey + text[comma:] + "\n", nil
}

// Upsert only replaces the named complete entry, leaving other bytes untouched.
func Upsert(text, key, entry string) (string, error) {
	needle := regexp.MustCompile(`(?m)@[A-Za-z]+\s*\{\s*` + regexp.QuoteMeta(key) + `\s*,`)
	loc := needle.FindStringIndex(text)
	if loc == nil {
		return text + "\n" + entry, nil
	}
	depth := 0
	escaped := false
	for i := strings.Index(text[loc[0]:], "{") + loc[0]; i < len(text); i++ {
		ch := text[i]
		if escaped {
			escaped = false
			continue
		}
		if ch == '\\' {
			escaped = true
			continue
		}
		if ch == '{' {
			depth++
		}
		if ch == '}' {
			depth--
			if depth == 0 {
				return text[:loc[0]] + strings.TrimSuffix(entry, "\n") + text[i+1:], nil
			}
		}
	}
	return "", errors.New("existing BibLaTeX entry is malformed; preserve and repair it before refreshing")
}
