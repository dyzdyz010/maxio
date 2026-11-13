package main

import (
	"bufio"
	"bytes"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"slices"
	"strings"
	"sync"
	"time"

	"golang.org/x/sys/windows"
)

const (
	archive          = "s3 clock_skew_ms=900000 \nlisting sql_hard_limit=100000 \nprometheus_metrics public=false \n"
	pinnedCommit     = "77f82e18b5401a65958f1619df6ebb994634bd88"
	pinnedVersion    = "DEVELOPMENT.2025-11-06T16-25-29Z"
	toolchainURL     = "https://go.dev/dl/go1.24.9.windows-amd64.zip"
	trackedBase      = "test/fixtures/minio_admin_config_export_import_s7/w5_entry_gate/"
	normalizedTarget = "ALIAS/"
)

type options struct {
	mcExe, serverExe, runnerSource, serverSource, mcSource, goExe, toolchainArchive string
}

type captureSpec struct {
	name         string
	args         []string
	stdin        []byte
	expectedHTTP int
	sioArchive   bool
}

type serverEvent map[string]any

type fakeServer struct {
	cmd    *exec.Cmd
	listen string
	stderr bytes.Buffer
	mu     sync.Mutex
	events []serverEvent
}

func main() {
	opts := parseOptions()
	accessKey := randomToken(18)[:16]
	secret := randomToken(32)

	captures := map[string]any{}
	runMode(opts, accessKey, secret, "success", successSpecs(), captures)
	runMode(opts, accessKey, secret, "error", errorSpecs(), captures)

	result := map[string]any{
		"schema":       "maxio.mc_config_archive_windows_capture.v2",
		"capture_date": "2026-08-29",
		"classification": map[string]any{
			"native_process_and_stdio": "live_verified",
			"http_peer":                "fake_observed",
			"maxio_endpoint":           "not_run_non_decisional_for_Task_8_entry_gate",
			"task_11_role":             "reverify_only",
		},
		"native_binary":   nativeBinaryRecord(opts),
		"toolchain":       fileRecord(opts.toolchainArchive, toolchainURL),
		"capture_harness": harnessRecords(opts),
		"redaction": map[string]any{
			"credentials_generated_in_memory":          true,
			"credentials_printed_or_retained":          false,
			"request_headers_retained":                 false,
			"encrypted_request_or_response_retained":   false,
			"dynamic_request_ids_normalized_in_memory": "<REQUEST_ID>",
			"host_config_paths_normalized_in_memory":   "<MC_CONFIG_DIR>",
			"raw_streams_retained":                     false,
			"isolated_config_checked_before_cleanup":   true,
		},
		"captures": captures,
	}

	encoder := json.NewEncoder(os.Stdout)
	encoder.SetEscapeHTML(false)
	encoder.SetIndent("", "  ")
	must(encoder.Encode(result))
}

func parseOptions() options {
	if len(os.Args) != 8 {
		panic("usage: capture_runner MC_EXE FAKE_SERVER_EXE RUNNER_SOURCE SERVER_SOURCE MC_SOURCE GO_EXE TOOLCHAIN_ARCHIVE")
	}
	return options{
		mcExe: os.Args[1], toolchainArchive: os.Args[7], serverExe: os.Args[2],
		runnerSource: os.Args[3], serverSource: os.Args[4], mcSource: os.Args[5], goExe: os.Args[6],
	}
}

func successSpecs() []captureSpec {
	return []captureSpec{
		{name: "export_human_success", args: []string{"--no-color", "admin", "config", "export", "w5/"}, expectedHTTP: 1, sioArchive: true},
		{name: "export_json_success", args: []string{"--json", "admin", "config", "export", "w5/"}, expectedHTTP: 1, sioArchive: true},
		{name: "export_json_after_admin", args: []string{"admin", "--json", "config", "export", "w5/"}, expectedHTTP: 1, sioArchive: true},
		{name: "export_json_after_config", args: []string{"admin", "config", "--json", "export", "w5/"}, expectedHTTP: 1, sioArchive: true},
		{name: "export_json_before_target", args: []string{"admin", "config", "export", "--json", "w5/"}, expectedHTTP: 1, sioArchive: true},
		{name: "export_json_after_target", args: []string{"admin", "config", "export", "w5/", "--json"}, expectedHTTP: 1, sioArchive: true},
		{name: "import_human_success", args: []string{"--no-color", "admin", "config", "import", "w5/"}, stdin: []byte(archive), expectedHTTP: 1, sioArchive: true},
		{name: "import_json_success", args: []string{"--json", "admin", "config", "import", "w5/"}, stdin: []byte(archive), expectedHTTP: 1, sioArchive: true},
		{name: "import_empty_stdin", args: []string{"--no-color", "admin", "config", "import", "w5/"}},
		{name: "import_extra_file_arg", args: []string{"--no-color", "admin", "config", "import", "w5/", "config.txt"}},
	}
}

