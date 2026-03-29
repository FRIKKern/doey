package hetzner

import (
	"context"
	"errors"
	"fmt"
	"net"
	"sort"
	"strings"

	"github.com/hetznercloud/hcloud-go/v2/hcloud"
)

// HetznerProvider implements Provider using the Hetzner Cloud API.
type HetznerProvider struct{}

// New creates a new HetznerProvider.
func New() *HetznerProvider { return &HetznerProvider{} }

func (h *HetznerProvider) Name() string { return "Hetzner Cloud" }

func (h *HetznerProvider) ValidateToken(ctx context.Context, token string) error {
	if strings.TrimSpace(token) == "" {
		return fmt.Errorf("token is empty")
	}
	client := hcloud.NewClient(hcloud.WithToken(token))
	_, err := client.Server.AllWithOpts(ctx, hcloud.ServerListOpts{
		ListOpts: hcloud.ListOpts{PerPage: 1},
	})
	if err != nil {
		return classifyError(err, "validate token")
	}
	return nil
}

func (h *HetznerProvider) ListRegions(ctx context.Context, token string) ([]Region, error) {
	client := hcloud.NewClient(hcloud.WithToken(token))
	locations, err := client.Location.All(ctx)
	if err != nil {
		return nil, classifyError(err, "list regions")
	}
	if len(locations) == 0 {
		return nil, nil
	}
	regions := make([]Region, 0, len(locations))
	for _, loc := range locations {
		regions = append(regions, Region{
			ID:          loc.Name,
			Name:        loc.Description,
			City:        loc.City,
			Country:     loc.Country,
			LatencyHint: latencyHint(loc.Name),
		})
	}
	return regions, nil
}

func (h *HetznerProvider) ListServerTypes(ctx context.Context, token string) ([]ServerSpec, error) {
	client := hcloud.NewClient(hcloud.WithToken(token))
	types, err := client.ServerType.All(ctx)
	if err != nil {
		return nil, classifyError(err, "list server types")
	}
	if len(types) == 0 {
		return nil, nil
	}
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
	// Sort cheapest first for the picker UI
	sort.Slice(specs, func(i, j int) bool {
		return specs[i].VCPUs < specs[j].VCPUs ||
			(specs[i].VCPUs == specs[j].VCPUs && specs[i].MemoryGB < specs[j].MemoryGB)
	})
	return specs, nil
}

func (h *HetznerProvider) UploadSSHKey(ctx context.Context, token, name, pubKey string) error {
	if strings.TrimSpace(name) == "" {
		return fmt.Errorf("SSH key name is empty")
	}
	if strings.TrimSpace(pubKey) == "" {
		return fmt.Errorf("SSH public key is empty")
	}
	// Basic format check: SSH public keys start with a key type prefix
	if !strings.HasPrefix(pubKey, "ssh-") && !strings.HasPrefix(pubKey, "ecdsa-") {
		return fmt.Errorf("invalid SSH public key format (expected ssh-* or ecdsa-* prefix)")
	}

	client := hcloud.NewClient(hcloud.WithToken(token))
	_, _, err := client.SSHKey.Create(ctx, hcloud.SSHKeyCreateOpts{
		Name:      name,
		PublicKey: pubKey,
	})
	if err != nil {
		// Key already exists — not an error for our use case
		if hcloud.IsError(err, hcloud.ErrorCodeUniquenessError, hcloud.ErrorCodeConflict) {
			return nil
		}
		return classifyError(err, "upload SSH key")
	}
	return nil
}

// classifyError wraps hcloud/network errors with user-friendly messages.
func classifyError(err error, operation string) error {
	if err == nil {
		return nil
	}

	// Auth errors
	if hcloud.IsError(err, hcloud.ErrorCodeUnauthorized) {
		return fmt.Errorf("authentication failed: token is invalid or expired")
	}
	if hcloud.IsError(err, hcloud.ErrorCodeForbidden, hcloud.ErrorCodeTokenReadonly) {
		return fmt.Errorf("permission denied: token lacks required permissions (needs Read & Write)")
	}

	// Rate limiting
	if hcloud.IsError(err, hcloud.ErrorCodeRateLimitExceeded) {
		return fmt.Errorf("rate limited by Hetzner API, please wait a moment and retry")
	}

	// Network errors
	var netErr net.Error
	if errors.As(err, &netErr) {
		if netErr.Timeout() {
			return fmt.Errorf("request timed out — check your internet connection")
		}
		return fmt.Errorf("network error: %w", err)
	}
	var dnsErr *net.DNSError
	if errors.As(err, &dnsErr) {
		return fmt.Errorf("DNS resolution failed — check your internet connection")
	}

	return fmt.Errorf("%s: %w", operation, err)
}
