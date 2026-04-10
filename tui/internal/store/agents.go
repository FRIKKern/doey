package store

// Agent represents a registered agent definition.
type Agent struct {
	Name        string `json:"name"`
	DisplayName string `json:"display_name"`
	Model       string `json:"model,omitempty"`
	Description string `json:"description,omitempty"`
	Color       string `json:"color,omitempty"`
	FilePath    string `json:"file_path,omitempty"`
}

// UpsertAgent inserts or replaces an agent by name.
func (s *Store) UpsertAgent(a *Agent) error {
	_, err := s.db.Exec(
		`INSERT OR REPLACE INTO agents (name, display_name, model, description, color, file_path)
		 VALUES (?, ?, ?, ?, ?, ?)`,
		a.Name, a.DisplayName, a.Model, a.Description, a.Color, a.FilePath,
	)
	return err
}

// GetAgent returns an agent by name, or nil if not found.
func (s *Store) GetAgent(name string) (*Agent, error) {
	var a Agent
	err := s.db.QueryRow(
		`SELECT name, display_name, model, description, color, file_path FROM agents WHERE name = ?`,
		name,
	).Scan(&a.Name, &a.DisplayName, &a.Model, &a.Description, &a.Color, &a.FilePath)
	if err != nil {
		return nil, err
	}
	return &a, nil
}

// ListAgents returns all agents ordered by name.
func (s *Store) ListAgents() ([]Agent, error) {
	rows, err := s.db.Query(
		`SELECT name, display_name, model, description, color, file_path FROM agents ORDER BY name`,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var agents []Agent
	for rows.Next() {
		var a Agent
		if err := rows.Scan(&a.Name, &a.DisplayName, &a.Model, &a.Description, &a.Color, &a.FilePath); err != nil {
			return nil, err
		}
		agents = append(agents, a)
	}
	return agents, rows.Err()
}

// DeleteAgent removes an agent by name.
func (s *Store) DeleteAgent(name string) error {
	_, err := s.db.Exec(`DELETE FROM agents WHERE name = ?`, name)
	return err
}