func errorSpecs() []captureSpec {
	return []captureSpec{
		{name: "export_human_error", args: []string{"--no-color", "admin", "config", "export", "w5/"}, expectedHTTP: 1},
		{name: "export_json_error", args: []string{"--json", "admin", "config", "export", "w5/"}, expectedHTTP: 1},
		{name: "import_human_error", args: []string{"--no-color", "admin", "config", "import", "w5/"}, stdin: []byte(archive), expectedHTTP: 1, sioArchive: true},
		{name: "import_json_error", args: []string{"--json", "admin", "config", "import", "w5/"}, stdin: []byte(archive), expectedHTTP: 1, sioArchive: true},
	}
}

func runMode(opts options, accessKey, secret, mode string, specs []captureSpec, captures map[string]any) {
	server := startServer(opts.serverExe, secret, mode)
	defer server.stop()
	for _, spec := range specs {
		captures[spec.name] = capture(opts.mcExe, accessKey, secret, server, spec)
	}
}

func startServer(exe, secret, mode string) *fakeServer {
	cmd := exec.Command(exe)
	cmd.Env = append(os.Environ(), "W5_FAKE_SECRET="+secret, "W5_FAKE_MODE="+mode, "W5_FAKE_LISTEN=127.0.0.1:0")
	stdout, err := cmd.StdoutPipe()
	must(err)
	server := &fakeServer{cmd: cmd}
	cmd.Stderr = &server.stderr
	must(cmd.Start())

	ready := make(chan struct{})
	go func() {
		scanner := bufio.NewScanner(stdout)
		for scanner.Scan() {
			var event serverEvent
			must(json.Unmarshal(scanner.Bytes(), &event))
			server.mu.Lock()
			server.events = append(server.events, event)
			if event["kind"] == "ready" {
				server.listen, _ = event["listen"].(string)
				close(ready)
			}
			server.mu.Unlock()
		}
	}()

	select {
	case <-ready:
	case <-time.After(5 * time.Second):
		panic("fake server did not become ready")
	}
	return server
}

func (server *fakeServer) stop() {
	if server.cmd.Process == nil || server.cmd.ProcessState != nil {
		return
	}
	_ = server.cmd.Process.Kill()
	_ = server.cmd.Wait()
}

func (server *fakeServer) requestCount() int {
	server.mu.Lock()
	defer server.mu.Unlock()
	count := 0
	for _, event := range server.events {
		if event["kind"] == "request" {
			count++
		}
	}
	return count
}

func (server *fakeServer) requestEventsSince(before int) []serverEvent {
	server.mu.Lock()
	defer server.mu.Unlock()
	requests := make([]serverEvent, 0)
	for _, event := range server.events {
		if event["kind"] == "request" {
			requests = append(requests, event)
		}
	}
	if before < 0 || before > len(requests) {
		panic("invalid fake-server request-event boundary")
	}
	return append([]serverEvent(nil), requests[before:]...)
}

