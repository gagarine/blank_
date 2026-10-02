package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/wailsapp/wails/v3/pkg/application"
	"writer/internal/document"
	"writer/internal/engine"
	"writer/internal/zotero"
)

type App struct {
	ctx              context.Context
	cancel           context.CancelFunc
	lifecycle        sync.RWMutex
	closed           bool
	desktop          *Desktop
	window           *application.WebviewWindow
	rpcRequestedPath string
	docs             *document.Service
	helper           *engine.Helper
	zotero           *zotero.Client
	mu               sync.Mutex
	compileMu        sync.Mutex
	assetMu          sync.Mutex
	preview          map[string]any
	subs             map[chan []byte]bool
	initial          string
	demo             bool
	native           bool
	dataDir          string
	rpcMu            sync.Mutex
	rpcListener      net.Listener
	rpcPath          string
	rpcClosed        bool
}

func NewApp(initial string) *App {
	cache, _ := os.UserConfigDir()
	dir := filepath.Join(cache, "TypstWriter")
	if custom := os.Getenv("WRITER_DATA_DIR"); custom != "" {
		dir = custom
	}
	a := &App{ctx: context.Background(), helper: engine.New(engine.Find()), zotero: zotero.New(), subs: map[chan []byte]bool{}, initial: initial, dataDir: dir}
	a.ctx, a.cancel = context.WithCancel(a.ctx)
	a.docs = document.New(filepath.Join(dir, "recovery"), func(s document.Snapshot) { a.emit("document", s) }, func(e error) { a.emit("error", e.Error()) })
	return a
}
func (a *App) shutdown(context.Context) {
	a.cancel()
	a.lifecycle.Lock()
	defer a.lifecycle.Unlock()
	if a.closed {
		return
	}
	a.closed = true
	a.docs.Save()
	a.docs.Close()
	a.helper.Close()
	a.closeSocket()
}
func (a *App) emit(event string, value any) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.window != nil {
		a.window.DispatchWailsEvent(&application.CustomEvent{Name: event, Data: value})
	}
	if len(a.subs) == 0 {
		return
	}
	data, _ := json.Marshal(map[string]any{"event": event, "data": value})
	for ch := range a.subs {
		select {
		case ch <- data:
		default:
		}
	}
}
func (a *App) Call(method, params string) (string, error) {
	var p json.RawMessage = []byte(params)
	if params == "" {
		p = []byte("{}")
	}
	v, e := a.dispatch(method, p, false)
	if e != nil {
		return "", e
	}
	data, e := json.Marshal(v)
	return string(data), e
}
func decode(raw json.RawMessage, v any) error { return json.Unmarshal(raw, v) }

