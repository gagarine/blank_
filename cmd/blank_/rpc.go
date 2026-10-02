package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"time"

	"golang.org/x/sys/unix"
)

type rpcRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params"`
}

func rpcResult(id json.RawMessage, result any, err error) []byte {
	v := map[string]any{"jsonrpc": "2.0", "id": id}
	if err != nil {
		v["error"] = map[string]any{"code": -32000, "message": err.Error()}
	} else {
		v["result"] = result
	}
	data, _ := json.Marshal(v)
	return append(data, '\n')
}
func socketPath() string {
	if p := os.Getenv("WRITER_SOCKET"); p != "" {
		return p
	}
	return defaultSocketPath()
}
func defaultSocketPath() string {
	return filepath.Join(os.TempDir(), fmt.Sprintf("still-writer-%d", os.Getuid()), "rpc.sock")
}

var windowSocketSequence atomic.Uint64

// Serialize socket allocation across app instances so a new window cannot
// unlink another window's freshly bound endpoint during simultaneous startup.
func listenWindowSocket(path string, fallback bool) (net.Listener, string, error) {
	lock, err := os.OpenFile(filepath.Join(filepath.Dir(path), ".startup.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, "", err
	}
	defer lock.Close()
	if err := unix.Flock(int(lock.Fd()), unix.LOCK_EX); err != nil {
		return nil, "", err
	}
	defer unix.Flock(int(lock.Fd()), unix.LOCK_UN)
	for {
		c, err := net.DialTimeout("unix", path, 300*time.Millisecond)
		if err != nil {
			break
		}
		c.Close()
		if !fallback {
			return nil, "", errors.New("the configured agent socket is already in use")
		}
		path = filepath.Join(filepath.Dir(path), fmt.Sprintf("window-%d-%d.sock", os.Getpid(), windowSocketSequence.Add(1)))
	}

	if stat, err := os.Lstat(path); err == nil {
		if stat.Mode()&os.ModeSocket == 0 {
			return nil, "", errors.New("agent socket path is occupied by a file")
		}
		if err := os.Remove(path); err != nil {
			return nil, "", err
		}
	}
	listener, err := net.Listen("unix", path)
	return listener, path, err
}

func (a *App) serveSocket() {
	a.rpcMu.Lock()
	if a.rpcClosed {
		a.rpcMu.Unlock()
		return
	}
	path := a.rpcRequestedPath
	if path == "" {
		path = socketPath()
	}
	if e := os.MkdirAll(filepath.Dir(path), 0700); e != nil {
		a.rpcMu.Unlock()
		a.emit("error", e.Error())
		return
	}
	if os.Getenv("WRITER_SOCKET") == "" {
		os.Chmod(filepath.Dir(path), 0700)
	}
	l, path, e := listenWindowSocket(path, a.rpcRequestedPath != "" || os.Getenv("WRITER_SOCKET") == "")
	if e != nil {
		a.rpcMu.Unlock()
		a.emit("error", e.Error())
		return
	}
	a.rpcListener, a.rpcPath = l, path
	os.Chmod(path, 0600)
	a.rpcMu.Unlock()
	for {
		conn, e := l.Accept()
		if e != nil {
			return
		}
		go func() {
			defer conn.Close()
			conn.SetDeadline(time.Now().Add(120 * time.Second))
			scanner := bufio.NewScanner(conn)
			scanner.Buffer(make([]byte, 65536), 16*1024*1024)
			if !scanner.Scan() {
				return
			}
			var req rpcRequest
			if e := json.Unmarshal(scanner.Bytes(), &req); e != nil {
				conn.Write(rpcResult(nil, nil, e))
				return
			}
			if len(req.Params) == 0 {
				req.Params = []byte("{}")
			}
			v, e := a.dispatch(req.Method, req.Params, true)
			conn.Write(rpcResult(req.ID, v, e))
		}()
	}
}
func (a *App) closeSocket() {
	a.rpcMu.Lock()
	defer a.rpcMu.Unlock()
	a.rpcClosed = true
	if a.rpcListener != nil {
		a.rpcListener.Close()
		os.Remove(a.rpcPath)
	}
}

func (a *App) serveDev() error {
	if a.demo {
		if _, e := a.openDemo(); e != nil {
			return e
		}
	} else if a.initial != "" {
		if _, e := a.docs.Open(a.initial); e != nil {
			return e
		}
	}
	go a.serveSocket()
	defer a.shutdown(context.Background())
	mux := http.NewServeMux()
	mux.HandleFunc("/api", func(w http.ResponseWriter, r *http.Request) {
		if !allowDev(w, r) {
			return
		}
		if r.Method == "OPTIONS" {
			return
		}
		if r.Method != "POST" {
			http.Error(w, "POST required", 405)
			return
		}
		var req rpcRequest
		if e := json.NewDecoder(io.LimitReader(r.Body, 16<<20)).Decode(&req); e != nil {
			http.Error(w, e.Error(), 400)
			return
		}
		v, e := a.dispatch(req.Method, req.Params, false)
		w.Header().Set("Content-Type", "application/json")
		w.Write(rpcResult(req.ID, v, e))
	})
	mux.HandleFunc("/events", func(w http.ResponseWriter, r *http.Request) {
		if !allowDev(w, r) {
			return
		}
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Cache-Control", "no-cache")
		ch := make(chan []byte, 8)
		a.mu.Lock()
		a.subs[ch] = true
		a.mu.Unlock()
		defer func() { a.mu.Lock(); delete(a.subs, ch); a.mu.Unlock() }()
		fmt.Fprint(w, ": connected\n\n")
		w.(http.Flusher).Flush()
		for {
			select {
			case <-r.Context().Done():
				return
			case data := <-ch:
				fmt.Fprintf(w, "data: %s\n\n", data)
				w.(http.Flusher).Flush()
			}
		}
	})
	sub, e := fs.Sub(assets, "dist")
	if e != nil {
		return e
	}
	mux.Handle("/", http.FileServer(http.FS(sub)))
	fmt.Println("blank_ development server: http://127.0.0.1:3415")
	return (&http.Server{Addr: "127.0.0.1:3415", Handler: mux, ReadHeaderTimeout: 5 * time.Second}).ListenAndServe()
}
func allowDev(w http.ResponseWriter, r *http.Request) bool {
	origin := r.Header.Get("Origin")
	if origin != "" && origin != "http://127.0.0.1:5173" && origin != "http://localhost:5173" && origin != "http://127.0.0.1:3415" {
		http.Error(w, "origin denied", 403)
		return false
	}
	if origin != "" {
		w.Header().Set("Access-Control-Allow-Origin", origin)
	}
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
	w.Header().Set("Access-Control-Allow-Methods", "POST, GET, OPTIONS")
	return true
}

type toolDef struct {
	Name        string         `json:"name"`
	Description string         `json:"description"`
	InputSchema map[string]any `json:"inputSchema"`
	Annotations map[string]any `json:"annotations"`
}

func schema(properties map[string]any, required ...string) map[string]any {
	v := map[string]any{"type": "object", "properties": properties, "additionalProperties": false}
	if len(required) > 0 {
		v["required"] = required
	}
	return v
}
func property(kind string) map[string]any { return map[string]any{"type": kind} }
func toolList() []toolDef {
	empty := schema(map[string]any{})
	tools := []toolDef{}
	add := func(name, desc string, input map[string]any, read bool) {
		tools = append(tools, toolDef{name, desc, input, map[string]any{"readOnlyHint": read, "openWorldHint": false, "destructiveHint": !read}})
	}
	add("project_read", "Read the enabled project's source files and revisions. Read before editing.", empty, true)
	add("project_outline", "Read headings and source locations.", empty, true)
	add("context_selection", "Read the current source selection and its revision.", empty, true)
	add("document_applyEdits", "Apply one undoable transaction. UTF-8 byte ranges are half-open; expected revisions are mandatory for all files. Stale edits are rejected.", schema(map[string]any{"projectId": property("string"), "expected": map[string]any{"type": "object", "additionalProperties": map[string]any{"type": "integer", "minimum": 0}}, "edits": map[string]any{"type": "array", "items": schema(map[string]any{"path": property("string"), "start": property("integer"), "end": property("integer"), "text": property("string")}, "path", "start", "end", "text")}}, "projectId", "expected", "edits"), false)
	add("document_undo", "Undo the latest agent transaction while retaining disjoint later edits.", empty, false)
	add("zotero_search", "Search local Zotero title, creator and year. Library is personal or groups/NUMBER.", schema(map[string]any{"query": property("string"), "library": property("string")}, "query"), true)
	add("citation_insert", "Insert selected Zotero results at a revision-checked source range and save their bibliography entries.", schema(map[string]any{"projectId": property("string"), "path": property("string"), "start": property("integer"), "end": property("integer"), "revision": property("integer"), "items": map[string]any{"type": "array", "items": map[string]any{"type": "object"}}, "locator": property("string"), "form": property("string")}, "projectId", "path", "start", "end", "revision", "items"), false)
	add("diagnostics_list", "Read the latest Typst compilation diagnostics.", empty, true)
	add("preview_compile", "Compile the current document revision and return diagnostics (without PDF bytes).", empty, true)
	add("preview_exportPDF", "Export a successful current revision to a project-relative PDF path.", schema(map[string]any{"path": property("string")}, "path"), false)
	return tools
}

func callSocket(method string, args json.RawMessage) (json.RawMessage, error) {
	conn, e := net.DialTimeout("unix", socketPath(), time.Second)
	if e != nil {
		return nil, errors.New("app_unavailable: open blank_ and enable agent access for the project")
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(120 * time.Second))
	data, _ := json.Marshal(rpcRequest{JSONRPC: "2.0", ID: []byte("1"), Method: method, Params: args})
	conn.Write(append(data, '\n'))
	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 65536), 128<<20)
	if !scanner.Scan() {
		return nil, errors.New("writer connection closed")
	}
	var res struct {
		Result json.RawMessage
		Error  *struct{ Message string }
	}
	if e = json.Unmarshal(scanner.Bytes(), &res); e != nil {
		return nil, e
	}
	if res.Error != nil {
		return nil, errors.New(res.Error.Message)
	}
	return res.Result, nil
}

