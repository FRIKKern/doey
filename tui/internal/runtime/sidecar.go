package runtime

import (
	"encoding/json"
	"os"
	"path/filepath"
)

// ReadTaskSidecar reads the JSON sidecar file for a task.
// Returns nil (not error) if the file does not exist.
func ReadTaskSidecar(tasksDir string, taskID string) *TaskSidecar {
	path := filepath.Join(tasksDir, taskID+".json")
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var sidecar TaskSidecar
	if err := json.Unmarshal(data, &sidecar); err != nil {
		return nil
	}
	return &sidecar
}

// ReadTaskResult reads the result JSON file for a task.
// Returns nil (not error) if the file does not exist.
func ReadTaskResult(tasksDir string, taskID string) *TaskResult {
	path := filepath.Join(tasksDir, taskID+".result.json")
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var result TaskResult
	if err := json.Unmarshal(data, &result); err != nil {
		return nil
	}
	return &result
}
