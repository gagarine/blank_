package main

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/wailsapp/wails/v3/pkg/application"
	"github.com/wailsapp/wails/v3/pkg/events"
)

// Desktop owns the application, not a document. Only this router is bound to
// JavaScript; Wails supplies the calling window in its trusted call context.
// Each window retains its own buffers, history, preview and agent endpoint.
type Desktop struct {
	app      *application.App
	mu       sync.RWMutex
	opening  sync.Mutex
	sessions map[uint]*App
}

var desktop *Desktop

func runDesktop(first *App) error {
	d := &Desktop{sessions: make(map[uint]*App)}
	desktop = d
	content, err := fs.Sub(assets, "dist")
	if err != nil {
		return err
	}
	d.app = application.New(application.Options{
		Name:       "blank_",
		Services:   []application.Service{application.NewService(d)},
		Assets:     application.AssetOptions{Handler: application.BundledAssetFileServer(content), DisableLogging: true},
		Mac:        application.MacOptions{ApplicationShouldTerminateAfterLastWindowClosed: false},
		OnShutdown: d.shutdown,
		ShouldQuit: d.saveAll,
		SingleInstance: &application.SingleInstanceOptions{
			UniqueID:               applicationID(),
			OnSecondInstanceLaunch: d.reopen,
		},
	})
	d.app.Menu.Set(d.applicationMenu())
	d.app.Event.OnApplicationEvent(events.Common.ApplicationOpenedWithFile, func(e *application.ApplicationEvent) {
		if path := e.Context().Filename(); path != "" {
			d.report(d.openWindow(path, false))
		}
	})
	d.app.Event.OnApplicationEvent(events.Mac.ApplicationShouldHandleReopen, func(*application.ApplicationEvent) {
		if len(d.all()) == 0 {
			d.report(d.openWindow("", false))
		}
	})
	if err := d.addWindow(first); err != nil {
		first.shutdown(context.Background())
		return err
	}
	return d.app.Run()
}

func (d *Desktop) session(id uint) (*App, error) {
	d.mu.RLock()
	defer d.mu.RUnlock()
	a := d.sessions[id]
	if a == nil {
		return nil, errors.New("document window is closed")
	}
	return a, nil
}

func (d *Desktop) all() []*App {
	d.mu.RLock()
	defer d.mu.RUnlock()
	result := make([]*App, 0, len(d.sessions))
	for _, a := range d.sessions {
		result = append(result, a)
	}
	return result
}

func (d *Desktop) Call(ctx context.Context, method, params string) (string, error) {
	window, ok := ctx.Value(application.WindowKey).(application.Window)
	if !ok || window == nil {
		return "", errors.New("missing document window")
	}
	return d.callWindow(window.ID(), method, params)
}

func (d *Desktop) callWindow(id uint, method, params string) (string, error) {
	a, err := d.session(id)
	if err != nil {
		return "", err
	}
	return a.Call(method, params)
}

func (d *Desktop) current() *App {
	window := d.app.Window.Current()
	if window == nil {
		return nil
	}
	a, _ := d.session(window.ID())
	return a
}

func (d *Desktop) openWindow(path string, demo bool) error {
	return d.openWindowWithOptions(path, demo, false)
}

func (d *Desktop) newDocumentWindow() error {
	return d.openWindowWithOptions("", false, true)
}

func (d *Desktop) openWindowWithOptions(path string, demo, blank bool) error {
	d.opening.Lock()
	defer d.opening.Unlock()
	// Reopening an already open document raises its existing window.
	if path != "" {
		full, err := filepath.Abs(path)
		if err != nil {
			return err
		}
		full = filepath.Clean(full)
		if real, err := filepath.EvalSymlinks(full); err == nil {
			full = real
		}
		for _, a := range d.all() {
			s := a.docs.Snapshot()
			if full == filepath.Join(s.Root, s.Entry) || full == s.Root {
				a.window.Show()
				a.window.Focus()
				return nil
			}
		}
	}
	// Home has no document to replace. Reuse it for an explicit open/new/help
	// action; populated document windows retain their own sessions.
	if path != "" || demo || blank {
		for _, home := range d.all() {
			if !home.lifecycle.TryRLock() {
				continue
			}
			if home.closed || home.docs.Snapshot().ID != "" {
				home.lifecycle.RUnlock()
				continue
			}
			var err error
			if blank {
				_, err = home.openBlankDraft()
			} else if demo {
				_, err = home.openDemo()
			} else {
				_, err = home.open(path)
			}
			if err == nil {
				home.window.Show()
				home.window.Focus()
			}
			home.lifecycle.RUnlock()
			return err
		}
	}
	a := NewApp(path)
	a.demo = demo
	if blank {
		if _, err := a.openBlankDraft(); err != nil {
			a.shutdown(context.Background())
			return err
		}
	}
	// Explicit WRITER_SOCKET belongs to the first session only. Additional
	// windows get independent endpoints in the usual user-only socket directory.
	a.rpcRequestedPath = defaultSocketPath()
	if err := d.addWindow(a); err != nil {
		a.shutdown(context.Background())
		return err
	}
	return nil
}

