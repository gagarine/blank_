package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
)

func createEmptyDocument(path string) error {
	if !strings.EqualFold(filepath.Ext(path), ".typ") {
		return errors.New("choose a filename ending in .typ")
	}
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	if _, err = file.WriteString("\n"); err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	if err != nil {
		return err
	}
	return closeErr
}