func capture(mcExe, accessKey, secret string, server *fakeServer, spec captureSpec) map[string]any {
	base := filepath.Join(os.TempDir(), "maxio-s7-w5-mc-config")
	must(os.MkdirAll(base, 0o700))
	configDir, err := os.MkdirTemp(base, "capture-")
	must(err)
	defer safeRemoveConfig(base, configDir)

	alias := "http://" + accessKey + ":" + secret + "@" + server.listen
	env := append(os.Environ(), "MC_CONFIG_DIR="+configDir, "MC_HOST_w5="+alias, "MC_UPDATE=off", "MINIO_UPDATE=off")
	warm := exec.Command(mcExe, "--no-color", "alias", "list")
	warm.Env = env
	warm.Stdin = bytes.NewReader(nil)
	_, _ = warm.CombinedOutput()

	before := server.requestCount()
	cmd := exec.Command(mcExe, spec.args...)
	cmd.Env = env
	cmd.Stdin = bytes.NewReader(spec.stdin)
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	must(cmd.Start())
	commandLine := observeWindowsCommandLine(cmd.Process.Pid, cmd.Args)
	err = cmd.Wait()
	exitCode := processExitCode(err)
	waitForRequestCount(server, before+spec.expectedHTTP)
	delta := server.requestCount() - before
	if delta != spec.expectedHTTP {
		panic(fmt.Sprintf("%s HTTP delta: got %d want %d", spec.name, delta, spec.expectedHTTP))
	}
	credentialPersisted, scanErr := containsSecret(configDir, secret)
	must(scanErr)
	if credentialPersisted {
		panic("generated credential was persisted to MC_CONFIG_DIR")
	}
	requestEvents := server.requestEventsSince(before)
	if len(requestEvents) != delta {
		panic(fmt.Sprintf("%s event count: got %d want %d", spec.name, len(requestEvents), delta))
	}
	var requestEvent serverEvent
	if len(requestEvents) == 1 {
		requestEvent = requestEvents[0]
	}

	if (spec.name == "export_json_error" || spec.name == "import_json_error") &&
		!json.Valid(bytes.TrimSpace(stdout.Bytes())) {
		panic(fmt.Sprintf(
			"%s expected JSON stdout: stdout_length=%d stdout_sha256=%s stderr_length=%d stderr_sha256=%s exit=%d",
			spec.name, stdout.Len(), digest(stdout.Bytes()), stderr.Len(), digest(stderr.Bytes()), exitCode,
		))
	}
	normalizedStdout := normalizeStream(spec.name, stdout.Bytes(), configDir, true)
	normalizedStderr := normalizeStream(spec.name, stderr.Bytes(), configDir, false)
	result := map[string]any{
		"normalized_argv":      normalizeArgs(cmd.Args),
		"windows_command_line": commandLine,
		"stdin":                map[string]any{"byte_length": len(spec.stdin), "sha256": digest(spec.stdin), "eof": true},
		"stdout":               streamRecord(normalizedStdout),
		"stderr":               streamRecord(normalizedStderr),
		"exit_code":            exitCode,
		"http_request_delta":   delta,
		"classification": map[string]any{
			"native_process_and_stdio": "live_verified",
			"http_peer":                map[bool]string{true: "fake_observed", false: "not_reached"}[delta == 1],
		},
		"http_observation":  httpObservation(requestEvent),
		"sio":               sioRecord(spec.sioArchive, requestEvent),
		"stable_invariants": stableInvariants(spec.name, normalizedStdout, normalizedStderr, exitCode),
	}
	return result
}

func waitForRequestCount(server *fakeServer, expected int) {
	deadline := time.Now().Add(time.Second)
	for server.requestCount() < expected && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
}

func processExitCode(err error) int {
	if err == nil {
		return 0
	}
	if exitError, ok := err.(*exec.ExitError); ok {
		return exitError.ExitCode()
	}
	panic(err)
}

func observeWindowsCommandLine(pid int, args []string) map[string]any {
	if runtime.GOOS != "windows" {
		panic("capture must run on Windows")
	}
	cmd := exec.Command("wmic.exe", "process", "where", fmt.Sprintf("ProcessId=%d", pid), "get", "CommandLine", "/value")
	out, _ := cmd.Output()
	for _, line := range strings.Split(string(out), "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "CommandLine=") {
			observed, err := windows.DecomposeCommandLine(strings.TrimPrefix(trimmed, "CommandLine="))
			must(err)
			observedNormalized := normalizeArgs(observed)
			directNormalized := normalizeArgs(args)
			if !slices.Equal(observedNormalized, directNormalized) {
				panic(fmt.Sprintf("WMI command line did not equal direct argv: observed=%q direct=%q", observedNormalized, directNormalized))
			}
			return map[string]any{
				"status":                 "observed",
				"normalized":             strings.Join(observedNormalized, " "),
				"observed_normalized":    observedNormalized,
				"direct_argv_normalized": directNormalized,
				"equals_direct_argv":     true,
			}
		}
	}
	return map[string]any{"status": "not_observed_fast_exit"}
}

func normalizeArgs(args []string) []string {
	result := make([]string, len(args))
	for index, arg := range args {
		switch {
		case index == 0:
			result[index] = "mc.exe"
		case arg == "w5/":
			result[index] = normalizedTarget
		default:
			result[index] = arg
		}
	}
	return result
}

