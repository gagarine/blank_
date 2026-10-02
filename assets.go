package main

import (
	"bytes"
	"encoding/base64"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"writer/internal/document"
)

const maxAssetBytes = 32 * 1024 * 1024

func figureMIME(name string, data []byte) (string, error) {
	ext := strings.ToLower(filepath.Ext(name))
	mime := http.DetectContentType(data)
	if ext == ".svg" {
		d := xml.NewDecoder(bytes.NewReader(data))
		for {
			token, e := d.Token()
			if e != nil {
				break
			}
			if element, ok := token.(xml.StartElement); ok {
				if element.Name.Local == "svg" {
					return "image/svg+xml", nil
				}
				break
			}
		}
		return "", errors.New("invalid SVG")
	}
	allowed := map[string]string{".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif", ".webp": "image/webp", ".pdf": "application/pdf"}
	if want, ok := allowed[ext]; !ok || want != mime {
		return "", errors.New("choose a PNG, JPEG, GIF, WebP, SVG, or PDF figure")
	}
	return mime, nil
}
func (a *App) importAsset(name string, data []byte) (string, error) {
	if len(data) == 0 || len(data) > maxAssetBytes {
		return "", errors.New("figures must be between 1 byte and 32 MB")
	}
	name = filepath.Base(name)
	if _, e := figureMIME(name, data); e != nil {
		return "", e
	}
	s := a.docs.Snapshot()
	if s.ID == "" {
		return "", errors.New("open a project first")
	}
	a.assetMu.Lock()
	defer a.assetMu.Unlock()
	ext := filepath.Ext(name)
	stem := strings.TrimSuffix(name, ext)
	for i := 0; i < 10000; i++ {
		candidate := name
		if i > 0 {
			candidate = fmt.Sprintf("%s-%d%s", stem, i, ext)
		}
		rel := filepath.ToSlash(filepath.Join("assets", candidate))
		full, e := document.SafePath(s.Root, rel)
		if e != nil {
			return "", e
		}
		if existing, e := os.ReadFile(full); e == nil {
			if bytes.Equal(existing, data) {
				return rel, nil
			}
			continue
		} else if !os.IsNotExist(e) {
			return "", e
		}
		if e = document.AtomicWrite(full, data); e != nil {
			return "", e
		}
		a.docs.Rescan()
		return rel, nil
	}
	return "", errors.New("too many files with the same name")
}
func (a *App) importAssetPath(path string) (string, error) {
	f, e := os.Open(path)
	if e != nil {
		return "", e
	}
	defer f.Close()
	data, e := io.ReadAll(io.LimitReader(f, maxAssetBytes+1))
	if e != nil {
		return "", e
	}
	return a.importAsset(filepath.Base(path), data)
}
func (a *App) readAsset(path string) (any, error) {
	full, e := document.SafePath(a.docs.Snapshot().Root, path)
	if e != nil {
		return nil, e
	}
	f, e := os.Open(full)
	if e != nil {
		return nil, e
	}
	defer f.Close()
	data, e := io.ReadAll(io.LimitReader(f, maxAssetBytes+1))
	if e != nil {
		return nil, e
	}
	if len(data) > maxAssetBytes {
		return nil, errors.New("figure preview exceeds 32 MB")
	}
	mime, e := figureMIME(path, data)
	if e != nil {
		return nil, e
	}
	return map[string]any{"mime": mime, "data": base64.StdEncoding.EncodeToString(data)}, nil
}
