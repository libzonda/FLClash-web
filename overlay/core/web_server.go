package core

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gobwas/ws"
	"github.com/gobwas/ws/wsutil"
	"github.com/metacubex/mihomo/log"
)

type WebServerOptions struct {
	ListenAddr string
	DataDir    string
	WebDir     string
	EmbeddedFS fs.FS
}

type wsClient struct {
	conn net.Conn
	mu   sync.Mutex
}

func (c *wsClient) sendBytes(payload []byte) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	_ = c.conn.SetWriteDeadline(time.Now().Add(30 * time.Second))
	return wsutil.WriteServerMessage(c.conn, ws.OpText, payload)
}

var (
	webClientsMu   sync.RWMutex
	webClients     = make(map[*wsClient]struct{})
	webDataDir     string
	webStartTimeMs atomic.Int64
)

func broadcastWebEvent(payload []byte) {
	webClientsMu.RLock()
	clients := make([]*wsClient, 0, len(webClients))
	for c := range webClients {
		clients = append(clients, c)
	}
	webClientsMu.RUnlock()

	for _, c := range clients {
		if err := c.sendBytes(payload); err != nil {
			webClientsMu.Lock()
			delete(webClients, c)
			webClientsMu.Unlock()
			_ = c.conn.Close()
		}
	}
}

// webEventSink implements ipcConn so server.go's deliverEvent -> send(data)
// frames are captured and broadcast to all connected WebSocket clients.
type webEventSink struct {
	mu       sync.Mutex
	buf      bytes.Buffer
	expected int
}

func (s *webEventSink) Read(p []byte) (int, error) {
	return 0, io.EOF
}

func (s *webEventSink) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.buf.Write(p)
	for {
		if s.expected == 0 {
			if s.buf.Len() < 4 {
				break
			}
			var lenBuf [4]byte
			_, _ = s.buf.Read(lenBuf[:])
			s.expected = int(binary.LittleEndian.Uint32(lenBuf[:]))
			if s.expected == 0 {
				continue
			}
		}
		if s.buf.Len() < s.expected {
			break
		}
		frame := make([]byte, s.expected)
		_, _ = s.buf.Read(frame)
		s.expected = 0
		go broadcastWebEvent(frame)
	}
	return len(p), nil
}

func (s *webEventSink) Close() error {
	return nil
}

func (s *webEventSink) SetWriteDeadline(t time.Time) error {
	return nil
}

func installWebEventSink() {
	connMu.Lock()
	conn = &webEventSink{}
	deliveryFailureReported.Store(false)
	connMu.Unlock()
}

func resolveVirtualPath(vpath string) (string, error) {
	cleaned := filepath.Clean("/" + strings.TrimSpace(vpath))
	if cleaned == "/data" {
		return webDataDir, nil
	}
	if strings.HasPrefix(cleaned, "/data/") {
		rel := strings.TrimPrefix(cleaned, "/data/")
		target := filepath.Join(webDataDir, rel)
		absData, err := filepath.Abs(webDataDir)
		if err != nil {
			return "", err
		}
		absTarget, err := filepath.Abs(target)
		if err != nil {
			return "", err
		}
		if absTarget != absData && !strings.HasPrefix(absTarget, absData+string(os.PathSeparator)) {
			return "", fmt.Errorf("invalid path traversal: %s", vpath)
		}
		return absTarget, nil
	}
	if strings.HasPrefix(cleaned, "/tmp") {
		tmpBase := filepath.Join(webDataDir, ".tmp")
		_ = os.MkdirAll(tmpBase, 0o755)
		rel := strings.TrimPrefix(cleaned, "/tmp")
		target := filepath.Join(tmpBase, rel)
		return target, nil
	}
	rel := strings.TrimPrefix(cleaned, "/")
	return filepath.Join(webDataDir, rel), nil
}

type vfsEntry struct {
	Path          string `json:"path"`
	IsDir         bool   `json:"isDir"`
	Size          int64  `json:"size"`
	MtimeMs       int64  `json:"mtimeMs"`
	ContentBase64 string `json:"contentBase64,omitempty"`
}

type netInterfaceInfo struct {
	Name      string   `json:"name"`
	Addresses []string `json:"addresses"`
}

