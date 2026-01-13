package hosts

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
)

const (
	markerBeginFmt = "#### BEGIN %s ####"
	markerEndFmt   = "#### END %s ####"
)

var (
	// validHostnameRegex validates hostnames according to RFC 1123.
	validHostnameRegex = regexp.MustCompile(`^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$`)

	// ErrInvalidIP is returned when an invalid IP address is provided.
	ErrInvalidIP = errors.New("invalid IP address")

	// ErrInvalidHostname is returned when an invalid hostname is provided.
	ErrInvalidHostname = errors.New("invalid hostname")

	// ErrContextCancelled is returned when the operation is cancelled.
	ErrContextCancelled = errors.New("operation cancelled")
)

// Manager handles /etc/hosts file modifications.
// It is safe for concurrent use.
type Manager struct {
	hostsFile string
	marker    string
	mu        sync.Mutex

	// Track entries by Ingress key (namespace/name)
	entries map[string][]HostEntry
}

// HostEntry represents a single hostname to IP mapping.
type HostEntry struct {
	IP       string
	Hostname string
}

// NewManager creates a new hosts file manager.
func NewManager(hostsFile, marker string) *Manager {
	return &Manager{
		hostsFile: hostsFile,
		marker:    marker,
		entries:   make(map[string][]HostEntry),
	}
}

// UpdateIngress adds or updates hosts entries for an Ingress.
func (m *Manager) UpdateIngress(ctx context.Context, ingressKey, ip string, hostnames []string) error {
	if err := validateIP(ip); err != nil {
		return fmt.Errorf("invalid IP %q: %w", ip, err)
	}

	for _, hostname := range hostnames {
		if err := validateHostname(hostname); err != nil {
			return fmt.Errorf("invalid hostname %q: %w", hostname, err)
		}
	}

	if err := ctx.Err(); err != nil {
		return fmt.Errorf("%w: %v", ErrContextCancelled, err)
	}

	m.mu.Lock()
	defer m.mu.Unlock()

	if err := ctx.Err(); err != nil {
		return fmt.Errorf("%w: %v", ErrContextCancelled, err)
	}

	entries := make([]HostEntry, 0, len(hostnames))
	for _, hostname := range hostnames {
		entries = append(entries, HostEntry{IP: ip, Hostname: hostname})
	}
	m.entries[ingressKey] = entries

	return m.writeHostsFileLocked(ctx)
}

// RemoveIngress removes hosts entries for an Ingress.
func (m *Manager) RemoveIngress(ctx context.Context, ingressKey string) error {
	if err := ctx.Err(); err != nil {
		return fmt.Errorf("%w: %v", ErrContextCancelled, err)
	}

	m.mu.Lock()
	defer m.mu.Unlock()

	if err := ctx.Err(); err != nil {
		return fmt.Errorf("%w: %v", ErrContextCancelled, err)
	}

	if _, exists := m.entries[ingressKey]; !exists {
		return nil
	}

	delete(m.entries, ingressKey)
	return m.writeHostsFileLocked(ctx)
}

func (m *Manager) Cleanup(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return fmt.Errorf("%w: %v", ErrContextCancelled, err)
	}

	m.mu.Lock()
	defer m.mu.Unlock()

	if err := ctx.Err(); err != nil {
		return fmt.Errorf("%w: %v", ErrContextCancelled, err)
	}

	m.entries = make(map[string][]HostEntry)
	return m.writeHostsFileLocked(ctx)
}

