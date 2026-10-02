package document

import (
	"errors"
	"os"
	"strings"
	"time"
)

type FileInformation struct {
	Created   *time.Time `json:"created"`
	LastSaved *time.Time `json:"lastSaved"`
	Bytes     int        `json:"bytes"`
	Dirty     bool       `json:"dirty"`
	Missing   bool       `json:"missing"`
}
type Information struct {
	ProjectID string                     `json:"projectId"`
	Revision  uint64                     `json:"revision"`
	Files     map[string]FileInformation `json:"files"`
}

// Read disk timestamps while holding the same lock as atomic saves. Unsaved
// text contributes to size, while LastSaved always describes content on disk.
func (s *Service) Information() (Information, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.project.ID == "" {
		return Information{}, errors.New("open a document first")
	}
	result := Information{ProjectID: s.project.ID, Revision: s.project.Revision, Files: map[string]FileInformation{}}
	for path, file := range s.project.Files {
		if !strings.HasSuffix(path, ".typ") {
			continue
		}
		full, err := SafePath(s.project.Root, path)
		if err != nil {
			return Information{}, err
		}
		info := FileInformation{Bytes: len(file.Text), Dirty: file.Dirty}
		stat, err := os.Stat(full)
		if os.IsNotExist(err) {
			info.Missing = true
		} else if err != nil {
			return Information{}, err
		} else {
			modified := stat.ModTime()
			info.LastSaved = &modified
			info.Created = creationTime(stat)
		}
		result.Files[path] = info
	}
	return result, nil
}
