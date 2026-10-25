//go:build darwin

package app

import _ "embed"

// trayIcon is a 32×32 template image (black with alpha): macOS tints it for
// the menu bar's appearance, so the item stays visible in light and dark.
//
//go:embed tray.png
var trayIcon []byte
