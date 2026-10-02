package engine

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"sync/atomic"
)

type response struct {
	ID     uint64          `json:"id"`
	Result json.RawMessage `json:"result"`
	Error  *struct {
		Message string `json:"message"`
	} `json:"error"`
}
type Helper struct {
	mu      sync.Mutex
	path    string
	cmd     *exec.Cmd
	in      io.WriteCloser
	pending map[uint64]chan response
	seq     atomic.Uint64
}

func New(path string) *Helper { return &Helper{path: path, pending: map[uint64]chan response{}} }
func Find() string {
	if p := os.Getenv("WRITER_HELPER"); p != "" {
		return p
	}
	exe, _ := os.Executable()
	for _, p := range []string{filepath.Join(filepath.Dir(exe), "writer-helper"), "build/helpers/writer-helper", "helper/target/release/writer-helper", "helper/target/debug/writer-helper"} {
		if st, e := os.Stat(p); e == nil && !st.IsDir() {
			abs, _ := filepath.Abs(p)
			return abs
		}
	}
	return "writer-helper"
}
func (h *Helper) startLocked() error {
	if h.cmd != nil {
		return nil
	}
	cmd := exec.Command(h.path)
	in, e := cmd.StdinPipe()
	if e != nil {
		return e
	}
	out, e := cmd.StdoutPipe()
	if e != nil {
		return e
	}
	cmd.Stderr = os.Stderr
	if e = cmd.Start(); e != nil {
		return fmt.Errorf("Typst helper unavailable: %w", e)
	}
	h.cmd = cmd
	h.in = in
	go func() {
		scanner := bufio.NewScanner(out)
		scanner.Buffer(make([]byte, 65536), 128*1024*1024)
		for scanner.Scan() {
			var r response
			if json.Unmarshal(scanner.Bytes(), &r) != nil {
				continue
			}
			h.mu.Lock()
			ch := h.pending[r.ID]
			delete(h.pending, r.ID)
			h.mu.Unlock()
			if ch != nil {
				ch <- r
			}
		}
		cmd.Wait()
		h.mu.Lock()
		if h.cmd == cmd {
			h.cmd = nil
			for id, ch := range h.pending {
				close(ch)
				delete(h.pending, id)
			}
		}
		h.mu.Unlock()
	}()
	return nil
}
func (h *Helper) Call(ctx context.Context, method string, params any, result any) error {
	return h.call(ctx, method, params, result, true)
}
func (h *Helper) call(ctx context.Context, method string, params any, result any, retry bool) error {
	id := h.seq.Add(1)
	data, e := json.Marshal(map[string]any{"jsonrpc": "2.0", "protocolVersion": 1, "id": id, "method": method, "params": params})
	if e != nil {
		return e
	}
	ch := make(chan response, 1)
	h.mu.Lock()
	if e = h.startLocked(); e != nil {
		h.mu.Unlock()
		return e
	}
	h.pending[id] = ch
	_, e = h.in.Write(append(data, '\n'))
	h.mu.Unlock()
	if e != nil {
		h.mu.Lock()
		delete(h.pending, id)
		h.mu.Unlock()
		return e
	}
	select {
	case r, ok := <-ch:
		if !ok {
			if retry && ctx.Err() == nil {
				return h.call(ctx, method, params, result, false)
			}
			return errors.New("Typst helper stopped; retry the operation")
		}
		if r.Error != nil {
			return errors.New(r.Error.Message)
		}
		return json.Unmarshal(r.Result, result)
	case <-ctx.Done():
		h.mu.Lock()
		delete(h.pending, id)
		h.mu.Unlock()
		return ctx.Err()
	}
}
func (h *Helper) Close() {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.cmd != nil {
		h.cmd.Process.Kill()
	}
}
