package document

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/fsnotify/fsnotify"
)

type Service struct {
	mu        sync.Mutex
	project   Snapshot
	history   []historyEntry
	redo      []historyEntry
	selection Selection
	journal   string
	timer     *time.Timer
	watcher   *fsnotify.Watcher
	done      chan struct{}
	onChange  func(Snapshot)
	onError   func(error)
	assets    map[string]int64
	closed    bool
}

func New(journal string, changed func(Snapshot), failed func(error)) *Service {
	return &Service{journal: journal, onChange: changed, onError: failed}
}

func (s *Service) Open(input string) (Snapshot, error) {
	abs, err := filepath.Abs(input)
	if err != nil {
		return Snapshot{}, err
	}
	info, err := os.Stat(abs)
	if err != nil {
		return Snapshot{}, err
	}
	root, entry := abs, "main.typ"
	if !info.IsDir() {
		root, entry = filepath.Dir(abs), filepath.Base(abs)
	}
	root, err = filepath.EvalSymlinks(root)
	if err != nil {
		return Snapshot{}, err
	}
	if info.IsDir() {
		var config struct {
			Entry string `json:"entry"`
		}
		if data, e := os.ReadFile(filepath.Join(root, "writer.json")); e == nil {
			if e = json.Unmarshal(data, &config); e != nil {
				return Snapshot{}, fmt.Errorf("writer.json: %w", e)
			}
			if config.Entry != "" {
				entry = config.Entry
			}
		}
	}
	if _, err = SafePath(root, entry); err != nil {
		return Snapshot{}, err
	}
	files := map[string]File{}
	err = filepath.WalkDir(root, func(path string, d fs.DirEntry, e error) error {
		if e != nil {
			return e
		}
		rel, _ := filepath.Rel(root, path)
		if d.IsDir() {
			if rel != "." && (strings.HasPrefix(d.Name(), ".") || d.Name() == "node_modules" || d.Name() == "target") {
				return filepath.SkipDir
			}
			return nil
		}
		if d.Type()&os.ModeSymlink != 0 {
			return nil
		}
		ext := strings.ToLower(filepath.Ext(path))
		if ext != ".typ" && ext != ".bib" && ext != ".yaml" && ext != ".yml" && ext != ".csl" && rel != "writer-references.json" {
			return nil
		}
		data, e := os.ReadFile(path)
		if e != nil {
			return e
		}
		if !utf8.Valid(data) {
			return fmt.Errorf("%s is not UTF-8", rel)
		}
		files[filepath.ToSlash(rel)] = File{Path: filepath.ToSlash(rel), Text: string(data), base: string(data), Revision: 1, exists: true}
		return nil
	})
	if err != nil {
		return Snapshot{}, err
	}
	entry = filepath.ToSlash(filepath.Clean(entry))
	if _, ok := files[entry]; !ok {
		return Snapshot{}, fmt.Errorf("entrypoint %s does not exist; open a .typ file or set writer.json entry", entry)
	}
	s.mu.Lock()
	if !s.closed && s.project.Root == root && s.project.Entry == entry {
		s.mu.Unlock()
		return s.Rescan(), nil
	}
	if s.timer != nil {
		s.timer.Stop()
	}
	if s.watcher != nil {
		s.watcher.Close()
	}
	if s.done != nil {
		close(s.done)
	}
	hash := sha256.Sum256([]byte(root + "\x00" + entry))
	s.closed = false
	s.project = Snapshot{ID: hex.EncodeToString(hash[:12]), Root: root, Entry: entry, Files: files, Revision: 1, LastOrigin: "open"}
	_, draftErr := os.Stat(filepath.Join(root, ".blank-draft"))
	s.project.Unsaved = draftErr == nil
	s.assets = map[string]int64{}
	s.discoverLocked(false)
	s.history = nil
	s.redo = nil
	s.selection = Selection{Path: entry, Revision: 1}
	s.restoreLocked()
	watcher, e := fsnotify.NewWatcher()
	if e == nil {
		s.watcher = watcher
		s.done = make(chan struct{})
		filepath.WalkDir(root, func(path string, d fs.DirEntry, e error) error {
			if e != nil {
				return nil
			}
			if d.IsDir() {
				if path != root && (strings.HasPrefix(d.Name(), ".") || d.Name() == "node_modules" || d.Name() == "target") {
					return filepath.SkipDir
				}
				watcher.Add(path)
			}
			return nil
		})
		go s.watch(watcher, s.done)
	}
	snap := s.snapshotLocked()
	s.mu.Unlock()
	if e != nil {
		s.fail(e)
	}
	s.emit(snap)
	return snap, nil
}