func (a *App) dispatch(method string, raw json.RawMessage, agent bool) (any, error) {
	a.lifecycle.RLock()
	defer a.lifecycle.RUnlock()
	if a.closed {
		return nil, errors.New("document window is closed")
	}
	snap := a.docs.Snapshot()
	if agent && (!snap.AgentEnabled || snap.ID == "") {
		return nil, errors.New("agent_access_disabled: enable agent access for the open project")
	}
	if agent {
		allowed := map[string]bool{"project.read": true, "project.outline": true, "context.selection": true, "document.applyEdits": true, "document.undo": true, "zotero.search": true, "citation.insert": true, "diagnostics.list": true, "preview.compile": true, "preview.exportPDF": true}
		if !allowed[method] {
			return nil, errors.New("method unavailable to agents")
		}
	}
	switch method {
	case "recent.list":
		return a.recentDocuments(), nil
	case "recent.remove":
		var p struct{ Path string }
		if err := decode(raw, &p); err != nil {
			return nil, err
		}
		return nil, a.forgetDocument(p.Path)
	case "window.open":
		var p struct{ Path string }
		if err := decode(raw, &p); err != nil {
			return nil, err
		}
		if p.Path == "" {
			return nil, errors.New("choose a document")
		}
		if a.native {
			return nil, a.desktop.openWindow(p.Path, false)
		}
		return a.open(p.Path)
	case "settings.fonts":
		return systemFontFamilies()
	case "document.demo":
		return a.openDemo()
	case "window.help":
		if a.native {
			return nil, a.desktop.openWindow("", true)
		}
		return a.openDemo()
	case "project.read":
		return snap, nil
	case "project.info":
		info, err := a.docs.Information()
		a.rpcMu.Lock()
		path := a.rpcPath
		a.rpcMu.Unlock()
		return struct {
			document.Information
			AgentSocket string `json:"agentSocket,omitempty"`
		}{info, path}, err
	case "document.rename":
		var p struct {
			ProjectID string `json:"projectId"`
			Name      string `json:"name"`
		}
		if e := decode(raw, &p); e != nil {
			return nil, e
		}
		renamed, err := a.docs.RenameEntry(p.ProjectID, p.Name)
		if err == nil {
			a.rememberDocument(renamed, filepath.Join(snap.Root, snap.Entry))
		}
		return renamed, err
	case "window.title":
		var p struct{ Title string }
		if err := decode(raw, &p); err != nil {
			return nil, err
		}
		if a.native {
			a.window.SetTitle(p.Title)
			a.installEditingActions()
		}
		return nil, nil
	case "document.new":
		var p struct{ Path string }
		if err := decode(raw, &p); err != nil {
			return nil, err
		}
		if a.native {
			return nil, a.desktop.newDocumentWindow()
		}
		if p.Path == "" {
			return a.openBlankDraft()
		}
		if err := createEmptyDocument(p.Path); err != nil {
			return nil, err
		}
		return a.open(p.Path)
	case "project.open":
		if agent {
			return nil, errors.New("open projects in the writer first")
		}
		var p struct{ Path string }
		if e := decode(raw, &p); e != nil {
			return nil, e
		}
		return a.open(p.Path)
	case "project.dialog":
		if !a.native {
			return nil, errors.New("enter a project path in browser development mode")
		}
		path, e := a.openFileDialog("Open a Typst document", "Typst", "*.typ")
		if e != nil || path == "" {
			return nil, e
		}
		return nil, a.desktop.openWindow(path, false)
	case "project.new":
		if agent {
			return nil, errors.New("create projects in the writer")
		}
		var p struct {
			Path string
			Kind string
		}
		decode(raw, &p)
		if p.Path == "" && a.native {
			dir, e := a.desktop.app.Dialog.OpenFile().SetTitle("Choose an empty folder for the project").CanChooseFiles(false).CanChooseDirectories(true).CanCreateDirectories(true).AttachToWindow(a.window).PromptForSingleSelection()
			if e != nil {
				return nil, e
			}
			p.Path = dir
		}
		if p.Path == "" {
			return nil, errors.New("choose a project folder")
		}
		return a.newProject(p.Path, p.Kind)
	case "project.agent":
		if agent {
			return nil, errors.New("agent cannot change its own access")
		}
		var p struct{ Enabled bool }
		decode(raw, &p)
		return a.docs.SetAgent(p.Enabled), nil
	case "document.applyEdits":
		var p document.Transaction
		if e := decode(raw, &p); e != nil {
			return nil, e
		}
		if agent {
			p.Origin = "agent"
		} else if p.Origin == "" {
			p.Origin = "user"
		}
		return a.docs.Apply(p)
	case "document.save":
		if snap.Unsaved {
			var p struct{ Path string }
			if err := decode(raw, &p); err != nil {
				return nil, err
			}
			if p.Path == "" && a.native {
				path, err := a.saveFileDialog("Save Document", snap.Entry, "Typst document", "*.typ")
				if err != nil {
					return nil, err
				}
				if path == "" {
					return snap, nil
				}
				p.Path = path
			}
			if p.Path == "" {
				return nil, errors.New("choose a save location for this document")
			}
			saved, err := a.docs.SaveDraftAs(p.Path)
			if err == nil {
				a.rememberDocument(saved, "")
			}
			return saved, err
		}
		return a.docs.Save()
	case "document.rescan":
		return a.docs.Rescan(), nil
	case "document.undo":
		var p struct{ Origin string }
		decode(raw, &p)
		if agent {
			p.Origin = "agent"
		}
		return a.docs.Undo(p.Origin)
	case "document.redo":
		return a.docs.Redo()
	case "document.resolve":
		var p struct{ Path, Text string }
		decode(raw, &p)
		return a.docs.Resolve(p.Path, p.Text)
	case "context.selection":
		if string(raw) != "{}" && !agent {
			var p document.Selection
			if e := decode(raw, &p); e != nil {
				return nil, e
			}
			a.docs.SetSelection(p)
		}
		return a.docs.Selection(), nil
	case "document.parse":
		var p struct{ Path string }
		decode(raw, &p)
		f, ok := snap.Files[p.Path]
		if !ok {
			return nil, errors.New("file not open")
		}
		var out any
		ctx, cancel := context.WithTimeout(a.ctx, 15*time.Second)
		defer cancel()
		e := a.helper.Call(ctx, "parse", map[string]any{"path": snap.ID + ":" + p.Path, "text": f.Text, "revision": f.Revision}, &out)
		return out, e
	case "asset.read":
		var p struct{ Path string }
		if e := decode(raw, &p); e != nil {
			return nil, e
		}
		return a.readAsset(p.Path)
	case "asset.add":
		if agent {
			return nil, errors.New("import figures through the UI")
		}
		var p struct{ Name, Data string }
		if e := decode(raw, &p); e != nil {
			return nil, e
		}
		data, e := base64.StdEncoding.DecodeString(p.Data)
		if e != nil {
			return nil, e
		}
		return a.importAsset(p.Name, data)
	case "asset.importPaths":
		if agent || !a.native {
			return nil, errors.New("drop figures in the desktop app")
		}
		var p struct{ Paths []string }
		if e := decode(raw, &p); e != nil {
			return nil, e
		}
		out := []string{}
		for _, path := range p.Paths {
			rel, e := a.importAssetPath(path)
			if e != nil {
				return nil, e
			}
			out = append(out, rel)
		}
		return out, nil
	case "asset.import":
		if agent || !a.native {
			return nil, errors.New("choose a figure in the desktop app")
		}
		path, e := a.openFileDialog("Choose an image or PDF figure", "Images and PDF figures", "*.png;*.jpg;*.jpeg;*.gif;*.svg;*.webp;*.pdf")
		if e != nil || path == "" {
			return nil, e
		}
		return a.importAssetPath(path)
	case "project.outline":
		return a.outline(snap), nil
	case "preview.compile":
		return a.compile()
	case "preview.current", "diagnostics.list":
		a.mu.Lock()
		defer a.mu.Unlock()
		if method == "diagnostics.list" {
			return a.preview["diagnostics"], nil
		}
		return a.preview, nil
	case "preview.cancel":
		a.helper.Close()
		return true, nil
	case "preview.exportPDF":
		var p struct{ Path string }
		decode(raw, &p)
		if p.Path != "" && !strings.EqualFold(filepath.Ext(p.Path), ".pdf") {
			return nil, errors.New("export destination must end in .pdf")
		}
		if agent {
			full, e := document.SafePath(snap.Root, p.Path)
			if e != nil {
				return nil, e
			}
			p.Path = full
		}
		if p.Path == "" && a.native {
			path, e := a.saveFileDialog("Export PDF", "manuscript.pdf", "PDF", "*.pdf")
			if e != nil {
				return nil, e
			}
			p.Path = path
		}
		if p.Path == "" {
			return nil, errors.New("choose an export destination")
		}
		result, e := a.compile()
		if e != nil {
			return nil, e
		}
		encoded, _ := result["pdf"].(string)
		if encoded == "" {
			return nil, errors.New("fix compilation errors before exporting")
		}
		if a.docs.Snapshot().Revision != snap.Revision || a.docs.Snapshot().ID != snap.ID {
			return nil, errors.New("document changed during export; retry")
		}
		data, e := base64.StdEncoding.DecodeString(encoded)
		if e != nil {
			return nil, e
		}
		if e = document.AtomicWrite(p.Path, data); e != nil {
			return nil, e
		}
		return map[string]any{"path": p.Path, "revision": snap.Revision}, nil
	case "zotero.search":
		var p struct{ Library, Query string }
		decode(raw, &p)
		return a.zotero.Search(a.ctx, p.Library, p.Query)
	case "zotero.groups":
		return a.zotero.Groups(a.ctx)
	case "citation.insert":
		var p citationRequest
		if e := decode(raw, &p); e != nil {
			return nil, e
		}
		if agent {
			p.Origin = "agent"
		}
		return a.insertCitation(p)
	case "citation.refresh":
		return a.refreshCitations()
	case "window.fullscreen":
		if a.native {
			a.window.ToggleFullscreen()
		}
		return true, nil
	default:
		return nil, fmt.Errorf("unknown method: %s", method)
	}
}

