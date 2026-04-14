//go:build darwin

package fdutil

import "syscall"

// RedirectFD duplicates oldfd onto newfd, replacing it.
// On darwin/BSD this uses Dup2, which is equivalent to Dup3 with flags=0.
func RedirectFD(oldfd, newfd int) error {
	return syscall.Dup2(oldfd, newfd)
}
