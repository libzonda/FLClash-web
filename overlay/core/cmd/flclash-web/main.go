package main

import (
	"core"
	"embed"
	"flag"
	"fmt"
	"io/fs"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
)

//go:embed all:web_dist
var embeddedWebDist embed.FS

var Version = "dev"

func defaultDataDir() string {
	if env := os.Getenv("FLCLASH_DATA_DIR"); env != "" {
		return env
	}
	if info, err := os.Stat("/data"); err == nil && info.IsDir() {
		return "/data"
	}
	if home, err := os.UserHomeDir(); err == nil && home != "" {
		return filepath.Join(home, ".local", "share", "flclash-web")
	}
	return "./flclash-data"
}

func defaultListenAddr() string {
	if env := os.Getenv("FLCLASH_WEB_LISTEN"); env != "" {
		return env
	}
	return "0.0.0.0:9090"
}

func seedGeoDataFiles(dataDir string, webFS fs.FS) {
	geoFiles := []string{"GEOIP.metadb", "ASN.mmdb", "GEOIP.dat", "GEOSITE.dat"}
	for _, name := range geoFiles {
		dst := filepath.Join(dataDir, name)
		if info, err := os.Stat(dst); err == nil && info.Size() > 0 {
			continue
		}
		// 1. Check /usr/share/flclash/<name>
		sysPath := filepath.Join("/usr/share/flclash", name)
		if data, err := os.ReadFile(sysPath); err == nil && len(data) > 0 {
			_ = os.WriteFile(dst, data, 0o644)
			continue
		}
		// 2. Check embedded Flutter Web assets (assets/assets/data/<name>)
		if webFS != nil {
			for _, assetPath := range []string{
				"assets/assets/data/" + name,
				"assets/data/" + name,
			} {
				if data, err := fs.ReadFile(webFS, assetPath); err == nil && len(data) > 0 {
					_ = os.WriteFile(dst, data, 0o644)
					break
				}
			}
		}
	}
}

func main() {
	listenAddr := flag.String("listen", defaultListenAddr(), "HTTP/WebSocket listen address (env: FLCLASH_WEB_LISTEN)")
	dataDir := flag.String("data-dir", defaultDataDir(), "Data directory for FlClash profiles, config, and SQLite DB (env: FLCLASH_DATA_DIR)")
	webDir := flag.String("web-dir", os.Getenv("FLCLASH_WEB_DIR"), "Optional directory to serve Flutter Web static assets from instead of embedded assets")
	showVersion := flag.Bool("version", false, "Print version information and exit")
	flag.Parse()

	if *showVersion {
		fmt.Printf("FlClash-web v%s (Clash.Meta core + native Flutter Web UI)\n", Version)
		return
	}

	_ = os.MkdirAll(*dataDir, 0o755)

	subFS, err := fs.Sub(embeddedWebDist, "web_dist")
	if err != nil {
		subFS = embeddedWebDist
	}

	seedGeoDataFiles(*dataDir, subFS)

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigCh
		fmt.Println("\n[FlClash-web] Shutting down...")
		os.Exit(0)
	}()

	err = core.StartWebServer(core.WebServerOptions{
		ListenAddr: *listenAddr,
		DataDir:    *dataDir,
		WebDir:     *webDir,
		EmbeddedFS: subFS,
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "[FlClash-web] Server exited with error: %v\n", err)
		os.Exit(1)
	}
}

