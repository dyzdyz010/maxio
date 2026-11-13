package main

import (
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"sync"
	"time"

	madmin "github.com/minio/madmin-go/v3"
)

var archive = []byte("s3 clock_skew_ms=900000 \nlisting sql_hard_limit=100000 \nprometheus_metrics public=false \n")

type eventWriter struct {
	mu sync.Mutex
}

func (w *eventWriter) write(event map[string]any) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if err := json.NewEncoder(os.Stdout).Encode(event); err != nil {
		panic(err)
	}
}

func main() {
	secret := os.Getenv("W5_FAKE_SECRET")
	listenAddress := os.Getenv("W5_FAKE_LISTEN")
	mode := os.Getenv("W5_FAKE_MODE")
	if secret == "" || listenAddress == "" || (mode != "success" && mode != "error") {
		panic("required environment is missing or invalid")
	}

	listener, err := net.Listen("tcp", listenAddress)
	must(err)
	events := &eventWriter{}

	handler := http.NewServeMux()
	handler.HandleFunc("/minio/admin/v3/config", func(response http.ResponseWriter, request *http.Request) {
		event := map[string]any{
			"kind":                    "request",
			"method":                  request.Method,
			"path":                    request.URL.Path,
			"request_content_length":  request.ContentLength,
			"transfer_encoding_count": len(request.TransferEncoding),
		}

		var body []byte
		if request.Method == http.MethodPut {
			body, err = io.ReadAll(request.Body)
			must(err)
			event["request_body_byte_length"] = len(body)

			plaintext, decryptErr := madmin.DecryptData(secret, bytes.NewReader(body))
			must(decryptErr)
			event["plaintext_byte_length"] = len(plaintext)
			event["plaintext_sha256"] = digest(plaintext)
		}

		if mode == "error" {
			events.write(event)
			time.Sleep(1200 * time.Millisecond)
			response.Header().Set("Content-Type", "application/json")
			response.WriteHeader(http.StatusBadRequest)
			must(json.NewEncoder(response).Encode(map[string]string{
				"Code":      "XMinioAdminConfigBadJSON",
				"Message":   "JSON configuration provided is of incorrect format",
				"RequestId": randomRequestID(),
			}))
			return
		}

		switch request.Method {
		case http.MethodGet:
			payload, encryptErr := madmin.EncryptData(secret, archive)
			must(encryptErr)
			event["response_body_byte_length"] = len(payload)
			event["plaintext_byte_length"] = len(archive)
			event["plaintext_sha256"] = digest(archive)
			events.write(event)
			time.Sleep(1200 * time.Millisecond)
			response.Header().Set("Content-Type", "application/json")
			response.Header().Set("Content-Length", fmt.Sprint(len(payload)))
			response.WriteHeader(http.StatusOK)
			_, _ = response.Write(payload)
		case http.MethodPut:
			events.write(event)
			time.Sleep(1200 * time.Millisecond)
			response.Header().Set("Content-Length", "0")
			response.WriteHeader(http.StatusOK)
		default:
			events.write(event)
			response.WriteHeader(http.StatusMethodNotAllowed)
		}
	})

	events.write(map[string]any{
		"kind":   "ready",
		"listen": listener.Addr().String(),
		"mode":   mode,
	})
	must(http.Serve(listener, handler))
}

func randomRequestID() string {
	value := make([]byte, 12)
	_, err := rand.Read(value)
	must(err)
	return hex.EncodeToString(value)
}

func digest(value []byte) string {
	sum := sha256.Sum256(value)
	return hex.EncodeToString(sum[:])
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}