func SafePath(root, path string) (string, error) {
	if path == "" || filepath.IsAbs(path) {
		return "", errors.New("a project-relative path is required")
	}
	clean := filepath.Clean(path)
	if clean == ".." || strings.HasPrefix(clean, ".."+string(filepath.Separator)) {
		return "", errors.New("path escapes project")
	}
	full := filepath.Join(root, clean)
	// Resolve every existing ancestor, including symlinked directories.
	probe := full
	for {
		resolved, e := filepath.EvalSymlinks(probe)
		if e == nil {
			rel, e := filepath.Rel(root, resolved)
			if e != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
				return "", errors.New("symlink escapes project")
			}
			break
		}
		if !os.IsNotExist(e) {
			return "", e
		}
		parent := filepath.Dir(probe)
		if parent == probe {
			return "", e
		}
		probe = parent
	}
	return full, nil
}

func (s *Service) snapshotLocked() Snapshot {
	v := s.project
	v.Files = make(map[string]File, len(s.project.Files))
	for k, f := range s.project.Files {
		if f.Conflict != nil {
			c := *f.Conflict
			f.Conflict = &c
		}
		v.Files[k] = f
	}
	return v
}
func (s *Service) Snapshot() Snapshot { s.mu.Lock(); defer s.mu.Unlock(); return s.snapshotLocked() }
func (s *Service) fail(e error) {
	if s.onError != nil {
		s.onError(e)
	}
}
func (s *Service) emit(v Snapshot) {
	if s.onChange != nil {
		s.onChange(v)
	}
}

func (s *Service) Apply(tx Transaction) (Snapshot, error) {
	s.mu.Lock()
	if s.closed || tx.ProjectID != s.project.ID || s.project.ID == "" {
		s.mu.Unlock()
		return Snapshot{}, errors.New("project_mismatch")
	}
	byFile := map[string][]Edit{}
	for _, e := range tx.Edits {
		if _, err := SafePath(s.project.Root, e.Path); err != nil {
			s.mu.Unlock()
			return Snapshot{}, err
		}
		byFile[e.Path] = append(byFile[e.Path], e)
	}
	before, after := map[string]string{}, map[string]string{}
	for path, edits := range byFile {
		f, ok := s.project.Files[path]
		if !ok {
			full, err := SafePath(s.project.Root, path)
			if err != nil {
				s.mu.Unlock()
				return Snapshot{}, err
			}
			if _, err = os.Stat(full); err == nil {
				s.mu.Unlock()
				return Snapshot{}, fmt.Errorf("file_not_loaded: %s; rescan before editing", path)
			} else if !os.IsNotExist(err) {
				s.mu.Unlock()
				return Snapshot{}, err
			}
			f = File{Path: path}
		}
		expected, provided := tx.Expected[path]
		if !provided || expected != f.Revision {
			s.mu.Unlock()
			return Snapshot{}, fmt.Errorf("stale_revision: %s is revision %d", path, f.Revision)
		}
		if f.Conflict != nil {
			s.mu.Unlock()
			return Snapshot{}, fmt.Errorf("unresolved_conflict: %s", path)
		}
		sort.Slice(edits, func(i, j int) bool { return edits[i].Start > edits[j].Start })
		text := f.Text
		boundary := len(text) + 1
		for _, e := range edits {
			if e.Start < 0 || e.End < e.Start || e.End > len(f.Text) || e.End > boundary || (e.Start == e.End && e.Start == boundary) || !utf8.ValidString(e.Text) || !utf8.ValidString(f.Text[:e.Start]) || !utf8.ValidString(f.Text[:e.End]) {
				s.mu.Unlock()
				return Snapshot{}, fmt.Errorf("invalid or overlapping UTF-8 range in %s", path)
			}
			text = text[:e.Start] + e.Text + text[e.End:]
			boundary = e.Start
		}
		if text != f.Text {
			before[path] = f.Text
			after[path] = text
		}
	}
	if len(after) > 0 {
		s.project.Revision++
		s.project.LastOrigin = tx.Origin
		for p, t := range after {
			f := s.project.Files[p]
			f.Path = p
			s.remapSelectionLocked(p, f.Text, t, f.Revision+1)
			f.Text = t
			f.Revision++
			f.Dirty = t != f.base || !f.exists
			s.project.Files[p] = f
		}
		s.history = append(s.history, historyEntry{ID: s.project.Revision, Origin: tx.Origin, Before: before, After: after})
		s.redo = nil
		s.journalLocked()
		s.autosaveLocked()
	}
	v := s.snapshotLocked()
	s.mu.Unlock()
	s.emit(v)
	return v, nil
}