func (a *App) open(path string) (document.Snapshot, error) {
	if a.docs.Snapshot().ID != "" {
		if _, err := a.docs.Save(); err != nil {
			return document.Snapshot{}, err
		}
	}
	s, err := a.docs.Open(path)
	if err == nil {
		a.rememberDocument(s, "")
		a.mu.Lock()
		a.preview = nil
		a.mu.Unlock()
	}
	return s, err
}

func (a *App) compile() (map[string]any, error) {
	a.compileMu.Lock()
	defer a.compileMu.Unlock()
	s := a.docs.Snapshot()
	if s.ID == "" {
		return nil, errors.New("open a document first")
	}
	files := map[string]string{}
	for p, f := range s.Files {
		files[p] = f.Text
	}
	var result map[string]any
	ctx, cancel := context.WithTimeout(a.ctx, 90*time.Second)
	defer cancel()
	e := a.helper.Call(ctx, "compile", map[string]any{"root": s.Root, "entry": s.Entry, "files": files, "revision": s.Revision}, &result)
	if e != nil {
		return nil, e
	}
	result["projectId"] = s.ID
	if a.docs.Snapshot().ID != s.ID || a.docs.Snapshot().Revision != s.Revision {
		return result, nil
	}
	a.mu.Lock()
	if result["pdf"] == nil && a.preview != nil {
		result["sourceMap"] = a.preview["sourceMap"]
		result["pageRatios"] = a.preview["pageRatios"]
		result["previousPdf"] = a.preview["pdf"]
		if result["previousPdf"] == nil {
			result["previousPdf"] = a.preview["previousPdf"]
		}
	}
	a.preview = result
	a.mu.Unlock()
	a.emit("preview", result)
	return result, nil
}

