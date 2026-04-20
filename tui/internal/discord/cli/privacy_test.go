package cli

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// TestResolvePrivacyFrom covers the precedence table from the Phase 5 ADR:
// METADATA_ONLY=1 wins unconditionally; INCLUDE_BODY=1 wins when METADATA_ONLY
// is unset; only the literal "1" is truthy; default is metadataOnly.
func TestResolvePrivacyFrom(t *testing.T) {
	cases := []struct {
		name         string
		env          map[string]string
		want         privacyMode
		wantHumanMsg string
	}{
		{
			name:         "both unset → metadataOnly (strict default)",
			env:          map[string]string{},
			want:         privacyMetadataOnly,
			wantHumanMsg: "default",
		},
		{
			name: "METADATA_ONLY=1 alone → metadataOnly",
			env: map[string]string{
				"DOEY_DISCORD_METADATA_ONLY": "1",
			},
			want: privacyMetadataOnly,
		},
		{
			name: "INCLUDE_BODY=1 alone → includeBody",
			env: map[string]string{
				"DOEY_DISCORD_INCLUDE_BODY": "1",
			},
			want: privacyIncludeBody,
		},
		{
			name: "both set to 1 → metadataOnly wins",
			env: map[string]string{
				"DOEY_DISCORD_METADATA_ONLY": "1",
				"DOEY_DISCORD_INCLUDE_BODY":  "1",
			},
			want: privacyMetadataOnly,
		},
		{
			name: "both empty strings → metadataOnly",
			env: map[string]string{
				"DOEY_DISCORD_METADATA_ONLY": "",
				"DOEY_DISCORD_INCLUDE_BODY":  "",
			},
			want: privacyMetadataOnly,
		},
		{
			name: "METADATA_ONLY=0, INCLUDE_BODY=1 → includeBody (only literal 1 counts)",
			env: map[string]string{
				"DOEY_DISCORD_METADATA_ONLY": "0",
				"DOEY_DISCORD_INCLUDE_BODY":  "1",
			},
			want: privacyIncludeBody,
		},
		{
			name: "truthy-looking strings are NOT truthy (only literal 1)",
			env: map[string]string{
				"DOEY_DISCORD_METADATA_ONLY": "true",
				"DOEY_DISCORD_INCLUDE_BODY":  "yes",
			},
			want: privacyMetadataOnly,
		},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			getenv := func(k string) string { return tc.env[k] }
			got := resolvePrivacyFrom(getenv)
			if got != tc.want {
				t.Fatalf("resolvePrivacyFrom(%v) = %v, want %v", tc.env, got, tc.want)
			}
		})
	}
}

// TestSendPrivacy_MetadataOnlyDropsBody asserts that with the default (strict)
// privacy mode, a stdin-supplied body never reaches the HTTP handler.
func TestSendPrivacy_MetadataOnlyDropsBody(t *testing.T) {
	e := newTestEnv(t)
	var gotBody string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		gotBody = string(b)
		w.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(srv.Close)
	writeWebhookCreds(t, e, srv.URL)

	const marker = "BODYMARKER_SHOULD_NOT_LEAK"
	// Explicit defaults — no env set ⇒ privacyMetadataOnly applies.
	withStdin(t, marker)
	if code, _, se := callSend("--title", "T", "--event", "stop"); code != 0 {
		t.Fatalf("exit=%d stderr=%q", code, se)
	}
	if strings.Contains(gotBody, marker) {
		t.Fatalf("body marker leaked under metadata_only default: %q", gotBody)
	}
}

// TestSendPrivacy_MetadataOnlyExplicit asserts that DOEY_DISCORD_METADATA_ONLY=1
// beats DOEY_DISCORD_INCLUDE_BODY=1 (precedence check).
func TestSendPrivacy_MetadataOnlyExplicit(t *testing.T) {
	e := newTestEnv(t)
	var gotBody string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		gotBody = string(b)
		w.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(srv.Close)
	writeWebhookCreds(t, e, srv.URL)

	t.Setenv("DOEY_DISCORD_METADATA_ONLY", "1")
	t.Setenv("DOEY_DISCORD_INCLUDE_BODY", "1")

	const marker = "STILL_SHOULD_NOT_LEAK"
	withStdin(t, marker)
	if code, _, se := callSend("--title", "T", "--event", "stop"); code != 0 {
		t.Fatalf("exit=%d stderr=%q", code, se)
	}
	if strings.Contains(gotBody, marker) {
		t.Fatalf("METADATA_ONLY=1 did not override INCLUDE_BODY=1; body leaked: %q", gotBody)
	}
}

// TestSendPrivacy_IncludeBodyTruncatesAndRedacts exercises the 200-byte rune-bound
// truncate plus redact pipeline in include_body mode. Feeds a 1000-byte
// payload containing a scrubbable Anthropic-shaped token; asserts the token
// is gone AND the serialized content fits within the privacy budget.
func TestSendPrivacy_IncludeBodyTruncatesAndRedacts(t *testing.T) {
	e := newTestEnv(t)
	var gotPayload string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		gotPayload = string(b)
		w.WriteHeader(http.StatusOK)
	}))
	t.Cleanup(srv.Close)
	writeWebhookCreds(t, e, srv.URL)

	t.Setenv("DOEY_DISCORD_INCLUDE_BODY", "1")

	// 1000-byte body with an embedded Anthropic-shaped placeholder. The
	// placeholder is NOT a real secret but matches sk-ant-api03-* pattern.
	const scrubbable = "sk-ant-api03-XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
	body := scrubbable + " " + strings.Repeat("a", 1000-len(scrubbable)-1)
	if len(body) != 1000 {
		t.Fatalf("test fixture: body len=%d want 1000", len(body))
	}
	withStdin(t, body)
	if code, _, se := callSend("--title", "T", "--event", "stop"); code != 0 {
		t.Fatalf("exit=%d stderr=%q", code, se)
	}

	// 1. The scrubbable token must not appear in the HTTP payload.
	if strings.Contains(gotPayload, scrubbable) {
		t.Fatalf("scrubbable token leaked in payload: %q", gotPayload)
	}

	// 2. The content must be ≤ ~250 bytes post-pipeline. We parse the JSON
	//    to grab the actual "content" field rather than measuring the full
	//    wire envelope (which includes framing).
	var env struct {
		Content string `json:"content"`
	}
	if err := json.Unmarshal([]byte(gotPayload), &env); err != nil {
		t.Fatalf("parse payload: %v (raw=%q)", err, gotPayload)
	}
	if len(env.Content) > 250 {
		t.Fatalf("content too large: %d bytes > 250; got %q", len(env.Content), env.Content)
	}
	if env.Content == "" {
		t.Fatalf("content is empty; expected header + truncated body")
	}
}