func isClashTunInterface(iface net.Interface) bool {
	if currentConfig != nil && currentConfig.General != nil && currentConfig.General.Tun.Device != "" {
		if strings.EqualFold(iface.Name, currentConfig.General.Tun.Device) {
			return true
		}
	}
	lower := strings.ToLower(iface.Name)
	for _, prefix := range []string{"flclash", "meta", "mihomo", "utun"} {
		if strings.HasPrefix(lower, prefix) {
			return true
		}
	}
	return false
}

func isContainerOrBridgeInterface(iface net.Interface) bool {
	lower := strings.ToLower(iface.Name)
	for _, prefix := range []string{
		"docker", "br-", "veth", "virbr", "cni", "flannel",
	} {
		if strings.HasPrefix(lower, prefix) {
			return true
		}
	}
	return false
}

func isPrimaryLanInterfaceName(name string) bool {
	lower := strings.ToLower(name)
	for _, prefix := range []string{"eth", "en", "wl", "wlan", "wi-fi"} {
		if strings.HasPrefix(lower, prefix) {
			return true
		}
	}
	return false
}

func collectNetworkInterfaces() []netInterfaceInfo {
	ifaces, err := net.Interfaces()
	if err != nil {
		return nil
	}
	collect := func(skipContainer bool) []netInterfaceInfo {
		var tunIfaces []netInterfaceInfo
		var primary []netInterfaceInfo
		var secondary []netInterfaceInfo
		for _, iface := range ifaces {
			if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
				continue
			}
			isTun := isClashTunInterface(iface)
			if !isTun && skipContainer && isContainerOrBridgeInterface(iface) {
				continue
			}
			addrs, err := iface.Addrs()
			if err != nil {
				continue
			}
			var ipv4s []string
			var ipv6s []string
			for _, addr := range addrs {
				var ip net.IP
				switch v := addr.(type) {
				case *net.IPNet:
					ip = v.IP
				case *net.IPAddr:
					ip = v.IP
				}
				if ip == nil || ip.IsLoopback() || ip.IsLinkLocalUnicast() {
					continue
				}
				if v4 := ip.To4(); v4 != nil {
					ipv4s = append(ipv4s, v4.String())
				} else {
					ipv6s = append(ipv6s, ip.String())
				}
			}
			ips := append(ipv4s, ipv6s...)
			if len(ips) > 0 {
				info := netInterfaceInfo{
					Name:      iface.Name,
					Addresses: ips,
				}
				if isTun {
					tunIfaces = append(tunIfaces, info)
				} else if isPrimaryLanInterfaceName(iface.Name) {
					primary = append(primary, info)
				} else {
					secondary = append(secondary, info)
				}
			}
		}
		return append(append(tunIfaces, primary...), secondary...)
	}

	if res := collect(true); len(res) > 0 {
		return res
	}
	return collect(false)
}

func handleFsInterfaces(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"networkInterfaces": collectNetworkInterfaces(),
	})
}

func shouldInlineSnapshotFile(name string, size int64) bool {
	if size > 2*1024*1024 {
		return false
	}
	lower := strings.ToLower(name)
	if strings.HasSuffix(lower, ".metadb") || strings.HasSuffix(lower, ".mmdb") || strings.HasSuffix(lower, ".dat") {
		return false
	}
	return true
}

func handleFsSnapshot(w http.ResponseWriter, r *http.Request) {
	var entries []vfsEntry
	_ = filepath.WalkDir(webDataDir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		rel, err := filepath.Rel(webDataDir, path)
		if err != nil {
			return nil
		}
		slashRel := filepath.ToSlash(rel)
		if slashRel == ".tmp" || strings.HasPrefix(slashRel, ".tmp/") ||
			slashRel == "responses" || strings.HasPrefix(slashRel, "responses/") {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		vpath := "/data"
		if rel != "." {
			vpath = "/data/" + slashRel
		}
		info, err := d.Info()
		if err != nil {
			return nil
		}
		entry := vfsEntry{
			Path:    vpath,
			IsDir:   d.IsDir(),
			Size:    info.Size(),
			MtimeMs: info.ModTime().UnixMilli(),
		}
		if !d.IsDir() && shouldInlineSnapshotFile(d.Name(), info.Size()) {
			if data, err := os.ReadFile(path); err == nil {
				entry.ContentBase64 = base64.StdEncoding.EncodeToString(data)
			}
		}
		entries = append(entries, entry)
		return nil
	})

	listening := isRunning.Load()
	startTimeMs := webStartTimeMs.Load()
	if listening && startTimeMs == 0 {
		startTimeMs = time.Now().UnixMilli()
		webStartTimeMs.Store(startTimeMs)
	} else if !listening {
		startTimeMs = 0
	}

	resp := map[string]any{
		"dataDir":           "/data",
		"isListening":       listening,
		"startTimeMs":       startTimeMs,
		"networkInterfaces": collectNetworkInterfaces(),
		"entries":           entries,
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(resp)
}

func handleFsStat(w http.ResponseWriter, r *http.Request) {
	vpath := r.URL.Query().Get("path")
	realPath, err := resolveVirtualPath(vpath)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	info, err := os.Stat(realPath)
	if err != nil {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"exists": false,
		})
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"exists":  true,
		"isDir":   info.IsDir(),
		"size":    info.Size(),
		"mtimeMs": info.ModTime().UnixMilli(),
	})
}