func (a *App) outline(s document.Snapshot) []map[string]any {
	var out []map[string]any
	pattern := regexp.MustCompile(`(?m)^(=+)\s+([^\r\n]+)`)
	for p, f := range s.Files {
		if !strings.HasSuffix(p, ".typ") {
			continue
		}
		for _, loc := range pattern.FindAllStringSubmatchIndex(f.Text, -1) {
			out = append(out, map[string]any{"path": p, "start": loc[0], "level": loc[3] - loc[2], "title": f.Text[loc[4]:loc[5]]})
		}
	}
	return out
}

func (a *App) newProject(path, kind string) (document.Snapshot, error) {
	abs, e := filepath.Abs(path)
	if e != nil {
		return document.Snapshot{}, e
	}
	entries, e := os.ReadDir(abs)
	if e != nil && !os.IsNotExist(e) {
		return document.Snapshot{}, e
	}
	if len(entries) > 0 {
		return document.Snapshot{}, errors.New("choose an empty folder to avoid replacing existing files")
	}
	files := map[string]string{"writer.json": "{\"entry\":\"main.typ\"}\n", "writer-zotero.bib": "", "writer-references.json": "{}\n"}
	preamble := "#set page(paper: \"a4\", margin: 2.5cm)\n#set text(font: \"Libertinus Serif\", size: 11pt)\n#set heading(numbering: \"1.1\")\n\n"
	if kind == "thesis" {
		files["main.typ"] = preamble + "#align(center)[\n  #text(size: 26pt, weight: \"bold\")[A thesis in progress]\n\n  Your name\n]\n#pagebreak()\n#outline()\n#pagebreak()\n\n#include \"chapters/01-introduction.typ\"\n#include \"chapters/02-methods.typ\"\n\n#bibliography(\"writer-zotero.bib\", style: \"apa\")\n"
		files["chapters/01-introduction.typ"] = "= Introduction <introduction>\n\nEvery worthwhile investigation begins with a question. What is yours?\n\n== The question\n\nStart writing here.\n"
		files["chapters/02-methods.typ"] = "= Methods <methods>\n\nDescribe how you will approach your question.\n"
	} else {
		files["main.typ"] = preamble + "#align(center)[#text(size: 24pt, weight: \"bold\")[Untitled paper]]\n\n= Introduction <introduction>\n\nStart with the idea you want to explore.\n\n= Discussion\n\nYour next thought belongs here.\n\n#bibliography(\"writer-zotero.bib\", style: \"apa\")\n"
	}
	for p, t := range files {
		if e = document.AtomicWrite(filepath.Join(abs, p), []byte(t)); e != nil {
			return document.Snapshot{}, e
		}
	}
	os.MkdirAll(filepath.Join(abs, "assets"), 0755)
	return a.open(abs)
}

type citationRequest struct {
	ProjectID string          `json:"projectId"`
	Path      string          `json:"path"`
	Start     int             `json:"start"`
	End       int             `json:"end"`
	Revision  uint64          `json:"revision"`
	Items     []zotero.Result `json:"items"`
	Locator   string          `json:"locator"`
	Form      string          `json:"form"`
	Origin    string          `json:"origin"`
}

