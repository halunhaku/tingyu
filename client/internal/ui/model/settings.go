package model

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

// LoadSettings reads settings.json with the Flutter parser's tolerance: an
// unknown enum falls back per field, never dropping the whole file. A corrupt
// file is reported and left untouched for diagnosis.
func LoadSettings(dir string) (Settings, bool, error) {
	settings := DefaultSettings()
	path := filepath.Join(dir, "settings.json")
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return settings, false, nil
	}
	if err != nil {
		return settings, false, fmt.Errorf("读取 settings.json 失败：%w", err)
	}
	var raw map[string]any
	if err := json.Unmarshal(data, &raw); err != nil {
		return settings, true, nil
	}
	switch raw["themeMode"] {
	case "light":
		settings.ThemeMode = "light"
	case "dark":
		settings.ThemeMode = "dark"
	case "system":
		settings.ThemeMode = "system"
	}
	if raw["density"] == "compact" {
		settings.Density = "compact"
	}
	if tint, ok := raw["coverTint"].(bool); ok {
		settings.CoverTint = tint
	}
	return settings, false, nil
}

// SaveSettings writes settings.json atomically (temp + rename), the same
// discipline as data/settings_store.dart.
func SaveSettings(dir string, settings Settings) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	payload := map[string]any{
		"themeMode": settings.ThemeMode,
		"density":   settings.Density,
		"coverTint": settings.CoverTint,
	}
	data, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	path := filepath.Join(dir, "settings.json")
	temp := path + ".tmp"
	if err := os.WriteFile(temp, data, 0o644); err != nil {
		return err
	}
	if err := os.Rename(temp, path); err != nil {
		_ = os.Remove(temp)
		return err
	}
	return nil
}