func (s *Service) Undo(origin string) (Snapshot, error) { return s.historyStep(false, origin) }
func (s *Service) Redo() (Snapshot, error)              { return s.historyStep(true, "") }
func (s *Service) historyStep(redo bool, origin string) (Snapshot, error) {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return Snapshot{}, errors.New("document session closed")
	}
	entries := s.history
	if redo {
		entries = s.redo
	}
	idx := len(entries) - 1
	for idx >= 0 && origin != "" && entries[idx].Origin != origin {
		idx--
	}
	if idx < 0 {
		v := s.snapshotLocked()
		s.mu.Unlock()
		return v, nil
	}
	h := entries[idx]
	result := map[string]string{}
	for p, before := range h.Before {
		f, ok := s.project.Files[p]
		if !ok || f.Conflict != nil {
			s.mu.Unlock()
			return Snapshot{}, errors.New("undo_conflict")
		}
		base, target := h.After[p], before
		if redo {
			base, target = before, h.After[p]
		}
		merged, ok := Merge(base, f.Text, target)
		if !ok {
			s.mu.Unlock()
			return Snapshot{}, errors.New("undo_conflict: later changes overlap this transaction")
		}
		result[p] = merged
	}
	for p, t := range result {
		f := s.project.Files[p]
		s.remapSelectionLocked(p, f.Text, t, f.Revision+1)
		f.Text = t
		f.Revision++
		f.Dirty = t != f.base || !f.exists
		s.project.Files[p] = f
	}
	if redo {
		s.redo = append(s.redo[:idx], s.redo[idx+1:]...)
		s.history = append(s.history, h)
	} else {
		s.history = append(s.history[:idx], s.history[idx+1:]...)
		s.redo = append(s.redo, h)
	}
	s.project.Revision++
	s.project.LastOrigin = "undo"
	s.journalLocked()
	s.autosaveLocked()
	v := s.snapshotLocked()
	s.mu.Unlock()
	s.emit(v)
	return v, nil
}

func (s *Service) autosaveLocked() {
	if s.timer != nil {
		s.timer.Stop()
	}
	s.timer = time.AfterFunc(750*time.Millisecond, func() {
		if _, e := s.Save(); e != nil {
			s.fail(e)
		}
	})
}

func AtomicWrite(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	f, e := os.CreateTemp(filepath.Dir(path), ".writer-save-*")
	if e != nil {
		return e
	}
	name := f.Name()
	defer os.Remove(name)
	mode := os.FileMode(0600)
	if st, err := os.Stat(path); err == nil {
		mode = st.Mode().Perm()
		preserveCreationTime(name, st)
	}
	f.Chmod(mode)
	if _, e = f.Write(data); e == nil {
		e = f.Sync()
	}
	closeErr := f.Close()
	if e != nil {
		return e
	}
	if closeErr != nil {
		return closeErr
	}
	if e = os.Rename(name, path); e != nil {
		return e
	}
	if dir, err := os.Open(filepath.Dir(path)); err == nil {
		dir.Sync()
		dir.Close()
	}
	return nil
}

func (s *Service) Save() (Snapshot, error) {
	s.mu.Lock()
	if s.closed {
		v := s.snapshotLocked()
		s.mu.Unlock()
		return v, nil
	}
	var first error
	for path, f := range s.project.Files {
		if !f.Dirty || f.Conflict != nil {
			continue
		}
		full, e := SafePath(s.project.Root, path)
		if e != nil {
			first = e
			continue
		}
		data, e := os.ReadFile(full)
		if e != nil && !os.IsNotExist(e) {
			first = e
			continue
		}
		if (os.IsNotExist(e) && f.exists) || (e == nil && string(data) != f.base) {
			s.reconcileLocked(path, string(data), os.IsNotExist(e))
			f = s.project.Files[path]
			if f.Conflict != nil {
				first = errors.New("external changes need review")
				continue
			}
		}
		if e = AtomicWrite(full, []byte(f.Text)); e != nil {
			first = e
			continue
		}
		f.base = f.Text
		f.exists = true
		f.Dirty = false
		s.project.Files[path] = f
	}
	s.journalLocked()
	v := s.snapshotLocked()
	s.mu.Unlock()
	s.emit(v)
	return v, first
}

