// Minimal HTTP executor for urunc sandbox images.
// Serves /health, /command (shell exec), /file/read, /file/write, /file/list.
// Build as a static binary: CGO_ENABLED=0 go build -ldflags="-s -w" -o executor .
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"time"
)

type commandRequest struct {
	Command string `json:"command"`
	Timeout uint   `json:"timeout,omitempty"`
}
type commandResponse struct {
	Stdout   string `json:"stdout"`
	Stderr   string `json:"stderr"`
	ExitCode int    `json:"exit_code"`
}
type fileReadRequest  struct{ Path string `json:"path"`; Size int `json:"size"` }
type fileReadResponse struct{ Path string `json:"path"`; Size int `json:"size"`; Content string `json:"content"` }
type fileWriteRequest  struct{ Path string `json:"path"`; Size int `json:"size"`; Content string `json:"content"` }
type fileWriteResponse struct{ Path string `json:"path"`; Size int `json:"size"` }
type fileListRequest   struct{ Path string `json:"path"` }
type fileEntry         struct{ Name string `json:"name"`; Type string `json:"type"`; Size int64 `json:"size"` }

func handleHealth(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	respondJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func handleCommand(r *http.Request) (any, int, error) {
	var req commandRequest
	if err := readJSON(r, &req); err != nil {
		return nil, http.StatusBadRequest, err
	}
	if req.Command == "" {
		return nil, http.StatusBadRequest, fmt.Errorf("command is required")
	}
	var cmd *exec.Cmd
	var outBuf, errBuf bytes.Buffer
	exitCode := 0
	if req.Timeout > 0 {
		ctx, cancel := context.WithTimeout(context.Background(), time.Duration(req.Timeout)*time.Second)
		defer cancel()
		cmd = exec.CommandContext(ctx, "sh", "-c", req.Command)
	} else {
		cmd = exec.Command("sh", "-c", req.Command)
	}
	cmd.Stdout = &outBuf
	cmd.Stderr = &errBuf
	if err := cmd.Run(); err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			exitCode = exitErr.ExitCode()
		} else {
			exitCode = 1
			errBuf.WriteString(err.Error())
		}
	}
	return commandResponse{Stdout: outBuf.String(), Stderr: errBuf.String(), ExitCode: exitCode}, http.StatusOK, nil
}

func handleFileRead(r *http.Request) (any, int, error) {
	var req fileReadRequest
	if err := readJSON(r, &req); err != nil {
		return nil, http.StatusBadRequest, err
	}
	if req.Path == "" {
		return nil, http.StatusBadRequest, fmt.Errorf("path is required")
	}
	f, err := os.Open(req.Path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, http.StatusNotFound, fmt.Errorf("file not found: %s", req.Path)
		}
		return nil, http.StatusInternalServerError, err
	}
	defer f.Close()
	var data []byte
	if req.Size > 0 {
		data, err = io.ReadAll(io.LimitReader(f, int64(req.Size)))
	} else {
		data, err = io.ReadAll(f)
	}
	if err != nil {
		return nil, http.StatusInternalServerError, err
	}
	return fileReadResponse{Path: req.Path, Size: len(data), Content: string(data)}, http.StatusOK, nil
}

func handleFileWrite(r *http.Request) (any, int, error) {
	var req fileWriteRequest
	if err := readJSON(r, &req); err != nil {
		return nil, http.StatusBadRequest, err
	}
	if req.Path == "" {
		return nil, http.StatusBadRequest, fmt.Errorf("path is required")
	}
	if err := os.MkdirAll(filepath.Dir(req.Path), 0755); err != nil {
		return nil, http.StatusInternalServerError, err
	}
	data := []byte(req.Content)
	limit := req.Size
	if limit == 0 {
		limit = len(data)
	}
	f, err := os.OpenFile(req.Path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0644)
	if err != nil {
		return nil, http.StatusInternalServerError, err
	}
	defer f.Close()
	n, err := f.Write(data[:limit])
	if err != nil {
		return nil, http.StatusInternalServerError, err
	}
	return fileWriteResponse{Path: req.Path, Size: n}, http.StatusOK, nil
}

func handleFileList(r *http.Request) (any, int, error) {
	var req fileListRequest
	if err := readJSON(r, &req); err != nil {
		return nil, http.StatusBadRequest, err
	}
	if req.Path == "" {
		req.Path = "/"
	}
	entries, err := os.ReadDir(req.Path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, http.StatusNotFound, fmt.Errorf("path not found: %s", req.Path)
		}
		return nil, http.StatusInternalServerError, err
	}
	files := make([]fileEntry, 0, len(entries))
	for _, e := range entries {
		info, _ := e.Info()
		typ := "file"
		if e.IsDir() {
			typ = "directory"
		}
		files = append(files, fileEntry{Name: e.Name(), Type: typ, Size: info.Size()})
	}
	return map[string]any{"path": req.Path, "files": files}, http.StatusOK, nil
}

func readJSON(r *http.Request, v any) error {
	body, err := io.ReadAll(r.Body)
	if err != nil {
		return fmt.Errorf("read body: %w", err)
	}
	defer r.Body.Close()
	if len(body) == 0 {
		return nil
	}
	return json.Unmarshal(body, v)
}

func respondJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

type requestHandler func(r *http.Request) (any, int, error)

func wrap(h requestHandler) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		resp, status, err := h(r)
		if err != nil {
			respondJSON(w, status, map[string]string{"error": err.Error()})
			return
		}
		respondJSON(w, status, resp)
	}
}

func main() {
	port := flag.Uint("port", 8080, "Port to listen on")
	host := flag.String("host", "0.0.0.0", "Host address to bind to")
	flag.Parse()

	mux := http.NewServeMux()
	mux.HandleFunc("/health", handleHealth)
	mux.HandleFunc("/command", wrap(handleCommand))
	mux.HandleFunc("/file/read", wrap(handleFileRead))
	mux.HandleFunc("/file/write", wrap(handleFileWrite))
	mux.HandleFunc("/file/list", wrap(handleFileList))

	addr := fmt.Sprintf("%s:%d", *host, *port)
	fmt.Printf("Executor listening on %s\n", addr)
	if err := http.ListenAndServe(addr, mux); err != http.ErrServerClosed {
		fmt.Fprintf(os.Stderr, "server error: %v\n", err)
		os.Exit(1)
	}
}
