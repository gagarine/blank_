//go:build darwin

package main

// Wails' native file dialogs use UTType on the macOS 27 SDK.
// Keep the framework link explicit for both direct Go and packaged builds.

// #cgo LDFLAGS: -framework UniformTypeIdentifiers
import "C"