func (s *Service) reconcileLocked(path, disk string, deleted bool) bool {
	f, ok := s.project.Files[path]
	if !ok {
		f = File{Path: path}
	}
	if (!deleted && disk == f.base && f.exists) || (deleted && !f.exists) {
		return false
	}
	if f.Conflict != nil {
		if f.Conflict.Disk == disk && f.Conflict.Deleted == deleted {
			return false
		}
		f.Conflict.Disk = disk
		f.Conflict.Deleted = deleted
		f.Revision++
		s.project.Revision++
		s.project.Files[path] = f
		return true
	}
	if deleted {
		f.Conflict = &Conflict{Base: f.base, Local: f.Text, Disk: disk, Deleted: true}
	} else if merged, ok := Merge(f.base, f.Text, disk); ok {
		s.remapSelectionLocked(path, f.Text, merged, f.Revision+1)
		f.Text = merged
		f.base = disk
		f.exists = true
		f.Dirty = merged != disk
	} else {
		f.Conflict = &Conflict{Base: f.base, Local: f.Text, Disk: disk}
	}
	f.Revision++
	s.project.Files[path] = f
	s.project.Revision++
	s.project.LastOrigin = "external"
	return true
}

func (s *Service) Rescan() Snapshot {
	s.mu.Lock()
	if s.closed {
		v := s.snapshotLocked()
		s.mu.Unlock()
		return v
	}
	changed := s.discoverLocked(true)
	for p := range s.project.Files {
		full, e := SafePath(s.project.Root, p)
		if e != nil {
			continue
		}
		data, e := os.ReadFile(full)
		if e != nil && !os.IsNotExist(e) {
			continue
		}
		if !utf8.Valid(data) {
			continue
		}
		changed = s.reconcileLocked(p, string(data), os.IsNotExist(e)) || changed
	}
	if changed {
		s.journalLocked()
		s.autosaveLocked()
	}
	v := s.snapshotLocked()
	s.mu.Unlock()
	if changed {
		s.emit(v)
	}
	return v
}

// Discover new chapter/data files and invalidate previews for changed binary assets.
func (s *Service) discoverLocked(notify bool) bool {
	if s.project.Root == "" {
		return false
	}
	changed := false
	seen := map[string]bool{}
	filepath.WalkDir(s.project.Root, func(path string, d fs.DirEntry, e error) error {
		if e != nil {
			return nil
		}
		rel, _ := filepath.Rel(s.project.Root, path)
		rel = filepath.ToSlash(rel)
		if d.IsDir() {
			if rel != "." && (strings.HasPrefix(d.Name(), ".") || d.Name() == "node_modules" || d.Name() == "target") {
				return filepath.SkipDir
			}
			return nil
		}
		if d.Type()&os.ModeSymlink != 0 || strings.HasPrefix(d.Name(), ".") {
			return nil
		}
		ext := strings.ToLower(filepath.Ext(path))
		isText := ext == ".typ" || ext == ".bib" || ext == ".yaml" || ext == ".yml" || ext == ".csl" || rel == "writer-references.json"
		if isText {
			if _, ok := s.project.Files[rel]; !ok {
				data, err := os.ReadFile(path)
				if err == nil && utf8.Valid(data) {
					s.project.Files[rel] = File{Path: rel, Text: string(data), base: string(data), exists: true, Revision: 1}
					changed = true
				}
			}
			return nil
		}
		if ext == ".pdf" || ext == ".png" || ext == ".jpg" || ext == ".jpeg" || ext == ".svg" || ext == ".webp" || ext == ".csv" || ext == ".json" || ext == ".toml" {
			st, err := d.Info()
			if err != nil {
				return nil
			}
			stamp := st.ModTime().UnixNano() ^ st.Size()
			seen[rel] = true
			if old, ok := s.assets[rel]; !ok || old != stamp {
				s.assets[rel] = stamp
				changed = true
			}
		}
		return nil
	})
	for p := range s.assets {
		if !seen[p] {
			delete(s.assets, p)
			changed = true
		}
	}
	if changed && notify {
		s.project.Revision++
		s.project.LastOrigin = "external"
	}
	return changed && notify
}
func (s *Service) Resolve(path, text string) (Snapshot, error) {
	if !utf8.ValidString(text) {
		return Snapshot{}, errors.New("invalid UTF-8")
	}
	s.mu.Lock()
	f, ok := s.project.Files[path]
	if !ok || f.Conflict == nil {
		s.mu.Unlock()
		return Snapshot{}, errors.New("no conflict")
	}
	full, e := SafePath(s.project.Root, path)
	if e != nil {
		s.mu.Unlock()
		return Snapshot{}, e
	}
	data, e := os.ReadFile(full)
	if e != nil && !os.IsNotExist(e) {
		s.mu.Unlock()
		return Snapshot{}, e
	}
	if (e == nil && string(data) != f.Conflict.Disk) || (os.IsNotExist(e) != f.Conflict.Deleted) {
		s.mu.Unlock()
		return Snapshot{}, errors.New("disk changed again; rescan before resolving")
	}
	f.base = f.Conflict.Disk
	f.exists = !f.Conflict.Deleted
	f.Conflict = nil
	f.Text = text
	f.Dirty = true
	f.Revision++
	s.project.Files[path] = f
	s.project.Revision++
	s.project.LastOrigin = "resolve"
	s.journalLocked()
	s.autosaveLocked()
	v := s.snapshotLocked()
	s.mu.Unlock()
	s.emit(v)
	return v, nil
}
func (s *Service) SetAgent(enabled bool) Snapshot {
	s.mu.Lock()
	s.project.AgentEnabled = enabled
	v := s.snapshotLocked()
	s.mu.Unlock()
	s.emit(v)
	return v
}
func (s *Service) SetSelection(v Selection) {
	s.mu.Lock()
	defer s.mu.Unlock()
	f, ok := s.project.Files[v.Path]
	if ok && v.Revision == f.Revision && v.Start >= 0 && v.End >= v.Start && v.End <= len(f.Text) {
		s.selection = v
	}
}
func (s *Service) Selection() Selection { s.mu.Lock(); defer s.mu.Unlock(); return s.selection }
func (s *Service) Close() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.closed {
		return
	}
	s.closed = true
	if s.timer != nil {
		s.timer.Stop()
	}
	if s.watcher != nil {
		s.watcher.Close()
	}
	if s.done != nil {
		close(s.done)
		s.done = nil
	}
	s.journalLocked()
}

