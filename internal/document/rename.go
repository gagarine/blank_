package document

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
)

// RenameEntry keeps the project and its relative dependencies in the same folder.
// It refuses collisions and retains the shared undo/redo history.
func (s *Service) RenameEntry(projectID, name string) (Snapshot, error) {
	if name == "" || name == "." || name == ".." || strings.ContainsAny(name, "/\\\x00") {
		return Snapshot{}, errors.New("choose a filename, without folders")
	}
	if !strings.EqualFold(filepath.Ext(name), ".typ") {
		name += ".typ"
	}
	if _, err := s.Save(); err != nil {
		return Snapshot{}, err
	}
	s.mu.Lock()
	fail := func(err error) (Snapshot, error) { s.mu.Unlock(); return Snapshot{}, err }
	if s.closed || s.project.ID != projectID {
		return fail(errors.New("the document changed; reopen its name menu"))
	}
	if s.project.Unsaved {
		return fail(errors.New("choose a save location first"))
	}
	old := s.project.Entry
	next := filepath.ToSlash(filepath.Join(filepath.Dir(old), name))
	if old == next {
		v := s.snapshotLocked()
		s.mu.Unlock()
		return v, nil
	}
	f := s.project.Files[old]
	if f.Conflict != nil {
		return fail(errors.New("resolve external changes before renaming"))
	}
	from, err := SafePath(s.project.Root, old)
	if err != nil {
		return fail(err)
	}
	to, err := SafePath(s.project.Root, next)
	if err != nil {
		return fail(err)
	}
	disk, err := os.ReadFile(from)
	if err != nil {
		return fail(err)
	}
	if string(disk) != f.base {
		return fail(errors.New("the file changed on disk; try again after it reloads"))
	}
	// Linking is exclusive, unlike os.Rename, which can overwrite a racing writer.
	if err = os.Link(from, to); err != nil {
		return fail(err)
	}
	configPath := filepath.Join(s.project.Root, "writer.json")
	config, configErr := os.ReadFile(configPath)
	changedConfig := false
	if configErr == nil {
		var settings map[string]json.RawMessage
		if err = json.Unmarshal(config, &settings); err != nil {
			os.Remove(to)
			return fail(err)
		}
		var entry string
		json.Unmarshal(settings["entry"], &entry)
		if filepath.ToSlash(filepath.Clean(entry)) == old {
			settings["entry"], _ = json.Marshal(next)
			updated, _ := json.MarshalIndent(settings, "", "  ")
			if err = AtomicWrite(configPath, append(updated, '\n')); err != nil {
				os.Remove(to)
				return fail(err)
			}
			changedConfig = true
		}
	} else if !os.IsNotExist(configErr) {
		os.Remove(to)
		return fail(configErr)
	}
	if err = os.Remove(from); err != nil {
		os.Remove(to)
		if changedConfig {
			AtomicWrite(configPath, config)
		}
		return fail(err)
	}
	delete(s.project.Files, old)
	f.Path, f.Revision = next, f.Revision+1
	s.project.Files[next] = f
	s.project.Entry = next
	hash := sha256.Sum256([]byte(s.project.Root + "\x00" + next))
	s.project.ID = hex.EncodeToString(hash[:12])
	s.project.Revision++
	s.project.LastOrigin = "rename"
	for _, list := range [][]historyEntry{s.history, s.redo} {
		for i := range list {
			for _, values := range []map[string]string{list[i].Before, list[i].After} {
				if value, ok := values[old]; ok {
					delete(values, old)
					values[next] = value
				}
			}
		}
	}
	if s.selection.Path == old {
		s.selection.Path = next
		s.selection.Revision = f.Revision
	}
	s.journalLocked()
	v := s.snapshotLocked()
	s.mu.Unlock()
	s.emit(v)
	return v, nil
}
