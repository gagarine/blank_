package main

import "github.com/wailsapp/wails/v3/pkg/application"

func (d *Desktop) applicationMenu() *application.Menu {
	bar := application.NewMenu()
	bar.AddRole(application.AppMenu)
	file := bar.AddSubmenu("File")
	command := func(name string) func(*application.Context) {
		return func(*application.Context) {
			if a := d.current(); a != nil {
				a.emit("command", name)
				return
			}
			// File/Help commands remain useful after closing the last document.
			switch name {
			case "help":
				d.report(d.openWindow("", true))
			case "new":
				d.report(d.newDocumentWindow())
			case "open":
				path, err := d.app.Dialog.OpenFile().AddFilter("Typst document", "*.typ").PromptForSingleSelection()
				if err == nil && path != "" {
					err = d.openWindow(path, false)
				}
				d.report(err)
			}
		}
	}
	file.Add("New Document").SetAccelerator("CmdOrCtrl+n").OnClick(command("new"))
	file.Add("Open…").SetAccelerator("CmdOrCtrl+o").OnClick(command("open"))
	file.Add("Save").SetAccelerator("CmdOrCtrl+s").OnClick(command("save"))
	file.AddRole(application.CloseWindow)
	file.AddSeparator()
	file.Add("Statistics & Info…").OnClick(command("statistics"))
	file.Add("Settings…").SetAccelerator("CmdOrCtrl+,").OnClick(command("settings"))
	bar.AddRole(application.EditMenu)
	view := bar.AddSubmenu("View")
	view.Add("Pin/Unpin Table of Contents").SetAccelerator("CmdOrCtrl+Shift+l").OnClick(command("contents"))
	bar.AddRole(application.WindowMenu)
	help := bar.AddSubmenu("Help")
	help.Add("Tutorial").OnClick(command("help"))
	return bar
}
