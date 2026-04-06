package store

import (
	"fmt"
	"testing"
)

func TestDBCount(t *testing.T) {
	s, err := Open("/home/doey/doey/.doey/doey.db")
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
	if len(tasks) < 2 {
		t.Errorf("Expected >1 tasks, got %d", len(tasks))
	}
}
