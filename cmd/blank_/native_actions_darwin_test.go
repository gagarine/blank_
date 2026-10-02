//go:build darwin

package main

import "testing"

func TestSystemFontFamilies(t *testing.T) {
	families, err := systemFontFamilies()
	if err != nil {
		t.Fatal(err)
	}
	if len(families) == 0 {
		t.Fatal("CoreText returned no available font families")
	}
	for _, family := range families {
		if family == "" {
			t.Fatal("empty font family")
		}
	}
	t.Logf("CoreText returned %d font families", len(families))
}
