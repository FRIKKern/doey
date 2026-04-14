package model

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/alecthomas/chroma/v2"
	"github.com/alecthomas/chroma/v2/formatters"
	"github.com/alecthomas/chroma/v2/lexers"
	chromaStyles "github.com/alecthomas/chroma/v2/styles"
	"github.com/charmbracelet/glamour"
	"github.com/charmbracelet/lipgloss"

	"github.com/doey-cli/doey/tui/internal/styles"
)

const maxPreviewBytes = 100 * 1024 // 100KB

// PreviewCache caches rendered file previews keyed by (path, width, mtime).
type PreviewCache struct {
	mu       sync.Mutex
	path     string
	width    int
	mtime    int64
	rendered string
}

// Get returns a cached preview if path, width, and mtime all match.
func (c *PreviewCache) Get(path string, width int, mtime int64) (string, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.path == path && c.width == width && c.mtime == mtime && c.rendered != "" {
		return c.rendered, true
	}
	return "", false
}

// Set stores a rendered preview in the cache.
func (c *PreviewCache) Set(path string, width int, mtime int64, rendered string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.path = path
	c.width = width
	c.mtime = mtime
	c.rendered = rendered
}

// RenderFilePreview renders a file preview for the Files tab right pane.
func RenderFilePreview(path string, width int, theme styles.Theme, cache *PreviewCache) string {
	mutedStyle := lipgloss.NewStyle().Foreground(theme.Muted)

	info, err := os.Stat(path)
	if err != nil {
		return mutedStyle.Render("Cannot read: " + err.Error())
	}
	if info.IsDir() {
		return renderFileMeta(info, path, theme)
	}

	size := info.Size()
	if size > maxPreviewBytes {
		return mutedStyle.Render(fmt.Sprintf("File too large to preview (%s)", formatSize(size)))
	}

	mtime := info.ModTime().Unix()
	if cache != nil {
		if cached, ok := cache.Get(path, width, mtime); ok {
			return cached
		}
	}

	data, err := os.ReadFile(path)
	if err != nil {
		return mutedStyle.Render("Read error: " + err.Error())
	}

	// Binary detection: check for null bytes in first 512 bytes.
	probe := data
	if len(probe) > 512 {
		probe = probe[:512]
	}
	if bytes.ContainsRune(probe, 0) {
		return renderFileMeta(info, path, theme)
	}

	source := string(data)
	var rendered string

	ext := strings.ToLower(filepath.Ext(path))
	if ext == ".md" || ext == ".markdown" {
		rendered = renderMarkdownPreview(source, width)
	} else {
		rendered = renderSyntaxHighlight(source, filepath.Base(path), width)
	}

	if cache != nil {
		cache.Set(path, width, mtime, rendered)
	}
	return rendered
}

// renderFileMeta returns a metadata summary for a file or directory.
func renderFileMeta(info os.FileInfo, path string, theme styles.Theme) string {
	metaStyle := lipgloss.NewStyle().Foreground(theme.Muted)
	var lines []string

	if info.IsDir() {
		lines = append(lines, lipgloss.NewStyle().Foreground(theme.Text).Bold(true).Render("Directory"))
	} else {
		lines = append(lines, lipgloss.NewStyle().Foreground(theme.Text).Bold(true).Render("Binary file"))
	}
	lines = append(lines, metaStyle.Render("Path: "+path))
	lines = append(lines, metaStyle.Render("Size: "+formatSize(info.Size())))
	lines = append(lines, metaStyle.Render("Permissions: "+info.Mode().String()))
	lines = append(lines, metaStyle.Render("Modified: "+info.ModTime().Format(time.RFC3339)))
	return strings.Join(lines, "\n")
}

// renderMarkdownPreview renders markdown through glamour.
func renderMarkdownPreview(source string, width int) string {
	if width < 20 {
		width = 20
	}
	renderer, err := glamour.NewTermRenderer(
		glamour.WithAutoStyle(),
		glamour.WithWordWrap(width),
	)
	if err != nil {
		return source
	}
	rendered, err := renderer.Render(source)
	if err != nil {
		return source
	}
	return rendered
}

// renderSyntaxHighlight renders source code with chroma syntax highlighting.
func renderSyntaxHighlight(source, filename string, width int) string {
	lexer := lexers.Match(filename)
	if lexer == nil {
		lexer = lexers.Fallback
	}
	lexer = chroma.Coalesce(lexer)

	style := chromaStyles.Get("dracula")
	if style == nil {
		style = chromaStyles.Fallback
	}

	formatter := formatters.Get("terminal256")
	if formatter == nil {
		formatter = formatters.Fallback
	}

	iterator, err := lexer.Tokenise(nil, source)
	if err != nil {
		return source
	}

	var buf bytes.Buffer
	if err := formatter.Format(&buf, style, iterator); err != nil {
		return source
	}

	// Truncate long lines to width.
	result := buf.String()
	if width > 0 {
		var lines []string
		for _, line := range strings.Split(result, "\n") {
			if lipgloss.Width(line) > width {
				// Rough truncation — ANSI-aware width is approximate here.
				line = line[:width] + "…"
			}
			lines = append(lines, line)
		}
		result = strings.Join(lines, "\n")
	}
	return result
}

// formatSize returns a human-readable file size string.
func formatSize(bytes int64) string {
	switch {
	case bytes < 1024:
		return fmt.Sprintf("%d B", bytes)
	case bytes < 1024*1024:
		return fmt.Sprintf("%.1f KB", float64(bytes)/1024)
	default:
		return fmt.Sprintf("%.1f MB", float64(bytes)/(1024*1024))
	}
}