func escapeContent(s string) string {
	r := strings.NewReplacer("\\", "\\\\", "#", "\\#", "[", "\\[", "]", "\\]", "*", "\\*", "_", "\\_", "$", "\\$", "@", "\\@")
	return r.Replace(s)
}
func (a *App) insertCitation(p citationRequest) (document.Snapshot, error) {
	s := a.docs.Snapshot()
	f, ok := s.Files[p.Path]
	if !ok || p.ProjectID != s.ID || p.Revision != f.Revision {
		return document.Snapshot{}, errors.New("stale citation insertion; select the passage again")
	}
	if len(p.Items) == 0 {
		return document.Snapshot{}, errors.New("select a reference")
	}
	bib := s.Files["writer-zotero.bib"].Text
	refs := map[string]zotero.Result{}
	if t := s.Files["writer-references.json"].Text; t != "" {
		if e := json.Unmarshal([]byte(t), &refs); e != nil {
			return document.Snapshot{}, e
		}
	}
	var cites []string
	for _, item := range p.Items {
		library, e := zotero.LibraryPath(item.Library)
		if e != nil {
			return document.Snapshot{}, e
		}
		key := "zotero-" + strings.ReplaceAll(library, "/", "-") + "-" + item.Key
		item.CiteKey = key
		entry, e := a.zotero.Bib(a.ctx, item.Library, item.Key, key)
		if e != nil {
			return document.Snapshot{}, e
		}
		bib, e = zotero.Upsert(bib, key, entry)
		if e != nil {
			return document.Snapshot{}, e
		}
		refs[key] = item
		cite := "@" + key
		if p.Locator != "" || p.Form != "" {
			cite = "#cite(<" + key + ">"
			if p.Locator != "" {
				cite += ", supplement: [" + escapeContent(p.Locator) + "]"
			}
			if p.Form == "prose" || p.Form == "year" || p.Form == "author" {
				cite += ", form: \"" + p.Form + "\""
			}
			cite += ")"
		}
		cites = append(cites, cite)
	}
	metadata, _ := json.MarshalIndent(refs, "", "  ")
	edits := []document.Edit{{Path: p.Path, Start: p.Start, End: p.End, Text: strings.Join(cites, " ")}, {Path: "writer-zotero.bib", Start: 0, End: len(s.Files["writer-zotero.bib"].Text), Text: bib}, {Path: "writer-references.json", Start: 0, End: len(s.Files["writer-references.json"].Text), Text: string(metadata) + "\n"}}
	root := s.Files[s.Entry].Text
	if !strings.Contains(root, "writer-zotero.bib") {
		suffix := "\n\n#bibliography(\"writer-zotero.bib\", style: \"apa\")\n"
		if p.Path == s.Entry && p.End == len(root) {
			edits[0].Text += suffix
		} else {
			edits = append(edits, document.Edit{Path: s.Entry, Start: len(root), End: len(root), Text: suffix})
		}
	}
	expected := map[string]uint64{}
	for _, e := range edits {
		expected[e.Path] = s.Files[e.Path].Revision
	}
	origin := p.Origin
	if origin == "" {
		origin = "user"
	}
	return a.docs.Apply(document.Transaction{ProjectID: s.ID, Expected: expected, Edits: edits, Origin: origin})
}
func (a *App) refreshCitations() (document.Snapshot, error) {
	s := a.docs.Snapshot()
	var refs map[string]zotero.Result
	if e := json.Unmarshal([]byte(s.Files["writer-references.json"].Text), &refs); e != nil {
		return document.Snapshot{}, errors.New("no saved Zotero references")
	}
	text := s.Files["writer-zotero.bib"].Text
	for key, r := range refs {
		entry, e := a.zotero.Bib(a.ctx, r.Library, r.Key, key)
		if e != nil {
			return document.Snapshot{}, e
		}
		text, e = zotero.Upsert(text, key, entry)
		if e != nil {
			return document.Snapshot{}, e
		}
	}
	return a.docs.Apply(document.Transaction{ProjectID: s.ID, Expected: map[string]uint64{"writer-zotero.bib": s.Files["writer-zotero.bib"].Revision}, Edits: []document.Edit{{Path: "writer-zotero.bib", End: len(s.Files["writer-zotero.bib"].Text), Text: text}}, Origin: "references"})
}