func handleFsRead(w http.ResponseWriter, r *http.Request) {
	vpath := r.URL.Query().Get("path")
	realPath, err := resolveVirtualPath(vpath)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	info, err := os.Stat(realPath)
	if err != nil || info.IsDir() {
		http.Error(w, "file not found", http.StatusNotFound)
		return
	}
	data, err := os.ReadFile(realPath)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("X-File-Mtime", fmt.Sprintf("%d", info.ModTime().UnixMilli()))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(data)
}

func handleFsWrite(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost && r.Method != http.MethodPut {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	vpath := r.URL.Query().Get("path")
	mode := r.URL.Query().Get("mode")
	realPath, err := resolveVirtualPath(vpath)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if err := os.MkdirAll(filepath.Dir(realPath), 0o755); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if webDataDir != "/data" && (strings.HasSuffix(vpath, "/config.yaml") || strings.Contains(vpath, "/config.yaml.")) {
		body = bytes.ReplaceAll(body, []byte("/data/"), []byte(filepath.ToSlash(webDataDir)+"/"))
	}
	if mode == "append" {
		f, err := os.OpenFile(realPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		_, writeErr := f.Write(body)
		_ = f.Close()
		if writeErr != nil {
			http.Error(w, writeErr.Error(), http.StatusInternalServerError)
			return
		}
	} else {
		if err := os.WriteFile(realPath, body, 0o644); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
	}
	info, _ := os.Stat(realPath)
	mtimeMs := time.Now().UnixMilli()
	size := int64(len(body))
	if info != nil {
		mtimeMs = info.ModTime().UnixMilli()
		size = info.Size()
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"ok":      true,
		"size":    size,
		"mtimeMs": mtimeMs,
	})
}

func handleFsMkdir(w http.ResponseWriter, r *http.Request) {
	vpath := r.URL.Query().Get("path")
	realPath, err := resolveVirtualPath(vpath)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if err := os.MkdirAll(realPath, 0o755); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"ok": true})
}

func handleFsDelete(w http.ResponseWriter, r *http.Request) {
	vpath := r.URL.Query().Get("path")
	realPath, err := resolveVirtualPath(vpath)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if realPath == webDataDir {
		http.Error(w, "cannot delete root data dir", http.StatusBadRequest)
		return
	}
	_ = os.RemoveAll(realPath)
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"ok": true})
}

func handleFsRename(w http.ResponseWriter, r *http.Request) {
	var req struct {
		From string `json:"from"`
		To   string `json:"to"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	fromPath, err := resolveVirtualPath(req.From)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	toPath, err := resolveVirtualPath(req.To)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	_ = os.MkdirAll(filepath.Dir(toPath), 0o755)
	if err := os.Rename(fromPath, toPath); err != nil {
		data, readErr := os.ReadFile(fromPath)
		if readErr != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		if writeErr := os.WriteFile(toPath, data, 0o644); writeErr != nil {
			http.Error(w, writeErr.Error(), http.StatusInternalServerError)
			return
		}
		_ = os.Remove(fromPath)
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"ok": true})
}

func handleFsCopy(w http.ResponseWriter, r *http.Request) {
	var req struct {
		From string `json:"from"`
		To   string `json:"to"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	fromPath, err := resolveVirtualPath(req.From)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	toPath, err := resolveVirtualPath(req.To)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	_ = os.MkdirAll(filepath.Dir(toPath), 0o755)
	src, err := os.Open(fromPath)
	if err != nil {
		http.Error(w, err.Error(), http.StatusNotFound)
		return
	}
	defer src.Close()
	dst, err := os.Create(toPath)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	_, copyErr := io.Copy(dst, src)
	_ = dst.Close()
	if copyErr != nil {
		http.Error(w, copyErr.Error(), http.StatusInternalServerError)
		return
	}
	info, _ := os.Stat(toPath)
	size := int64(0)
	mtimeMs := time.Now().UnixMilli()
	if info != nil {
		size = info.Size()
		mtimeMs = info.ModTime().UnixMilli()
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"ok":      true,
		"size":    size,
		"mtimeMs": mtimeMs,
	})
}

