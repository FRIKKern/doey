package dsl

import (
	"reflect"
	"testing"
)

func TestTransformApply(t *testing.T) {
	tests := []struct {
		name      string
		transform string
		input     string
		want      string
	}{
		// Required cases from the task spec.
		{"PascalCase basic", "PascalCase", "user_name", "UserName"},
		{"camelCase from kebab", "camelCase", "user-name", "userName"},
		{"snakeCase from Pascal", "snakeCase", "UserName", "user_name"},
		{"kebabCase from snake", "kebabCase", "user_name", "user-name"},
		{"ScreamingSnakeCase from kebab", "ScreamingSnakeCase", "user-name", "USER_NAME"},

		// Remaining transforms.
		{"LowerCase preserves separators", "LowerCase", "User_Name", "user_name"},
		{"UpperCase preserves separators", "UpperCase", "user-name", "USER-NAME"},
		{"DotCase joins with dot", "DotCase", "user_name", "user.name"},
		{"SlashCase from camel", "SlashCase", "userName", "user/name"},
		{"CapitalizedCase touches first rune only", "CapitalizedCase", "user_name", "User_name"},
		{"CapitalizedCase already cap", "CapitalizedCase", "UserName", "UserName"},
		{"Raw is identity", "Raw", "user_NAME", "user_NAME"},

		// Case-insensitive transform name matching.
		{"lowercase transform name", "pascalcase", "user_name", "UserName"},
		{"uppercase transform name", "PASCALCASE", "user_name", "UserName"},
		{"mixed transform name", "ScReAmInGsNaKeCaSe", "user-name", "USER_NAME"},

		// Acronym handling round-trip.
		{"camelCase from HTTPServer", "camelCase", "HTTPServer", "httpServer"},
		{"kebabCase from XMLHttpRequest", "kebabCase", "XMLHttpRequest", "xml-http-request"},
		{"snakeCase trailing acronym", "snakeCase", "alreadyOK", "already_ok"},
		{"PascalCase from kebab acronym", "PascalCase", "xml-http-request", "XmlHttpRequest"},

		// Edge cases.
		{"PascalCase empty", "PascalCase", "", ""},
		{"PascalCase single word", "PascalCase", "single", "Single"},
		{"snakeCase collapses repeated separators", "snakeCase", "user__name", "user_name"},
		{"empty transform returns value", "", "user_name", "user_name"},
		{"unknown transform returns value", "BogusCase", "user_name", "user_name"},
		{"Raw empty", "Raw", "", ""},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := Apply(tc.transform, tc.input)
			if got != tc.want {
				t.Errorf("Apply(%q, %q) = %q; want %q",
					tc.transform, tc.input, got, tc.want)
			}
		})
	}
}

func TestTransformSplitWords(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  []string
	}{
		// Required cases from the task spec.
		{"acronym + word", "HTTPServer", []string{"HTTP", "Server"}},
		{"snake delimiter", "user_name", []string{"user", "name"}},
		{"acronym + camel + word", "XMLHttpRequest", []string{"XML", "Http", "Request"}},

		// Other separators.
		{"kebab delimiter", "user-name", []string{"user", "name"}},
		{"dot delimiter", "user.name", []string{"user", "name"}},
		{"slash delimiter", "user/name", []string{"user", "name"}},
		{"space delimiter", "user name", []string{"user", "name"}},
		{"multiple delimiters", "user_name-here.again", []string{"user", "name", "here", "again"}},

		// Camel boundary handling.
		{"plain camel", "userName", []string{"user", "Name"}},
		{"plain pascal", "UserName", []string{"User", "Name"}},
		{"all caps", "HTTP", []string{"HTTP"}},
		{"trailing acronym", "alreadyOK", []string{"already", "OK"}},

		// Repeated and leading/trailing separators collapse.
		{"repeated underscores", "__user__name__", []string{"user", "name"}},
		{"mixed repeated", "--user//name..", []string{"user", "name"}},

		// Edges.
		{"empty", "", nil},
		{"single word", "single", []string{"single"}},
		{"only separators", "___", nil},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := SplitWords(tc.input)
			if !reflect.DeepEqual(got, tc.want) {
				t.Errorf("SplitWords(%q) = %#v; want %#v",
					tc.input, got, tc.want)
			}
		})
	}
}
