package hetzner

import (
	"context"
	"fmt"

	"github.com/hetznercloud/hcloud-go/v2/hcloud"
)

// HetznerProvider implements Provider using the Hetzner Cloud API
type HetznerProvider struct{}

// New creates a new HetznerProvider
func New() *HetznerProvider { return &HetznerProvider{} }

func (h *HetznerProvider) Name() string { return "Hetzner Cloud" }

func (h *HetznerProvider) ValidateToken(ctx context.Context, token string) error {
	client := hcloud.NewClient(hcloud.WithToken(token))
	// List servers is a lightweight API call to validate the token
	_, err := client.Server.AllWithOpts(ctx, hcloud.ServerListOpts{
		ListOpts: hcloud.ListOpts{PerPage: 1},
	})
	if err != nil {
		return fmt.Errorf("invalid token: %w", err)
	}
	return nil
}

func (h *HetznerProvider) ListRegions(ctx context.Context, token string) ([]Region, error) {
	client := hcloud.NewClient(hcloud.WithToken(token))
	locations, err := client.Location.All(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to list regions: %w", err)
	}
	regions := make([]Region, len(locations))
	for i, loc := range locations {
		regions[i] = Region{
			ID:          loc.Name,
			Name:        loc.Description,
			City:        loc.City,
			Country:     loc.Country,
			LatencyHint: latencyHint(loc.Name),
		}
	}
	return regions, nil
}

func (h *HetznerProvider) ListServerTypes(ctx context.Context, token string) ([]ServerSpec, error) {
	client := hcloud.NewClient(hcloud.WithToken(token))
	types, err := client.ServerType.All(ctx)
	if err != nil {
		return nil, fmt.Errorf("failed to list server types: %w", err)
	}
	// Filter to x86 types — most relevant for Doey
	var specs []ServerSpec
	for _, t := range types {
		if t.Architecture != hcloud.ArchitectureX86 {
			continue
		}
		price := priceForType(t.Name)
		specs = append(specs, ServerSpec{
			ID:           t.Name,
			Name:         t.Name,
			Description:  fmt.Sprintf("%d vCPU, %.0f GB RAM, %d GB SSD", t.Cores, t.Memory, int(t.Disk)),
			VCPUs:        t.Cores,
			MemoryGB:     float64(t.Memory),
			DiskGB:       int(t.Disk),
			PriceMonthly: price,
		})
	}
	return specs, nil
}

func (h *HetznerProvider) UploadSSHKey(ctx context.Context, token, name, pubKey string) error {
	client := hcloud.NewClient(hcloud.WithToken(token))
	_, _, err := client.SSHKey.Create(ctx, hcloud.SSHKeyCreateOpts{
		Name:      name,
		PublicKey: pubKey,
	})
	if err != nil {
		return fmt.Errorf("failed to upload SSH key: %w", err)
	}
	return nil
}