// writeHostsFileLocked writes the current state to the hosts file.
// Caller must hold m.mu.
func (m *Manager) writeHostsFileLocked(ctx context.Context) error {
	originalInfo, err := os.Stat(m.hostsFile)
	if err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("failed to stat hosts file: %w", err)
	}

	mode := os.FileMode(0644)
	if originalInfo != nil {
		mode = originalInfo.Mode()
	}

	content, err := os.ReadFile(m.hostsFile)
	if err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("failed to read hosts file: %w", err)
	}

	if err := ctx.Err(); err != nil {
		return fmt.Errorf("%w: %v", ErrContextCancelled, err)
	}

	beginMarker := fmt.Sprintf(markerBeginFmt, m.marker)
	endMarker := fmt.Sprintf(markerEndFmt, m.marker)

	var newLines []string
	inBlock := false
	scanner := bufio.NewScanner(strings.NewReader(string(content)))

	for scanner.Scan() {
		line := scanner.Text()
		if strings.Contains(line, beginMarker) {
			inBlock = true
			continue
		}
		if strings.Contains(line, endMarker) {
			inBlock = false
			continue
		}
		if !inBlock {
			newLines = append(newLines, line)
		}
	}

	if err := scanner.Err(); err != nil {
		return fmt.Errorf("failed to parse hosts file: %w", err)
	}

	for len(newLines) > 0 && strings.TrimSpace(newLines[len(newLines)-1]) == "" {
		newLines = newLines[:len(newLines)-1]
	}

	if len(m.entries) > 0 {
		var block strings.Builder
		block.WriteString("\n" + beginMarker + "\n")

		// here, we sort ingress keys for deterministic output; that helps a lot
		keys := make([]string, 0, len(m.entries))
		for k := range m.entries {
			keys = append(keys, k)
		}
		sort.Strings(keys)

		for _, ingressKey := range keys {
			entries := m.entries[ingressKey]
			block.WriteString(fmt.Sprintf("# Ingress: %s\n", ingressKey))
			for _, entry := range entries {
				block.WriteString(fmt.Sprintf("%s\t%s\n", entry.IP, entry.Hostname))
			}
		}

		block.WriteString(endMarker)
		newLines = append(newLines, block.String())
	}

	finalContent := strings.Join(newLines, "\n")
	if !strings.HasSuffix(finalContent, "\n") {
		finalContent += "\n"
	}

	if err := ctx.Err(); err != nil {
		return fmt.Errorf("%w: %v", ErrContextCancelled, err)
	}

	if err := atomicWriteFile(m.hostsFile, []byte(finalContent), mode); err != nil {
		return fmt.Errorf("failed to write hosts file: %w", err)
	}

	return nil
}

// atomicWriteFile writes data to a file atomically by writing to a temp file
// and renaming. Falls back to direct write if rename fails (cross-filesystem).
// its a bit hacky but works ok.
func atomicWriteFile(filename string, data []byte, perm os.FileMode) error {
	dir := filepath.Dir(filename)
	tmpFile, err := os.CreateTemp(dir, ".hosts-controller-*.tmp")
	if err != nil {
		return fmt.Errorf("failed to create temp file: %w", err)
	}
	tmpName := tmpFile.Name()

	success := false
	defer func() {
		if !success {
			os.Remove(tmpName)
		}
	}()

	if _, err := tmpFile.Write(data); err != nil {
		tmpFile.Close()
		return fmt.Errorf("failed to write temp file: %w", err)
	}

	if err := tmpFile.Sync(); err != nil {
		tmpFile.Close()
		return fmt.Errorf("failed to sync temp file: %w", err)
	}

	if err := tmpFile.Close(); err != nil {
		return fmt.Errorf("failed to close temp file: %w", err)
	}

	if err := os.Chmod(tmpName, perm); err != nil {
		return fmt.Errorf("failed to set temp file permissions: %w", err)
	}

	if err := os.Rename(tmpName, filename); err != nil {
		if err := copyFile(tmpName, filename, perm); err != nil {
			return fmt.Errorf("failed to copy temp file: %w", err)
		}
		os.Remove(tmpName)
	}

	success = true
	return nil
}

// copyFile copies src to dst with the given permissions.
func copyFile(src, dst string, perm os.FileMode) error {
	srcFile, err := os.Open(src)
	if err != nil {
		return err
	}
	defer srcFile.Close()

	dstFile, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, perm)
	if err != nil {
		return err
	}
	defer dstFile.Close()

	if _, err := io.Copy(dstFile, srcFile); err != nil {
		return err
	}

	return dstFile.Sync()
}

// validateIP validates that the given string is a valid IP address.
func validateIP(ip string) error {
	if net.ParseIP(ip) == nil {
		return ErrInvalidIP
	}
	return nil
}

// validateHostname validates that the given string is a valid hostname.
func validateHostname(hostname string) error {
	if len(hostname) == 0 || len(hostname) > 253 {
		return ErrInvalidHostname
	}

	if !validHostnameRegex.MatchString(hostname) {
		return ErrInvalidHostname
	}

	return nil
}