func runMCP() error {
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 65536), 16<<20)
	for scanner.Scan() {
		var req rpcRequest
		if e := json.Unmarshal(scanner.Bytes(), &req); e != nil {
			os.Stdout.Write(rpcResult(nil, nil, e))
			continue
		}
		if len(req.ID) == 0 {
			continue
		}
		var result any
		var err error
		switch req.Method {
		case "initialize":
			result = map[string]any{"protocolVersion": "2025-06-18", "capabilities": map[string]any{"tools": map[string]any{}}, "serverInfo": map[string]any{"name": "blank_", "version": "0.1.0"}, "instructions": "Read project_read before editing. Source offsets are UTF-8 bytes. Apply small revision-checked transactions. Only the enabled project is accessible. Edits appear live and can be undone."}
		case "ping":
			result = map[string]any{}
		case "tools/list":
			result = map[string]any{"tools": toolList()}
		case "tools/call":
			var p struct {
				Name      string
				Arguments json.RawMessage
			}
			err = json.Unmarshal(req.Params, &p)
			if err == nil {
				known := false
				for _, t := range toolList() {
					if t.Name == p.Name {
						known = true
					}
				}
				if !known {
					err = errors.New("unknown tool")
				} else {
					if len(p.Arguments) == 0 {
						p.Arguments = []byte("{}")
					}
					method := strings.Replace(p.Name, "_", ".", 1)
					if p.Name == "document_undo" {
						p.Arguments = []byte(`{"origin":"agent"}`)
					}
					var raw json.RawMessage
					raw, err = callSocket(method, p.Arguments)
					if err == nil {
						if p.Name == "preview_compile" {
							var v map[string]any
							json.Unmarshal(raw, &v)
							delete(v, "pdf")
							delete(v, "previousPdf")
							raw, _ = json.Marshal(v)
						}
						result = map[string]any{"content": []any{map[string]any{"type": "text", "text": string(raw)}}}
					}
				}
			}
			if err != nil {
				result = map[string]any{"isError": true, "content": []any{map[string]any{"type": "text", "text": err.Error()}}}
				err = nil
			}
		default:
			err = fmt.Errorf("unsupported MCP method %s", req.Method)
		}
		if _, e := io.Copy(os.Stdout, bytes.NewReader(rpcResult(req.ID, result, err))); e != nil {
			return e
		}
	}
	return scanner.Err()
}