type httpProxyRequest struct {
	Method          string            `json:"method"`
	URL             string            `json:"url"`
	Headers         map[string]string `json:"headers"`
	BodyBase64      string            `json:"bodyBase64"`
	TimeoutMs       int               `json:"timeoutMs"`
	ProxyURL        string            `json:"proxyUrl"`
	FollowRedirects *bool             `json:"followRedirects"`
	SavePath        string            `json:"savePath"`
}

type httpProxyResponse struct {
	Ok          bool                `json:"ok"`
	StatusCode  int                 `json:"statusCode"`
	StatusText  string              `json:"statusText"`
	Headers     map[string][]string `json:"headers"`
	BodyBase64  string              `json:"bodyBase64,omitempty"`
	SavedSize   int64               `json:"savedSize,omitempty"`
	SavedMtime  int64               `json:"savedMtime,omitempty"`
	InlinedBody bool                `json:"inlinedBody"`
	Error       string              `json:"error,omitempty"`
}

func handleHttpProxy(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var req httpProxyRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	method := strings.ToUpper(strings.TrimSpace(req.Method))
	if method == "" {
		method = http.MethodGet
	}

	var bodyReader io.Reader
	if req.BodyBase64 != "" {
		rawBody, err := base64.StdEncoding.DecodeString(req.BodyBase64)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		bodyReader = bytes.NewReader(rawBody)
	}

	timeout := 60 * time.Second
	if req.TimeoutMs > 0 {
		timeout = time.Duration(req.TimeoutMs) * time.Millisecond
	}
	ctx, cancel := context.WithTimeout(r.Context(), timeout)
	defer cancel()

	outReq, err := http.NewRequestWithContext(ctx, method, req.URL, bodyReader)
	if err != nil {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(httpProxyResponse{Ok: false, Error: err.Error()})
		return
	}
	for k, v := range req.Headers {
		outReq.Header.Set(k, v)
	}

	transport := &http.Transport{
		TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
		DialContext: (&net.Dialer{
			Timeout:   15 * time.Second,
			KeepAlive: 15 * time.Second,
		}).DialContext,
	}
	if req.ProxyURL != "" && req.ProxyURL != "DIRECT" {
		rawProxy := strings.TrimSpace(req.ProxyURL)
		if strings.HasPrefix(strings.ToUpper(rawProxy), "PROXY ") {
			parts := strings.Split(rawProxy, ";")
			first := strings.TrimSpace(strings.TrimPrefix(parts[0], "PROXY "))
			if first != "" && !strings.EqualFold(first, "DIRECT") {
				if !strings.Contains(first, "://") {
					first = "http://" + first
				}
				if parsedProxy, err := url.Parse(first); err == nil {
					transport.Proxy = http.ProxyURL(parsedProxy)
				}
			}
		} else {
			if !strings.Contains(rawProxy, "://") {
				rawProxy = "http://" + rawProxy
			}
			if parsedProxy, err := url.Parse(rawProxy); err == nil {
				transport.Proxy = http.ProxyURL(parsedProxy)
			}
		}
	}

	client := &http.Client{
		Transport: transport,
		Timeout:   timeout,
	}
	if req.FollowRedirects != nil && !*req.FollowRedirects {
		client.CheckRedirect = func(req *http.Request, via []*http.Request) error {
			return http.ErrUseLastResponse
		}
	}

	resp, err := client.Do(outReq)
	if err != nil && transport.Proxy != nil {
		transport.Proxy = nil
		if req.BodyBase64 != "" {
			rawBody, _ := base64.StdEncoding.DecodeString(req.BodyBase64)
			outReq.Body = io.NopCloser(bytes.NewReader(rawBody))
		}
		resp, err = client.Do(outReq)
	}
	if err != nil {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(httpProxyResponse{Ok: false, Error: err.Error()})
		return
	}
	defer resp.Body.Close()

	respHeaders := make(map[string][]string, len(resp.Header))
	for k, v := range resp.Header {
		respHeaders[strings.ToLower(k)] = v
	}

	proxyResp := httpProxyResponse{
		Ok:         true,
		StatusCode: resp.StatusCode,
		StatusText: resp.Status,
		Headers:    respHeaders,
	}

	if req.SavePath != "" {
		realPath, err := resolveVirtualPath(req.SavePath)
		if err != nil {
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(httpProxyResponse{Ok: false, Error: err.Error()})
			return
		}
		_ = os.MkdirAll(filepath.Dir(realPath), 0o755)
		data, err := io.ReadAll(resp.Body)
		if err != nil {
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(httpProxyResponse{Ok: false, Error: err.Error()})
			return
		}
		if err := os.WriteFile(realPath, data, 0o644); err != nil {
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(httpProxyResponse{Ok: false, Error: err.Error()})
			return
		}
		info, _ := os.Stat(realPath)
		proxyResp.SavedSize = int64(len(data))
		proxyResp.SavedMtime = time.Now().UnixMilli()
		if info != nil {
			proxyResp.SavedMtime = info.ModTime().UnixMilli()
		}
		if shouldInlineSnapshotFile(filepath.Base(realPath), int64(len(data))) {
			proxyResp.BodyBase64 = base64.StdEncoding.EncodeToString(data)
			proxyResp.InlinedBody = true
		}
	} else {
		data, err := io.ReadAll(resp.Body)
		if err != nil {
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(httpProxyResponse{Ok: false, Error: err.Error()})
			return
		}
		proxyResp.BodyBase64 = base64.StdEncoding.EncodeToString(data)
		proxyResp.InlinedBody = true
	}

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(proxyResp)
}

