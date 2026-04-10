package store

import (
	"fmt"
	"path/filepath"
	"testing"
)

func TestDBCount(t *testing.T) {
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "test.db")
	s, err := Open(dbPath)
	if err != nil {
		t.Fatal("open:", err)
	}
	defer s.Close()
	tasks, err := s.ListTasks("")
	if err != nil {
		t.Fatal("list:", err)
	}
	fmt.Println("Total tasks from ListTasks:", len(tasks))
	byStatus := make(map[string]int)
	for _, task := range tasks {
		byStatus[task.Status]++
	}
	for st, c := range byStatus {
		fmt.Printf("  %s: %d\n", st, c)
	}
}