func (d *Desktop) addWindow(a *App) error {
	if a.demo {
		if _, err := a.openDemo(); err != nil {
			return err
		}
	} else if a.initial != "" {
		if _, err := a.open(a.initial); err != nil {
			return err
		}
	}
	a.desktop = d
	a.native = true
	// Register under the same lock used by the binding router before any
	// newly loaded webview can dispatch its first call.
	d.mu.Lock()
	w := d.app.Window.NewWithOptions(application.WebviewWindowOptions{
		Title: "blank_", Width: 1280, Height: 860, MinWidth: 800, MinHeight: 550,
		URL: "wails://wails/", BackgroundColour: application.NewRGB(255, 255, 255), EnableFileDrop: true,
		Mac: application.MacWindow{TitleBar: application.MacTitleBarHiddenInset, TabbingMode: application.MacWindowTabbingModeDisallowed},
	})
	a.mu.Lock()
	a.window = w
	a.mu.Unlock()
	d.sessions[w.ID()] = a
	d.mu.Unlock()
	w.RegisterHook(events.Common.WindowClosing, func(e *application.WindowEvent) {
		if _, err := a.docs.Save(); err != nil {
			a.emit("error", err.Error())
			e.Cancel()
			return
		}
		d.closeWindow(w.ID())
	})
	w.OnWindowEvent(events.Common.WindowFilesDropped, func(e *application.WindowEvent) {
		target := e.Context().DropTargetDetails()
		if target == nil {
			return
		}
		a.emit("filesDropped", map[string]any{"x": target.X, "y": target.Y, "paths": e.Context().DroppedFiles()})
	})
	go a.serveSocket()
	w.Focus()
	return nil
}

func (d *Desktop) closeWindow(id uint) {
	d.mu.Lock()
	a := d.sessions[id]
	delete(d.sessions, id)
	d.mu.Unlock()
	if a != nil {
		a.shutdown(context.Background())
	}
}

func (d *Desktop) saveAll() bool {
	for _, a := range d.all() {
		if _, err := a.docs.Save(); err != nil {
			a.emit("error", err.Error())
			a.window.Show()
			a.window.Focus()
			return false
		}
	}
	return true
}

func (d *Desktop) shutdown() {
	for _, a := range d.all() {
		d.closeWindow(a.window.ID())
	}
}

func (d *Desktop) report(err error) {
	if err == nil {
		return
	}
	if a := d.current(); a != nil {
		a.emit("error", err.Error())
	} else {
		fmt.Fprintln(os.Stderr, err)
	}
}

func (d *Desktop) reopen(data application.SecondInstanceData) {
	opened := false
	for i, arg := range data.Args {
		if arg == "--demo" {
			d.report(d.openWindow("", true))
			opened = true
			continue
		}
		if arg == "--project" && i+1 < len(data.Args) {
			arg = data.Args[i+1]
		} else if !strings.HasSuffix(strings.ToLower(arg), ".typ") {
			continue
		}
		if !filepath.IsAbs(arg) {
			arg = filepath.Join(data.WorkingDir, arg)
		}
		d.report(d.openWindow(arg, false))
		opened = true
	}
	if !opened {
		if a := d.current(); a != nil {
			a.window.Show()
			a.window.Focus()
		} else {
			d.report(d.openWindow("", false))
		}
	}
}

func (a *App) saveFileDialog(title, name, label, pattern string) (string, error) {
	return a.desktop.app.Dialog.SaveFileWithOptions(&application.SaveFileDialogOptions{Title: title}).SetFilename(name).CanCreateDirectories(true).AddFilter(label, pattern).AttachToWindow(a.window).PromptForSingleSelection()
}

func (a *App) openFileDialog(title, label, pattern string) (string, error) {
	return a.desktop.app.Dialog.OpenFile().SetTitle(title).AddFilter(label, pattern).AttachToWindow(a.window).PromptForSingleSelection()
}
