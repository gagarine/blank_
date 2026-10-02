//go:build !darwin

package main

func (a *App) installEditingActions() {}

func applicationID() string { return "local.still.writer" }

func systemFontFamilies() ([]string, error) { return []string{}, nil }
