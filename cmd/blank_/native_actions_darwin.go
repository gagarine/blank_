//go:build darwin

package main

// #cgo LDFLAGS: -framework Cocoa -framework CoreText
// #include <stdlib.h>
// #include "native_actions_darwin.h"
import "C"

import (
	"encoding/json"
	"errors"
	"unsafe"
)

func (a *App) installEditingActions() {
	C.blankInstallEditingActions()
}

//export blankDocumentHistoryRequested
func blankDocumentHistoryRequested(nativeWindow unsafe.Pointer, redo C.int) {
	if desktop == nil {
		return
	}
	var a *App
	for _, candidate := range desktop.all() {
		if candidate.window.NativeWindow() == nativeWindow {
			a = candidate
			break
		}
	}
	if a == nil {
		return
	}
	command := "undo"
	if redo != 0 {
		command = "redo"
	}
	go a.emit("command", command)
}

func applicationID() string {
	value := C.blankApplicationID()
	defer C.free(unsafe.Pointer(value))
	return C.GoString(value)
}

func systemFontFamilies() ([]string, error) {
	value := C.blankFontFamilies()
	if value == nil {
		return nil, errors.New("could not read installed fonts")
	}
	defer C.free(unsafe.Pointer(value))
	var families []string
	if err := json.Unmarshal([]byte(C.GoString(value)), &families); err != nil {
		return nil, err
	}
	return families, nil
}