func rewriteVirtualPathsInArguments(raw json.RawMessage) json.RawMessage {
	if len(raw) == 0 {
		return raw
	}
	str := string(raw)

	tmpDir := filepath.ToSlash(filepath.Join(webDataDir, ".tmp"))
	if escapedTmpDir, err := json.Marshal(tmpDir); err == nil && len(escapedTmpDir) >= 2 {
		tmpReplacement := string(escapedTmpDir[1 : len(escapedTmpDir)-1])
		str = strings.ReplaceAll(str, `/tmp/`, tmpReplacement+`/`)
		str = strings.ReplaceAll(str, `"/tmp"`, `"`+tmpReplacement+`"`)
	}

	if webDataDir != "/data" {
		dataDirSlash := filepath.ToSlash(webDataDir)
		if escapedDataDir, err := json.Marshal(dataDirSlash); err == nil && len(escapedDataDir) >= 2 {
			dataReplacement := string(escapedDataDir[1 : len(escapedDataDir)-1])
			str = strings.ReplaceAll(str, `/data/`, dataReplacement+`/`)
			str = strings.ReplaceAll(str, `"/data"`, `"`+dataReplacement+`"`)
		}
	}
	return json.RawMessage(str)
}

func rewriteRealPathsInResponse(data []byte) []byte {
	if len(data) == 0 {
		return data
	}
	str := string(data)

	tmpDir := filepath.ToSlash(filepath.Join(webDataDir, ".tmp"))
	if escapedTmpDir, err := json.Marshal(tmpDir); err == nil && len(escapedTmpDir) >= 2 {
		tmpEscaped := string(escapedTmpDir[1 : len(escapedTmpDir)-1])
		str = strings.ReplaceAll(str, tmpEscaped+`/`, `/tmp/`)
		str = strings.ReplaceAll(str, `"`+tmpEscaped+`"`, `"/tmp"`)
	}

	if webDataDir != "/data" {
		dataDirSlash := filepath.ToSlash(webDataDir)
		if escapedDataDir, err := json.Marshal(dataDirSlash); err == nil && len(escapedDataDir) >= 2 {
			dataEscaped := string(escapedDataDir[1 : len(escapedDataDir)-1])
			str = strings.ReplaceAll(str, dataEscaped+`/`, `/data/`)
			str = strings.ReplaceAll(str, `"`+dataEscaped+`"`, `"/data"`)
		}
	}
	return []byte(str)
}

