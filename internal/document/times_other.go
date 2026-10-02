//go:build !darwin

package document

import (
	"os"
	"time"
)

func creationTime(os.FileInfo) *time.Time      { return nil }
func preserveCreationTime(string, os.FileInfo) {}
