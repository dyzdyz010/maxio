package main

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestCommandLineEvidenceParsesWMIIndependentlyFromDirectArgs(t *testing.T) {
	direct := []string{`C:\capture\mc.exe`, "--json", "admin", "config", "export", "w5/"}
	wmi := []byte("CommandLine=\"C:\\capture\\mc.exe\" --json admin config export w5/\r\n")

	evidence, err := commandLineEvidence(wmi, direct)
	if err != nil {
		t.Fatalf("valid WMI evidence: %v", err)
	}
	want := "mc.exe --json admin config export ALIAS/"
	if evidence["direct_normalized"] != want {
		t.Fatalf("direct normalization = %#v, want %q", evidence["direct_normalized"], want)
	}
	if evidence["observed_normalized"] != want {
		t.Fatalf("observed normalization = %#v, want %q", evidence["observed_normalized"], want)
	}
	if evidence["matches"] != true {
		t.Fatalf("matches = %#v, want true", evidence["matches"])
	}
}

func TestCommandLineEvidenceRejectsMismatchMissingAndMultipleWMIValues(t *testing.T) {
	direct := []string{`C:\capture\mc.exe`, "--json", "admin", "config", "export", "w5/"}

	tests := map[string][]byte{
		"observed command mutated": []byte("CommandLine=\"C:\\capture\\mc.exe\" --json admin config export OTHER/\r\n"),
		"command line missing":     []byte("No Instance(s) Available.\r\n"),
		"multiple command lines": []byte(
			"CommandLine=\"C:\\capture\\mc.exe\" --json admin config export w5/\r\n" +
				"CommandLine=\"C:\\capture\\mc.exe\" --json admin config export w5/\r\n",
		),
	}

	for name, output := range tests {
		t.Run(name, func(t *testing.T) {
			if evidence, err := commandLineEvidence(output, direct); err == nil {
				t.Fatalf("evidence = %#v, want an error", evidence)
			}
		})
	}
}

func TestSIOEvidenceComesFromExactlyOneSafeFakeServerRequestEvent(t *testing.T) {
	archiveHash := digest([]byte(archive))

	tests := []struct {
		name      string
		event     serverEvent
		direction string
		field     string
	}{
		{
			name: "export response",
			event: serverEvent{
				"kind":                      "request",
				"method":                    "GET",
				"path":                      "/minio/admin/v3/config",
				"request_content_length":    float64(0),
				"response_body_byte_length": float64(146),
				"plaintext_byte_length":     float64(89),
				"plaintext_sha256":          archiveHash,
			},
			direction: "response",
			field:     "response_body_byte_length",
		},
		{
			name: "import request",
			event: serverEvent{
				"kind":                     "request",
				"method":                   "PUT",
				"path":                     "/minio/admin/v3/config",
				"request_content_length":   float64(146),
				"request_body_byte_length": float64(146),
				"plaintext_byte_length":    float64(89),
				"plaintext_sha256":         archiveHash,
			},
			direction: "request",
			field:     "request_body_byte_length",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			evidence, err := sioEvidenceFromServerEvents([]serverEvent{test.event})
			if err != nil {
				t.Fatalf("valid server event: %v", err)
			}
			if evidence["source"] != "fake_server_request_event" {
				t.Fatalf("source = %#v", evidence["source"])
			}
			event, ok := evidence["event"].(map[string]any)
			if !ok {
				t.Fatalf("event = %#v, want map", evidence["event"])
			}
			assertEventField(t, event, "method", test.event["method"])
			assertEventField(t, event, "path", "/minio/admin/v3/config")
			assertEventField(t, event, "encrypted_body_direction", test.direction)
			assertEventField(t, event, "encrypted_body_source_field", test.field)
			assertEventField(t, event, "encrypted_body_byte_length", 146)
			assertEventField(t, event, "plaintext_byte_length", 89)
			assertEventField(t, event, "plaintext_sha256", archiveHash)
			assertEventField(t, evidence, "ciphertext_retained", false)
		})
	}
}

func TestSIOEvidenceRejectsMutatedOrAmbiguousEvents(t *testing.T) {
	valid := serverEvent{
		"kind":                      "request",
		"method":                    "GET",
		"path":                      "/minio/admin/v3/config",
		"request_content_length":    float64(0),
		"response_body_byte_length": float64(146),
		"plaintext_byte_length":     float64(89),
		"plaintext_sha256":          digest([]byte(archive)),
	}

	mutatedLength := cloneEvent(valid)
	mutatedLength["response_body_byte_length"] = float64(145)
	mutatedHash := cloneEvent(valid)
	mutatedHash["plaintext_sha256"] = digest([]byte("not the captured archive"))

	tests := map[string][]serverEvent{
		"encrypted length mutated": {mutatedLength},
		"plaintext hash mutated":   {mutatedHash},
		"extra request event":      {valid, cloneEvent(valid)},
	}

	for name, events := range tests {
		t.Run(name, func(t *testing.T) {
			if evidence, err := sioEvidenceFromServerEvents(events); err == nil {
				t.Fatalf("evidence = %#v, want an error", evidence)
			}
		})
	}
}

func TestContainsSecretReturnsFoundAndErrors(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "safe.json"), []byte("safe"), 0o600); err != nil {
		t.Fatal(err)
	}

	found, err := containsSecret(root, "credential-value")
	if err != nil || found {
		t.Fatalf("safe scan = (%v, %v), want (false, nil)", found, err)
	}
	if err := os.WriteFile(filepath.Join(root, "secret.json"), []byte("credential-value"), 0o600); err != nil {
		t.Fatal(err)
	}
	found, err = containsSecret(root, "credential-value")
	if err != nil || !found {
		t.Fatalf("secret scan = (%v, %v), want (true, nil)", found, err)
	}

	missing := filepath.Join(root, "missing")
	if found, err = containsSecret(missing, "credential-value"); err == nil {
		t.Fatalf("missing-root scan = (%v, nil), want an error", found)
	}
}

func TestContainsSecretPropagatesInjectedReadError(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "unreadable.json")
	if err := os.WriteFile(path, []byte("safe"), 0o600); err != nil {
		t.Fatal(err)
	}
	want := errors.New("injected read failure")

	found, err := containsSecretWithRead(root, "credential-value", func(string) ([]byte, error) {
		return nil, want
	})
	if found || !errors.Is(err, want) {
		t.Fatalf("injected read scan = (%v, %v), want (false, %v)", found, err, want)
	}
}

func assertEventField(t *testing.T, record map[string]any, key string, want any) {
	t.Helper()
	if record[key] != want {
		t.Fatalf("%s = %#v, want %#v", key, record[key], want)
	}
}

func cloneEvent(event serverEvent) serverEvent {
	clone := serverEvent{}
	for key, value := range event {
		clone[key] = value
	}
	return clone
}
