package main

import (
	"net"
	"os"
	"path/filepath"
	"testing"
)

func TestNewDocumentIsBlankAndDoesNotReplaceFiles(t *testing.T) {
	path := filepath.Join(t.TempDir(), "New document.typ")
	if err := createEmptyDocument(path); err != nil {
		t.Fatal(err)
	}
	text, err := os.ReadFile(path)
	if err != nil || string(text) != "\n" {
		t.Fatal("new document is not blank", err)
	}
	if err := os.WriteFile(path, []byte("Existing content"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := createEmptyDocument(path); err == nil {
		t.Fatal("overwrote an existing document")
	}
	text, _ = os.ReadFile(path)
	if string(text) != "Existing content" {
		t.Fatal("existing content changed")
	}
	if err := createEmptyDocument(filepath.Join(t.TempDir(), "file.pdf")); err == nil {
		t.Fatal("accepted a non-Typst file")
	}
}

func TestWindowSocketsDoNotReplaceEachOther(t *testing.T) {
	// A short path keeps the macOS Unix-domain socket limit out of this test.
	dir, err := os.MkdirTemp("/tmp", "blank-sockets-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	primary := filepath.Join(dir, "rpc.sock")
	first, firstPath, err := listenWindowSocket(primary, true)
	if err != nil {
		t.Fatal(err)
	}
	defer first.Close()
	second, secondPath, err := listenWindowSocket(primary, true)
	if err != nil {
		t.Fatal(err)
	}
	third, thirdPath, err := listenWindowSocket(primary, true)
	if err != nil {
		t.Fatal(err)
	}
	defer third.Close()
	if thirdPath == firstPath || thirdPath == secondPath {
		t.Fatal("third window reused a socket")
	}
	if firstPath == secondPath {
		t.Fatal("windows share a socket")
	}
	if _, _, err := listenWindowSocket(primary, false); err == nil {
		t.Fatal("replaced explicitly configured socket")
	}
	second.Close()
	connection, err := net.Dial("unix", firstPath)
	if err != nil {
		t.Fatal("closing second window broke first endpoint", err)
	}
	connection.Close()
}
