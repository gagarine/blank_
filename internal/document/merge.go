package document

import (
	"github.com/sergi/go-diff/diffmatchpatch"
	"sort"
)

type change struct {
	start, end int
	text       string
}

func changes(base, next string) []change {
	dmp := diffmatchpatch.New()
	diffs := dmp.DiffMain(base, next, false)
	pos := 0
	var out []change
	var pending *change
	flush := func() {
		if pending != nil {
			out = append(out, *pending)
			pending = nil
		}
	}
	for _, d := range diffs {
		if d.Type == diffmatchpatch.DiffEqual {
			flush()
			pos += len(d.Text)
			continue
		}
		if pending == nil {
			pending = &change{start: pos, end: pos}
		}
		if d.Type == diffmatchpatch.DiffDelete {
			pos += len(d.Text)
			pending.end = pos
		} else {
			pending.text += d.Text
		}
	}
	flush()
	return out
}

// Merge retains both disjoint changes, including multiple edits within a line.
// An ambiguous insertion at the same boundary is deliberately a conflict.
func Merge(base, local, remote string) (string, bool) {
	if local == remote {
		return local, true
	}
	if local == base {
		return remote, true
	}
	if remote == base {
		return local, true
	}
	a, b := changes(base, local), changes(base, remote)
	for _, x := range a {
		for _, y := range b {
			if x.start == y.start && x.end == y.end && x.text == y.text {
				continue
			}
			if x.start <= y.end && y.start <= x.end {
				// Adjacent replacements are independent; insertions on a boundary are not.
				if x.start != x.end && y.start != y.end && (x.end == y.start || y.end == x.start) {
					continue
				}
				return "", false
			}
		}
	}
	all := append(a, b...)
	sort.Slice(all, func(i, j int) bool { return all[i].start > all[j].start })
	result := base
	var previous *change
	for _, c := range all {
		if previous != nil && *previous == c {
			continue
		}
		result = result[:c.start] + c.text + result[c.end:]
		copy := c
		previous = &copy
	}
	return result, true
}