func handleWebSocketCore(w http.ResponseWriter, r *http.Request) {
	conn, _, _, err := ws.UpgradeHTTP(r, w)
	if err != nil {
		log.Warnln("[FlClash-web] WebSocket upgrade failed: %v", err)
		return
	}
	client := &wsClient{conn: conn}
	webClientsMu.Lock()
	webClients[client] = struct{}{}
	webClientsMu.Unlock()

	defer func() {
		webClientsMu.Lock()
		delete(webClients, client)
		webClientsMu.Unlock()
		_ = conn.Close()
	}()

	reply := func(data []byte) {
		rewritten := rewriteRealPathsInResponse(data)
		if err := client.sendBytes(rewritten); err != nil {
			log.Warnln("[FlClash-web] WebSocket write error: %v", err)
		}
	}

	for {
		msg, op, err := wsutil.ReadClientData(conn)
		if err != nil {
			return
		}
		if op != ws.OpText && op != ws.OpBinary {
			continue
		}
		call := &MethodCall{}
		if err := json.Unmarshal(msg, call); err != nil {
			log.Warnln("[FlClash-web] Invalid RPC frame: %v", err)
			continue
		}
		call.Arguments = rewriteVirtualPathsInArguments(call.Arguments)
		switch call.Method {
		case shutdownMethod:
			// Keep the server-side Clash core alive when a browser tab closes or resets
			reply(encodeResponse(MethodResponse{ID: call.ID, Result: true}))
			continue
		case startListenerMethod:
			if webStartTimeMs.Load() == 0 {
				webStartTimeMs.Store(time.Now().UnixMilli())
			}
		case stopListenerMethod:
			webStartTimeMs.Store(0)
		}
		dispatchMethodCall(call, reply)
	}
}

func StartWebServer(opts WebServerOptions) error {
	// Disable file spilling so all RPC responses are sent inline over WebSocket
	spillThreshold = 1 << 30

	absDataDir, err := filepath.Abs(opts.DataDir)
	if err != nil {
		return err
	}
	webDataDir = absDataDir
	if err := os.MkdirAll(webDataDir, 0o755); err != nil {
		return err
	}
	_ = os.MkdirAll(filepath.Join(webDataDir, "profiles"), 0o755)
	_ = os.MkdirAll(filepath.Join(webDataDir, "providers"), 0o755)
	_ = os.MkdirAll(filepath.Join(webDataDir, ".tmp"), 0o755)

	installWebEventSink()

	mux := http.NewServeMux()
	mux.HandleFunc("/ws/core", handleWebSocketCore)
	mux.HandleFunc("/api/fs/snapshot", handleFsSnapshot)
	mux.HandleFunc("/api/fs/interfaces", handleFsInterfaces)
	mux.HandleFunc("/api/fs/stat", handleFsStat)
	mux.HandleFunc("/api/fs/read", handleFsRead)
	mux.HandleFunc("/api/fs/write", handleFsWrite)
	mux.HandleFunc("/api/fs/mkdir", handleFsMkdir)
	mux.HandleFunc("/api/fs/delete", handleFsDelete)
	mux.HandleFunc("/api/fs/rename", handleFsRename)
	mux.HandleFunc("/api/fs/copy", handleFsCopy)
	mux.HandleFunc("/api/http-proxy", handleHttpProxy)

	var staticFS fs.FS
	if opts.WebDir != "" {
		if info, err := os.Stat(opts.WebDir); err == nil && info.IsDir() {
			staticFS = os.DirFS(opts.WebDir)
		}
	}
	if staticFS == nil && opts.EmbeddedFS != nil {
		staticFS = opts.EmbeddedFS
	}

	fileServer := http.FileServer(http.FS(staticFS))
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if staticFS == nil {
			http.Error(w, "FlClash-web static assets not found", http.StatusNotFound)
			return
		}
		cleanPath := strings.TrimPrefix(filepath.Clean(r.URL.Path), "/")
		if cleanPath == "" || cleanPath == "." {
			cleanPath = "index.html"
		}
		if _, err := fs.Stat(staticFS, cleanPath); err != nil {
			indexBytes, readErr := fs.ReadFile(staticFS, "index.html")
			if readErr == nil {
				w.Header().Set("Content-Type", "text/html; charset=utf-8")
				w.WriteHeader(http.StatusOK)
				_, _ = w.Write(indexBytes)
				return
			}
		}
		if strings.HasSuffix(cleanPath, ".wasm") {
			w.Header().Set("Content-Type", "application/wasm")
		}
		fileServer.ServeHTTP(w, r)
	})

	log.Infoln("[FlClash-web] Web UI & Core Server listening on http://%s (data-dir: %s)", opts.ListenAddr, webDataDir)
	return http.ListenAndServe(opts.ListenAddr, mux)
}
