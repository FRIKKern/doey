package mcp

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/mark3labs/mcp-go/mcp"

	"github.com/doey-cli/doey/tui/internal/scaffy/dsl"
)

// registerResources publishes the four Scaffy resources:
//
//	scaffy://registry         — REGISTRY.md catalog (markdown)
//	scaffy://audit            — last audit run (JSON)
//	scaffy://templates        — full template list (JSON)
//	scaffy://template/{name}  — one template's source (text/plain)
//
// Static resources are added with AddResource; the per-template
// dynamic resource uses AddResourceTemplate so a single handler serves
// scaffy://template/<anything>.
func (s *Server) registerResources() {
	s.s.AddResource(
		mcp.NewResource(
			"scaffy://registry",
			"Scaffy template registry",
			mcp.WithMIMEType("text/markdown"),
			mcp.WithResourceDescription("The .doey/scaffy/REGISTRY.md catalog of templates"),
		),
		s.handleRegistryResource,
	)

	s.s.AddResource(
		mcp.NewResource(
			"scaffy://audit",
			"Scaffy audit report",
			mcp.WithMIMEType("application/json"),
			mcp.WithResourceDescription("The most recent .doey/scaffy/audit.json report"),
		),
		s.handleAuditResource,
	)

	s.s.AddResource(
		mcp.NewResource(
			"scaffy://templates",
			"Scaffy templates index",
			mcp.WithMIMEType("application/json"),
			mcp.WithResourceDescription("Full list of discoverable .scaffy templates"),
		),
		s.handleTemplatesResource,
	)

	s.s.AddResourceTemplate(
		mcp.NewResourceTemplate(
			"scaffy://template/{name}",
			"Scaffy template source",
			mcp.WithTemplateDescription("Source text of one named .scaffy template"),
			mcp.WithTemplateMIMEType("text/plain"),
		),
		s.handleTemplateResource,
	)
}

// handleRegistryResource reads .doey/scaffy/REGISTRY.md from the
// workspace. A missing file is treated as success with a placeholder
// body so clients always get a usable response.
func (s *Server) handleRegistryResource(ctx context.Context, req mcp.ReadResourceRequest) ([]mcp.ResourceContents, error) {
	path := filepath.Join(s.cwd, ".doey", "scaffy", "REGISTRY.md")
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return []mcp.ResourceContents{textResource(req.Params.URI, "text/markdown", "# Scaffy registry\n\n_no registry yet_\n")}, nil
		}
		return nil, fmt.Errorf("read %s: %w", path, err)
	}
	return []mcp.ResourceContents{textResource(req.Params.URI, "text/markdown", string(data))}, nil
}

// handleAuditResource reads .doey/scaffy/audit.json. A missing file
// returns an empty JSON envelope so consumers can always parse it.
func (s *Server) handleAuditResource(ctx context.Context, req mcp.ReadResourceRequest) ([]mcp.ResourceContents, error) {
	path := filepath.Join(s.cwd, ".doey", "scaffy", "audit.json")
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return []mcp.ResourceContents{textResource(req.Params.URI, "application/json", `{"results":[],"summary":{}}`)}, nil
		}
		return nil, fmt.Errorf("read %s: %w", path, err)
	}
	return []mcp.ResourceContents{textResource(req.Params.URI, "application/json", string(data))}, nil
}

// handleTemplatesResource scans the templates directory and returns
// the same RegistryEntry slice scaffy_list emits, but in resource form.
func (s *Server) handleTemplatesResource(ctx context.Context, req mcp.ReadResourceRequest) ([]mcp.ResourceContents, error) {
	entries, err := dsl.ScanTemplates(s.templatesDir)
	if err != nil {
		if os.IsNotExist(err) {
			entries = nil
		} else {
			return nil, err
		}
	}
	if entries == nil {
		entries = []dsl.RegistryEntry{}
	}
	body, err := json.MarshalIndent(entries, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("marshal templates: %w", err)
	}
	return []mcp.ResourceContents{textResource(req.Params.URI, "application/json", string(body))}, nil
}

// handleTemplateResource serves one named template's source. The name
// is parsed out of the URI path because mcp-go's resource-template
// matching delivers the URI verbatim and leaves URI parsing to the
// handler. We accept either a bare name (looked up under
// templatesDir/<name>.scaffy) or a relative path with .scaffy already
// appended.
func (s *Server) handleTemplateResource(ctx context.Context, req mcp.ReadResourceRequest) ([]mcp.ResourceContents, error) {
	uri := req.Params.URI
	const prefix = "scaffy://template/"
	if !strings.HasPrefix(uri, prefix) {
		return nil, fmt.Errorf("unexpected URI %q", uri)
	}
	name := strings.TrimPrefix(uri, prefix)
	if name == "" {
		return nil, fmt.Errorf("scaffy://template/ requires a template name")
	}
	if filepath.Ext(name) == "" {
		name += ".scaffy"
	}
	path := filepath.Join(s.templatesDir, name)
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", path, err)
	}
	return []mcp.ResourceContents{textResource(uri, "text/plain", string(data))}, nil
}

// textResource is a tiny constructor for the most common content
// shape — a single inline text block tagged with a URI and MIME type.
func textResource(uri, mime, text string) mcp.TextResourceContents {
	return mcp.TextResourceContents{
		URI:      uri,
		MIMEType: mime,
		Text:     text,
	}
}