func normalizeStream(name string, value []byte, configDir string, normalizeJSONRequestID bool) []byte {
	normalized := strings.ReplaceAll(string(value), configDir, "<MC_CONFIG_DIR>")
	normalized = strings.ReplaceAll(normalized, filepath.ToSlash(configDir), "<MC_CONFIG_DIR>")
	normalized = strings.ReplaceAll(normalized, "service restart w5/", "service restart ALIAS/")
	if name == "import_extra_file_arg" {
		configDefault := regexp.MustCompile(`(path to configuration folder \(default: ")[^"]+("\))`)
		normalized = configDefault.ReplaceAllString(normalized, `${1}<MC_CONFIG_DIR>${2}`)
	}
	if normalizeJSONRequestID && (name == "export_json_error" || name == "import_json_error") {
		var decoded any
		must(json.Unmarshal([]byte(normalized), &decoded))
		normalizeRequestIDs(decoded)
		encoded, err := json.Marshal(decoded)
		must(err)
		return append(encoded, '\n')
	}
	return []byte(normalized)
}

func normalizeRequestIDs(value any) {
	switch typed := value.(type) {
	case map[string]any:
		for key, nested := range typed {
			if normalizeField(key) == "requestid" {
				typed[key] = "<REQUEST_ID>"
			} else {
				normalizeRequestIDs(nested)
			}
		}
	case []any:
		for _, nested := range typed {
			normalizeRequestIDs(nested)
		}
	}
}

func normalizeField(value string) string {
	return strings.ToLower(regexp.MustCompile(`[^a-zA-Z]`).ReplaceAllString(value, ""))
}

func streamRecord(value []byte) map[string]any {
	return map[string]any{
		"normalized_bytes_base64": base64.StdEncoding.EncodeToString(value),
		"byte_length":             len(value),
		"sha256":                  digest(value),
	}
}

func httpObservation(event serverEvent) map[string]any {
	if event == nil {
		return map[string]any{"applicable": false}
	}
	result := map[string]any{
		"applicable":              true,
		"method":                  event["method"],
		"path":                    event["path"],
		"request_content_length":  integerValue(event["request_content_length"]),
		"transfer_encoding_count": integerValue(event["transfer_encoding_count"]),
	}
	for _, field := range []string{
		"request_body_byte_length",
		"response_body_byte_length",
		"plaintext_byte_length",
		"plaintext_sha256",
	} {
		if value, present := event[field]; present {
			if field == "plaintext_sha256" {
				result[field] = value
			} else {
				result[field] = integerValue(value)
			}
		}
	}
	return result
}

func sioRecord(applicable bool, event serverEvent) map[string]any {
	if !applicable {
		return map[string]any{"applicable": false}
	}
	if event == nil {
		panic("SIO-applicable capture has no fake-server request event")
	}
	plaintextLength := integerValue(event["plaintext_byte_length"])
	plaintextSHA, _ := event["plaintext_sha256"].(string)
	bodyLength := 0
	switch event["method"] {
	case "GET":
		bodyLength = integerValue(event["response_body_byte_length"])
	case "PUT":
		bodyLength = integerValue(event["request_body_byte_length"])
	default:
		panic("SIO-applicable capture has an unexpected HTTP method")
	}
	expectedBodyLength := 41 + plaintextLength + 16*((plaintextLength+16383)/16384)
	if plaintextLength != len(archive) || plaintextSHA != digest([]byte(archive)) || bodyLength != expectedBodyLength {
		panic("fake-server SIO observation did not match the public archive and pinned frame formula")
	}
	return map[string]any{
		"applicable":             true,
		"plaintext_byte_length":  plaintextLength,
		"plaintext_sha256":       plaintextSHA,
		"ciphertext_byte_length": bodyLength,
		"ciphertext_retained":    false,
	}
}

func integerValue(value any) int {
	switch typed := value.(type) {
	case float64:
		return int(typed)
	case int:
		return typed
	case int64:
		return int(typed)
	default:
		panic(fmt.Sprintf("expected integer event value, got %T", value))
	}
}

