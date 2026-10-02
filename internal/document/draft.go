package document

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// SaveDraftAs promotes an app-managed recovery copy to ordinary user files.
// Preflight every destination; never overwrite an existing document or asset.
func (s *Service) SaveDraftAs(destination string) (Snapshot, error) {
	s.mu.Lock()
	if s.closed || !s.project.Unsaved {
		s.mu.Unlock()
		return Snapshot{}, errors.New("this document is already saved")
	}
	fail := func(err error) (Snapshot, error) { s.mu.Unlock(); return Snapshot{}, err }
	if !strings.EqualFold(filepath.Ext(destination), ".typ") {
		return fail(errors.New("choose a filename ending in .typ"))
	}
	full, err := filepath.Abs(destination)
	if err != nil {
		return fail(err)
	}
	root, entry := filepath.Dir(full), filepath.Base(full)
	if err = os.MkdirAll(root, 0700); err != nil {
		return fail(err)
	}
	root, err = filepath.EvalSymlinks(root)
	if err != nil {
		return fail(err)
	}
	if root == s.project.Root {
		return fail(errors.New("choose a location outside the temporary draft"))
	}
	old := s.snapshotLocked()
	contents := map[string][]byte{}
	assets := map[string]string{}
	err = filepath.WalkDir(old.Root, func(path string, item fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		rel, e := filepath.Rel(old.Root, path)
		if e != nil {
			return e
		}
		if item.IsDir() {
			if rel != "." && strings.HasPrefix(item.Name(), ".") {
				return filepath.SkipDir
			}
			return nil
		}
		if strings.HasPrefix(item.Name(), ".") || rel == "writer.json" {
			return nil
		}
		if item.Type()&os.ModeSymlink != 0 {
			return fmt.Errorf("cannot save a linked asset: %s", rel)
		}
		key := filepath.ToSlash(rel)
		contents[key] = nil
		assets[key] = path
		return nil
	})
	if err != nil {
		return fail(err)
	}
	for path, file := range old.Files {
		if file.Conflict != nil {
			return fail(errors.New("resolve external changes before saving"))
		}
		contents[path] = []byte(file.Text)
	}
	data := contents[old.Entry]
	delete(contents, old.Entry)
	if _, exists := contents[entry]; exists {
		return fail(errors.New("that name is already used by another project file"))
	}
	contents[entry] = data
	paths := make([]string, 0, len(contents))
	for path := range contents {
		target, e := SafePath(root, path)
		if e != nil {
			return fail(e)
		}
		if _, e = os.Lstat(target); !os.IsNotExist(e) {
			if e == nil {
				e = fmt.Errorf("%s already exists; choose another filename or an empty folder", path)
			}
			return fail(e)
		}
		paths = append(paths, path)
	}
	// Dependencies first, entrypoint last, so a completed document is usable.
	sort.Slice(paths, func(i, j int) bool {
		if paths[i] == entry {
			return false
		}
		if paths[j] == entry {
			return true
		}
		return paths[i] < paths[j]
	})
	for _, path := range paths {
		target, e := SafePath(root, path)
		if e != nil {
			return fail(e)
		}
		if e = os.MkdirAll(filepath.Dir(target), 0700); e != nil {
			return fail(e)
		}
		file, e := os.OpenFile(target, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
		if e != nil {
			return fail(e)
		}
		if data := contents[path]; data != nil {
			_, e = file.Write(data)
		} else {
			// Stream media instead of retaining every image in RAM during a save.
			var source *os.File
			source, e = os.Open(assets[path])
			if e == nil {
				_, e = io.Copy(file, source)
				source.Close()
			}
		}
		if e == nil {
			e = file.Sync()
		}
		closeErr := file.Close()
		if e != nil {
			return fail(e)
		}
		if closeErr != nil {
			return fail(closeErr)
		}
	}
	history, redo, selection := s.history, s.redo, s.selection
	// Freeze edits during the switch; stale callers cannot write the old draft.
	s.closed = true
	s.mu.Unlock()
	_, err = s.Open(filepath.Join(root, entry))
	s.mu.Lock()
	if err != nil {
		s.closed = false
		s.mu.Unlock()
		return Snapshot{}, err
	}
	rename := func(values map[string]string) {
		if value, ok := values[old.Entry]; ok {
			delete(values, old.Entry)
			values[entry] = value
		}
	}
	for _, list := range [][]historyEntry{history, redo} {
		for i := range list {
			rename(list[i].Before)
			rename(list[i].After)
		}
	}
	s.history, s.redo = history, redo
	for path, previous := range old.Files {
		if path == old.Entry {
			path = entry
		}
		file := s.project.Files[path]
		file.Revision = previous.Revision
		s.project.Files[path] = file
	}
	if selection.Path == old.Entry {
		selection.Path = entry
	}
	s.selection = selection
	s.project.Revision = old.Revision + 1
	s.project.LastOrigin = "save-as"
	result := s.snapshotLocked()
	s.mu.Unlock()
	s.emit(result)
	return result, nil
}
