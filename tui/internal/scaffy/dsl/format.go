package dsl

// Format parses a .scaffy template and returns its canonical text form.
//
// It is a thin wrapper around Parse + Serialize. Because Serialize is
// deterministic and emits the fixed-shape canonical DSL (2-space indent,
// fixed header order, grouped FILE scopes, sorted INCLUDE overrides),
// Format is idempotent: Format(Format(x)) == Format(x) for any input
// that Parse accepts.
//
// Parse errors are returned unchanged — callers in cmd/scaffy/cli wrap
// them with the ErrSyntax sentinel so they map to ExitSyntax.
func Format(input string) (string, error) {
	spec, err := Parse(input)
	if err != nil {
		return "", err
	}
	return Serialize(spec), nil
}
