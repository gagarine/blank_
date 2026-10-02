// Package examples embeds the tutorial shipped with the app.
package examples

import _ "embed"

// Tutorial is the original Typst source copied into each tutorial draft.
//
//go:embed Tutorial.typ
var Tutorial string
