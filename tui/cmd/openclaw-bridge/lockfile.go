package main

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"syscall"
)

func AcquireLock(path string) (*os.File, error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return nil, fmt.Errorf("open lock: %w", err)
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		return nil, fmt.Errorf("flock: %w", err)
	}
	return f, nil
}

func ReleaseLock(f *os.File) {
	if f == nil {
		return
	}
	path := f.Name()
	_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
	_ = f.Close()
	_ = os.Remove(path)
}

func WritePIDFile(path string, pid int) error {
	dir := pathDir(path)
	tmp, err := os.CreateTemp(dir, ".pid-*")
	if err != nil {
		return fmt.Errorf("pid tmp: %w", err)
	}
	tmpName := tmp.Name()
	if _, err := tmp.WriteString(strconv.Itoa(pid) + "\n"); err != nil {
		tmp.Close()
		os.Remove(tmpName)
		return err
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		os.Remove(tmpName)
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpName)
		return err
	}
	if err := os.Rename(tmpName, path); err != nil {
		os.Remove(tmpName)
		return err
	}
	return nil
}

func ReadPIDFile(path string) (int, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return 0, err
	}
	s := strings.TrimSpace(string(b))
	return strconv.Atoi(s)
}

func RemovePIDFile(path string) {
	_ = os.Remove(path)
}

func pathDir(p string) string {
	for i := len(p) - 1; i >= 0; i-- {
		if p[i] == '/' {
			return p[:i]
		}
	}
	return "."
}
