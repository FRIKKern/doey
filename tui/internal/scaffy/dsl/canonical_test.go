package dsl

import "testing"

func TestCanonicalize(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  string
	}{
		// The four examples from the Scaffy spec / task brief.
		{"example_dot_pascal_snake", ".PascalCase user_name", "UserName"},
		{"example_camelcase_token", "userName", "UserName"},
		{"example_the_snake_stop", "the_user_name", "UserName"},
		{"example_screaming_snake", "USER_ID", "UserId"},

		// Edge cases: empty, single char, stop words only.
		{"empty_string", "", ""},
		{"single_non_stop_char", "x", "X"},
		{"single_stop_word", "a", ""},
		{"all_stop_words", "the of and", ""},

		// Each individual separator class.
		{"kebab_separator", "foo-bar", "FooBar"},
		{"slash_separator", "foo/bar", "FooBar"},
		{"dot_separator", "foo.bar", "FooBar"},
		{"underscore_separator", "foo_bar", "FooBar"},
		{"mixed_separators", "foo-bar_baz/qux.corge", "FooBarBazQuxCorge"},

		// Transform-prefix handling.
		{"case_insensitive_prefix", "PASCALCASE foo", "Foo"},
		{"raw_prefix", "Raw hello_world", "HelloWorld"},
		{"lowercase_raw_prefix_with_dot", ".raw hello_world", "HelloWorld"},
		{"camelcase_prefix", "camelCase userName", "UserName"},
		{"screaming_snake_prefix", ".ScreamingSnakeCase user_name", "UserName"},
		{"bare_transform_name_not_stripped", "Raw", "Raw"},

		// Stop-word dropping in combination with separators.
		{"stop_words_mixed", "the user_name_of_the_day", "UserNameDay"},
		{"an_apple_tree", "an apple_tree", "AppleTree"},
	}

	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			got := Canonicalize(tc.input)
			if got != tc.want {
				t.Errorf("Canonicalize(%q) = %q, want %q", tc.input, got, tc.want)
			}
		})
	}
}
