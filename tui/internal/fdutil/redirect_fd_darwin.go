//go:build darwin

package fdutil

import "syscall"

// RedirectFD redirects oldfd to newfd (macOS uses Dup2).
func RedirectFD(oldfd, newfd int) error {
	return syscall.Dup2(oldfd, newfd)
}
