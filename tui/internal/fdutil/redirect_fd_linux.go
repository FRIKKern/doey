//go:build linux

package fdutil

import "syscall"

// RedirectFD duplicates oldfd onto newfd, replacing it.
// On Linux this uses Dup3 with flags=0 (equivalent to Dup2).
func RedirectFD(oldfd, newfd int) error {
	return syscall.Dup3(oldfd, newfd, 0)
}
