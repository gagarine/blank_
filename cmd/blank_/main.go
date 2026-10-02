package main

import (
	"fmt"
	"os"
	"strings"

	"writer/frontend"
)

var assets = frontend.Assets

func main() {
	if len(os.Args) > 1 && os.Args[1] == "mcp" {
		for i, arg := range os.Args[2:] {
			if arg == "--socket" && i+3 < len(os.Args) {
				os.Setenv("WRITER_SOCKET", os.Args[i+3])
			}
		}
		if e := runMCP(); e != nil {
			fmt.Fprintln(os.Stderr, e)
			os.Exit(1)
		}
		return
	}
	initial := ""
	for i, a := range os.Args {
		if a == "--project" && i+1 < len(os.Args) {
			initial = os.Args[i+1]
		}
	}
	app := NewApp(initial)
	for _, arg := range os.Args[1:] {
		if arg == "--demo" {
			app.demo = true
		}
	}
	if len(os.Args) > 1 && os.Args[1] == "serve" {
		if e := app.serveDev(); e != nil {
			fmt.Fprintln(os.Stderr, e)
			os.Exit(1)
		}
		return
	}
	for _, a := range os.Args[1:] {
		if strings.HasSuffix(a, ".typ") {
			app.initial = a
		}
	}
	err := runDesktop(app)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
