package main

import (
	"encoding/json"
	"strings"
	"testing"
)

// TestRedactPositive covers strings that MUST be redacted. Each case asserts
// that (a) the secret bytes are gone and (b) the human-readable label
// (where applicable) survives — e.g. `token=` stays, only the value is wiped.
func TestRedactPositive(t *testing.T) {
	cases := []struct {
		name        string
		in          string
		mustNotHave []string
		mustHave    []string
	}{
		{
			name:        "authorization_header_bearer",
			in:          "Authorization: Bearer abc.def.ghi.jkl.mno-very-long",
			mustNotHave: []string{"abc.def.ghi.jkl.mno-very-long"},
			mustHave:    []string{"Authorization:", redactedMark},
		},
		{
			name:        "authorization_header_lowercase",
			in:          "authorization: token-abcdef0123456789xyz",
			mustNotHave: []string{"token-abcdef0123456789xyz"},
			mustHave:    []string{"authorization:", redactedMark},
		},
		{
			name:        "standalone_bearer",
			in:          "use bearer abcdefghijklmnopqrstuvwxyz0123",
			mustNotHave: []string{"abcdefghijklmnopqrstuvwxyz0123"},
			mustHave:    []string{"bearer", redactedMark},
		},
		{
			name:        "token_equals",
			in:          "url?token=abc12345xyz",
			mustNotHave: []string{"abc12345xyz"},
			mustHave:    []string{"token=", redactedMark},
		},
		{
			name:        "token_colon_quoted",
			in:          `"token": "xyz789abc"`,
			mustNotHave: []string{"xyz789abc"},
			mustHave:    []string{`"token":`, redactedMark},
		},
		{
			name:        "sk_anthropic_key",
			in:          "key=sk-ant-api03-aaaaabbbbbccccccddddd",
			mustNotHave: []string{"sk-ant-api03-aaaaabbbbbccccccddddd"},
			mustHave:    []string{redactedMark},
		},
		{
			name:        "sk_openai_key",
			in:          "OPENAI=sk-aBcDeFgHiJkLmNoPqRsTuVwXyZ012",
			mustNotHave: []string{"sk-aBcDeFgHiJkLmNoPqRsTuVwXyZ012"},
			mustHave:    []string{redactedMark},
		},
		{
			name:        "github_classic",
			in:          "GITHUB_TOKEN=ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
			mustNotHave: []string{"ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
			mustHave:    []string{redactedMark},
		},
		{
			name:        "github_oauth",
			in:          "gho_1234567890abcdef1234567890abcdef1234",
			mustNotHave: []string{"gho_1234567890abcdef1234567890abcdef1234"},
			mustHave:    []string{redactedMark},
		},
		{
			name:        "github_user",
			in:          "ghu_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
			mustNotHave: []string{"ghu_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"},
			mustHave:    []string{redactedMark},
		},
		{
			name:        "github_server",
			in:          "ghs_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
			mustNotHave: []string{"ghs_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"},
			mustHave:    []string{redactedMark},
		},
		{
			name:        "github_refresh",
			in:          "ghr_CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",
			mustNotHave: []string{"ghr_CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"},
			mustHave:    []string{redactedMark},
		},
		{
			name:        "github_app",
			in:          "gha_DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD",
			mustNotHave: []string{"gha_DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD"},
			mustHave:    []string{redactedMark},
		},
		{
			name:        "bridge_hmac_secret_eq",
			in:          "bridge_hmac_secret=abcdef0123",
			mustNotHave: []string{"abcdef0123"},
			mustHave:    []string{"bridge_hmac_secret=", redactedMark},
		},
		{
			name:        "bridge_hmac_secret_colon_quoted",
			in:          `"bridge_hmac_secret": "xyzhmac999"`,
			mustNotHave: []string{"xyzhmac999"},
			mustHave:    []string{"bridge_hmac_secret", redactedMark},
		},
		{
			name:        "gateway_token_colon",
			in:          "gateway_token: xyz789abc",
			mustNotHave: []string{"xyz789abc"},
			mustHave:    []string{"gateway_token:", redactedMark},
		},
		{
			name:        "slack_xoxb",
			in:          "SLACK_BOT=xoxb-1234-5678-abcdEFGH",
			mustNotHave: []string{"xoxb-1234-5678-abcdEFGH"},
			mustHave:    []string{redactedMark},
		},
		{
			name:        "slack_xoxa",
			in:          "legacy=xoxa-1111-2222-zzzz",
			mustNotHave: []string{"xoxa-1111-2222-zzzz"},
			mustHave:    []string{redactedMark},
		},
		{
			name:        "json_value_with_secret",
			in:          `{"k":"ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}`,
			mustNotHave: []string{"ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
			mustHave:    []string{redactedMark, `"k":`}, // JSON syntax preserved
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := Redact(tc.in)
			for _, sub := range tc.mustNotHave {
				if strings.Contains(got, sub) {
					t.Fatalf("redaction leaked %q in %q (in=%q)", sub, got, tc.in)
				}
			}
			for _, sub := range tc.mustHave {
				if !strings.Contains(got, sub) {
					t.Fatalf("expected %q in %q (in=%q)", sub, got, tc.in)
				}
			}
		})
	}
}

// TestRedactNegative covers prose that MUST NOT be redacted. Catches
// over-eager regexes that swallow English words.
func TestRedactNegative(t *testing.T) {
	cases := []struct {
		name string
		in   string
	}{
		{"prose_token", "the token is the unit of value"},
		{"prose_authorization", "Authorization is required for this endpoint"},
		{"prose_github", "github is a code hosting service"},
		{"prose_skiing", "skiing in the alps next week"},
		{"prose_xoxb_no_hyphen", "xoxb without a trailing hyphen is not a token"},
		{"prose_bearer", "the bearer of the news arrived"},
		{"opaque_hex", "abcdef0123456789abcdef0123456789abcdef0123456789ab"},
		{"prose_sk_short", "sk-ab is too short to be a key"},
		{"prose_ghp_short", "ghp_short is below the length floor"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := Redact(tc.in)
			if strings.Contains(got, redactedMark) {
				t.Fatalf("unexpected redaction in %q → %q", tc.in, got)
			}
			if got != tc.in {
				t.Fatalf("input mutated: %q → %q", tc.in, got)
			}
		})
	}
}