func (s *Service) journalLocked() {
	if s.journal == "" || s.project.ID == "" {
		return
	}
	type recovered struct {
		Text string `json:"text"`
		Base string `json:"base"`
	}
	entries := map[string]recovered{}
	for p, f := range s.project.Files {
		if f.Dirty || f.Conflict != nil {
			entries[p] = recovered{f.Text, f.base}
		}
	}
	data, _ := json.Marshal(entries)
	if e := AtomicWrite(filepath.Join(s.journal, s.project.ID+".json"), data); e != nil {
		s.fail(e)
	}
}
func (s *Service) restoreLocked() {
	if s.journal == "" {
		return
	}
	data, e := os.ReadFile(filepath.Join(s.journal, s.project.ID+".json"))
	if e != nil {
		return
	}
	var entries map[string]struct {
		Text string
		Base string
	}
	if json.Unmarshal(data, &entries) != nil {
		return
	}
	for p, r := range entries {
		if _, e := SafePath(s.project.Root, p); e != nil {
			continue
		}
		f := s.project.Files[p]
		f.Path = p
		f.Revision++
		if t, ok := Merge(r.Base, r.Text, f.Text); ok {
			f.Text = t
			f.Dirty = t != f.base || !f.exists
		} else {
			f.Conflict = &Conflict{Base: r.Base, Local: r.Text, Disk: f.Text}
			f.Text = r.Text
			f.Dirty = true
		}
		s.project.Files[p] = f
	}
}
func (s *Service) watch(w *fsnotify.Watcher, done chan struct{}) {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-done:
			return
		case _, ok := <-w.Events:
			if !ok {
				return
			}
			s.Rescan()
		case e, ok := <-w.Errors:
			if !ok {
				return
			}
			s.fail(e)
			s.Rescan()
		case <-ticker.C:
			s.Rescan()
		}
	}
}

func (s *Service) remapSelectionLocked(path, before, after string, revision uint64) {
	if s.selection.Path != path {
		return
	}
	edits := changes(before, after)
	point := func(pos int) int {
		delta := 0
		for _, e := range edits {
			if pos < e.start {
				break
			}
			if pos <= e.end {
				return e.start + delta + len(e.text)
			}
			delta += len(e.text) - (e.end - e.start)
		}
		return pos + delta
	}
	s.selection.Start = point(s.selection.Start)
	s.selection.End = point(s.selection.End)
	s.selection.Revision = revision
}