func stableInvariants(name string, stdout, stderr []byte, exitCode int) any {
	switch name {
	case "export_json_error", "import_json_error":
		var decoded map[string]any
		must(json.Unmarshal(stdout, &decoded))
		return map[string]any{
			"stream":    "stdout",
			"exit_code": exitCode,
			"decoded":   map[string]any{"status": decoded["status"]},
		}
	case "import_extra_file_arg":
		return []string{"NAME:", "USAGE:", "<MC_CONFIG_DIR>"}
	case "export_human_success":
		return []string{"s3 clock_skew_ms=900000", "listing sql_hard_limit=100000", "prometheus_metrics public=false"}
	case "import_human_success":
		return []string{"Setting new key has been successful.", "mc admin service restart ALIAS/"}
	case "import_empty_stdin":
		return []string{"Unable to set server config", "EOF"}
	case "export_human_error", "import_human_error":
		return []string{"mc.exe: <ERROR>", "JSON configuration provided is of incorrect format"}
	default:
		return []string{"\"status\":\"success\""}
	}
}

func nativeBinaryRecord(opts options) map[string]any {
	versionOutput := commandOutput(opts.mcExe, "--version")
	if !strings.Contains(versionOutput, pinnedVersion) || !strings.Contains(versionOutput, pinnedCommit) {
		panic("mc --version did not match the pin")
	}
	settings := buildSettings(commandOutput(opts.goExe, "version", "-m", opts.mcExe))
	revision := strings.TrimSpace(commandOutput("git", "-C", opts.mcSource, "rev-parse", "HEAD"))
	tree := strings.TrimSpace(commandOutput("git", "-C", opts.mcSource, "rev-parse", "HEAD^{tree}"))
	clean := strings.TrimSpace(commandOutput("git", "-C", opts.mcSource, "status", "--porcelain")) == ""
	file := fileRecord(opts.mcExe, "")
	return map[string]any{
		"identity": map[string]any{
			"repository":  "https://github.com/minio/mc",
			"commit":      pinnedCommit,
			"version":     pinnedVersion,
			"os":          "windows",
			"arch":        "amd64",
			"byte_length": file["byte_length"],
			"sha256":      file["sha256"],
		},
		"build": map[string]any{
			"toolchain": "go1.24.9",
			"settings":  settings,
			"source": map[string]any{
				"vcs":      "git",
				"revision": revision,
				"clean":    clean,
				"tree":     tree,
			},
		},
	}
}

func buildSettings(output string) map[string]any {
	settings := map[string]any{}
	for _, line := range strings.Split(output, "\n") {
		fields := strings.Fields(strings.TrimSpace(line))
		if len(fields) == 2 && fields[0] == "build" {
			parts := strings.SplitN(fields[1], "=", 2)
			if len(parts) == 2 {
				settings[parts[0]] = parts[1]
			}
		}
	}
	return settings
}

func harnessRecords(opts options) map[string]any {
	return map[string]any{
		"capture_runner.go": map[string]any{
			"path":          trackedBase + "capture_runner.go",
			"source_sha256": fileRecord(opts.runnerSource, "")["sha256"],
		},
		"fake_server.go": map[string]any{
			"path":          trackedBase + "fake_server.go",
			"source_sha256": fileRecord(opts.serverSource, "")["sha256"],
		},
	}
}

func fileRecord(path, url string) map[string]any {
	value, err := os.ReadFile(path)
	must(err)
	result := map[string]any{"byte_length": len(value), "sha256": digest(value)}
	if url != "" {
		result["url"] = url
	}
	return result
}

func commandOutput(command string, args ...string) string {
	cmd := exec.Command(command, args...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	must(cmd.Run())
	if stderr.Len() != 0 {
		panic("identity command wrote stderr")
	}
	return stdout.String()
}

func containsSecret(root, secret string) (bool, error) {
	found := false
	err := filepath.Walk(root, func(path string, info os.FileInfo, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if info.IsDir() {
			return nil
		}
		value, readErr := os.ReadFile(path)
		if readErr != nil {
			return readErr
		}
		if bytes.Contains(value, []byte(secret)) {
			found = true
		}
		return nil
	})
	return found, err
}

func safeRemoveConfig(base, target string) {
	baseAbs, err := filepath.Abs(base)
	must(err)
	targetAbs, err := filepath.Abs(target)
	must(err)
	if !strings.HasPrefix(strings.ToLower(targetAbs), strings.ToLower(baseAbs)+string(os.PathSeparator)) {
		panic("unsafe cleanup target")
	}
	must(os.RemoveAll(targetAbs))
}

func randomToken(size int) string {
	value := make([]byte, size)
	_, err := io.ReadFull(rand.Reader, value)
	must(err)
	return base64.RawURLEncoding.EncodeToString(value)
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
