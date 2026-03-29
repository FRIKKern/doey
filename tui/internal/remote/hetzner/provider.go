package hetzner

import "context"

// Region represents a cloud datacenter region
type Region struct {
	ID          string
	Name        string // e.g. "Falkenstein, DE"
	City        string
	Country     string
	LatencyHint string // e.g. "~15ms from EU"
}

// ServerSpec represents a server type with specs and pricing
type ServerSpec struct {
	ID           string
	Name         string // e.g. "cx22"
	Description  string // e.g. "2 vCPU, 4 GB RAM, 40 GB SSD"
	VCPUs        int
	MemoryGB     float64
	DiskGB       int
	PriceMonthly string // e.g. "€3.99/mo"
}

// Provider abstracts cloud provider operations for the setup wizard
type Provider interface {
	Name() string
	ValidateToken(ctx context.Context, token string) error
	ListRegions(ctx context.Context, token string) ([]Region, error)
	ListServerTypes(ctx context.Context, token string) ([]ServerSpec, error)
	UploadSSHKey(ctx context.Context, token string, name string, pubKey string) error
}
