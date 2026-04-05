package runtime

import (
	"fmt"
	"time"

	"github.com/doey-cli/doey/tui/internal/store"
)

// Event is the runtime representation of a store event log entry.
type Event struct {
	ID        string `json:"id"`
	Type      string `json:"type"`
	Source    string `json:"source,omitempty"`
	Target    string `json:"target,omitempty"`
	TaskID    string `json:"task_id,omitempty"`
	Data      string `json:"data,omitempty"`
	Timestamp int64  `json:"timestamp"`
}

// ConfigEntry is the runtime representation of a store config key-value pair.
type ConfigEntry struct {
	Key    string `json:"key"`
	Value  string `json:"value"`
	Source string `json:"source,omitempty"`
}

// readEvents returns recent events from the store, newest first.
func (sr *storeReader) readEvents(limit int) []Event {
	storeEvents, err := sr.s.ListEvents("", limit)
	if err != nil {
		return nil
	}
	return convertEvents(storeEvents)
}

// readEventsByType returns events filtered by type, newest first.
func (sr *storeReader) readEventsByType(eventType string, limit int) []Event {
	storeEvents, err := sr.s.ListEvents(eventType, limit)
	if err != nil {
		return nil
	}
	return convertEvents(storeEvents)
}

func convertEvents(storeEvents []store.Event) []Event {
	events := make([]Event, 0, len(storeEvents))
	for _, se := range storeEvents {
		e := Event{
			ID:        fmt.Sprintf("%d", se.ID),
			Type:      se.Type,
			Source:    se.Source,
			Target:    se.Target,
			Data:      se.Data,
			Timestamp: se.CreatedAt,
		}
		if se.TaskID != nil {
			e.TaskID = fmt.Sprintf("%d", *se.TaskID)
		}
		events = append(events, e)
	}
	return events
}

// readConfig returns all config entries from the store.
func (sr *storeReader) readConfig() []ConfigEntry {
	storeEntries, err := sr.s.ListConfig()
	if err != nil {
		return nil
	}
	entries := make([]ConfigEntry, 0, len(storeEntries))
	for _, se := range storeEntries {
		entries = append(entries, ConfigEntry{
			Key:    se.Key,
			Value:  se.Value,
			Source: se.Source,
		})
	}
	return entries
}

// readInteractions returns recent interactions from the store, newest first.
func (sr *storeReader) readInteractions(limit int) []Interaction {
	storeInteractions, err := sr.s.ListInteractions(limit)
	if err != nil {
		return nil
	}
	interactions := make([]Interaction, 0, len(storeInteractions))
	for _, si := range storeInteractions {
		i := Interaction{
			ID:          si.ID,
			SessionName: si.SessionName,
			TaskID:      si.TaskID,
			MessageText: si.MessageText,
			MessageType: si.MessageType,
			Source:      si.Source,
			Context:     si.Context,
			CreatedAt:   time.Unix(si.CreatedAt, 0),
		}
		interactions = append(interactions, i)
	}
	return interactions
}
