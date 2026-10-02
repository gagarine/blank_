package engine

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestRestartAndConcurrentParse(t *testing.T) {
	binary, _ := filepath.Abs("../../helper/target/release/writer-helper")
	if _, e := os.Stat(binary); e != nil {
		t.Skip("build helper first")
	}
	h := New(binary)
	defer h.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	var parsed map[string]any
	if e := h.Call(ctx, "parse", map[string]any{"path": "test", "text": "Hello é🌱", "revision": 1}, &parsed); e != nil {
		t.Fatal(e)
	}
	h.Close()
	deadline := time.Now().Add(2 * time.Second)
	for {
		h.mu.Lock()
		stopped := h.cmd == nil
		h.mu.Unlock()
		if stopped {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("helper did not stop")
		}
		time.Sleep(time.Millisecond)
	}
	if e := h.Call(ctx, "parse", map[string]any{"path": "test", "text": "Hello again", "revision": 2}, &parsed); e != nil {
		t.Fatal(e)
	}
	if parsed["revision"] != float64(2) {
		t.Fatal(parsed)
	}
	root := t.TempDir()
	done := make(chan error, 1)
	go func() {
		var out any
		done <- h.Call(ctx, "compile", map[string]any{"root": root, "entry": "main.typ", "files": map[string]string{"main.typ": "#lorem(30000)"}, "revision": 3}, &out)
	}()
	if e := h.Call(ctx, "parse", map[string]any{"path": "test", "text": "Parser remains responsive", "revision": 3}, &parsed); e != nil {
		t.Fatal(e)
	}
	if e := <-done; e != nil {
		t.Fatal(e)
	}
}
