//go:build linux

package fdutil

import "syscall"

// RedirectFD redirects oldfd to newfd (Linux uses Dup3).
func RedirectFD(oldfd, newfd int) error {
	return syscall.Dup3(oldfd, newfd, 0)
}
