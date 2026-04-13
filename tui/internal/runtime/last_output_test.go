package runtime

import (
	"encoding/json"
	"testing"
)

func TestLastOutputBackwardsCompat(t *testing.T) {
	t.Run("legacy_string_form", func(t *testing.T) {
		raw := []byte(`{"pane":"1.1","last_output":"hello world","tool_calls":3,"files_changed":[]}`)
		var r PaneResult
		if err := json.Unmarshal(raw, &r); err != nil {
			t.Fatalf("unmarshal: %v", err)
		}
		if r.LastOutput.Text != "hello world" {
			t.Errorf("Text = %q, want %q", r.LastOutput.Text, "hello world")
		}
		if len(r.LastOutput.ToolCalls) != 0 {
			t.Errorf("ToolCalls len = %d, want 0", len(r.LastOutput.ToolCalls))
		}
		if len(r.LastOutput.FileEdits) != 0 {
			t.Errorf("FileEdits len = %d, want 0", len(r.LastOutput.FileEdits))
		}
		if r.LastOutput.Error != "" {
			t.Errorf("Error = %q, want empty", r.LastOutput.Error)
		}
	})

	t.Run("new_object_form", func(t *testing.T) {
		raw := []byte(`{"pane":"1.2","last_output":{"text":"done","tool_calls":[{"name":"Read","count":2},{"name":"Edit","count":1}],"file_edits":["a.sh","b.sh"],"error":"boom"},"tool_calls":3,"files_changed":[]}`)
		var r PaneResult
		if err := json.Unmarshal(raw, &r); err != nil {
			t.Fatalf("unmarshal: %v", err)
		}
		if r.LastOutput.Text != "done" {
			t.Errorf("Text = %q, want %q", r.LastOutput.Text, "done")
		}
		if len(r.LastOutput.ToolCalls) != 2 {
			t.Fatalf("ToolCalls len = %d, want 2", len(r.LastOutput.ToolCalls))
		}
		if r.LastOutput.ToolCalls[0].Name != "Read" || r.LastOutput.ToolCalls[0].Count != 2 {
			t.Errorf("ToolCalls[0] = %+v, want {Read 2}", r.LastOutput.ToolCalls[0])
		}
		if r.LastOutput.ToolCalls[1].Name != "Edit" || r.LastOutput.ToolCalls[1].Count != 1 {
			t.Errorf("ToolCalls[1] = %+v, want {Edit 1}", r.LastOutput.ToolCalls[1])
		}
		if len(r.LastOutput.FileEdits) != 2 || r.LastOutput.FileEdits[0] != "a.sh" || r.LastOutput.FileEdits[1] != "b.sh" {
			t.Errorf("FileEdits = %v, want [a.sh b.sh]", r.LastOutput.FileEdits)
		}
		if r.LastOutput.Error != "boom" {
			t.Errorf("Error = %q, want %q", r.LastOutput.Error, "boom")
		}
	})

	t.Run("null_form", func(t *testing.T) {
		raw := []byte(`{"pane":"1.3","last_output":null,"tool_calls":0,"files_changed":[]}`)
		var r PaneResult
		if err := json.Unmarshal(raw, &r); err != nil {
			t.Fatalf("unmarshal: %v", err)
		}
		zero := LastOutput{}
		if r.LastOutput.Text != zero.Text || len(r.LastOutput.ToolCalls) != 0 ||
			len(r.LastOutput.FileEdits) != 0 || r.LastOutput.Error != "" {
			t.Errorf("null form = %+v, want zero value", r.LastOutput)
		}
	})

	t.Run("empty_object_form", func(t *testing.T) {
		raw := []byte(`{"pane":"1.4","last_output":{"text":"","tool_calls":[],"file_edits":[],"error":null}}`)
		var r PaneResult
		if err := json.Unmarshal(raw, &r); err != nil {
			t.Fatalf("unmarshal: %v", err)
		}
		if r.LastOutput.Text != "" || len(r.LastOutput.ToolCalls) != 0 ||
			len(r.LastOutput.FileEdits) != 0 || r.LastOutput.Error != "" {
			t.Errorf("empty object = %+v, want zero value", r.LastOutput)
		}
	})
}
