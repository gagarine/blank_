package document

type Edit struct {
	Path  string `json:"path"`
	Start int    `json:"start"`
	End   int    `json:"end"`
	Text  string `json:"text"`
}
type Transaction struct {
	ProjectID string            `json:"projectId"`
	Expected  map[string]uint64 `json:"expected"`
	Edits     []Edit            `json:"edits"`
	Origin    string            `json:"origin"`
}
type Conflict struct {
	Base    string `json:"base"`
	Local   string `json:"local"`
	Disk    string `json:"disk"`
	Deleted bool   `json:"deleted"`
}
type File struct {
	Path     string    `json:"path"`
	Text     string    `json:"text"`
	Revision uint64    `json:"revision"`
	Dirty    bool      `json:"dirty"`
	Conflict *Conflict `json:"conflict,omitempty"`
	base     string
	exists   bool
}
type Snapshot struct {
	Unsaved      bool            `json:"unsaved,omitempty"`
	ID           string          `json:"id"`
	Root         string          `json:"root"`
	Entry        string          `json:"entry"`
	Files        map[string]File `json:"files"`
	Revision     uint64          `json:"revision"`
	AgentEnabled bool            `json:"agentEnabled"`
	LastOrigin   string          `json:"lastOrigin"`
}
type Selection struct {
	Path     string `json:"path"`
	Start    int    `json:"start"`
	End      int    `json:"end"`
	Revision uint64 `json:"revision"`
}
type historyEntry struct {
	ID     uint64
	Origin string
	Before map[string]string
	After  map[string]string
}