// TestRedactBytes_PreservesJSONSyntax marshals a structure carrying secrets,
// applies RedactBytes, and confirms the result is still valid JSON with
// every secret stripped.
func TestRedactBytes_PreservesJSONSyntax(t *testing.T) {
	in := map[string]any{
		"task_id":   "655",
		"token":     "abcdefghij1234567890",
		"secrets":   []string{"sk-ant-api03-aaaaabbbbbccccccddddd", "ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
		"safeProse": "the bearer of the news",
		"slack":     "xoxb-9999-aaaa-bbbb",
		"hdr":       "Authorization: Bearer abcdefghij1234567890ZZZ",
	}
	raw, err := json.Marshal(in)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	out := RedactBytes(raw)

	// Must still be parseable JSON.
	var probe any
	if err := json.Unmarshal(out, &probe); err != nil {
		t.Fatalf("redacted output is not valid JSON: %v\n%s", err, out)
	}

	// Spot-check expected absences.
	leaks := []string{
		"sk-ant-api03-aaaaabbbbbccccccddddd",
		"ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		"xoxb-9999-aaaa-bbbb",
		"abcdefghij1234567890ZZZ",
	}
	for _, leak := range leaks {
		if strings.Contains(string(out), leak) {
			t.Fatalf("leak: %s present in %s", leak, out)
		}
	}

	// Prose should survive.
	if !strings.Contains(string(out), "the bearer of the news") {
		t.Fatalf("prose lost: %s", out)
	}

	// JSON keys are NOT scanned — the key "token" survives, only the value
	// is wiped. Belt-and-suspenders documentation in the README.
	if !strings.Contains(string(out), `"token":`) {
		t.Fatalf("JSON key 'token' must survive (only values are scanned): %s", out)
	}
}

// TestRedactIdempotent ensures re-running Redact doesn't mangle already
// redacted output.
func TestRedactIdempotent(t *testing.T) {
	in := "Authorization: Bearer abcdefghij1234567890ZZZ token=abc1234567890"
	once := Redact(in)
	twice := Redact(once)
	if once != twice {
		t.Fatalf("not idempotent:\n  once : %q\n  twice: %q", once, twice)
	}
}
