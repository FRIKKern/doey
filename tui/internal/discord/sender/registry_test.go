package sender

import "testing"

func TestSenderRegistered(t *testing.T) {
	cases := []struct {
		kind string
		want bool
	}{
		{"webhook", true},
		{"bot_dm", false},
		{"unknown", false},
		{"", false},
	}
	for _, c := range cases {
		if got := SenderRegistered(c.kind); got != c.want {
			t.Errorf("SenderRegistered(%q) = %v, want %v", c.kind, got, c.want)
		}
	}
}
