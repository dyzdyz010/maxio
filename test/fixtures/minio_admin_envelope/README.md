# MinIO Admin envelope interoperability evidence

本目录只保存协议证据，不包含运行时 Go 依赖，也不声称这里的公开测试密码、salt 或 nonce 可用于生产。

## 固定来源

- madmin-go `v3.0.109`，commit [`6897865311e2be91d814ea0ef4814a730d87d1cd`](https://github.com/minio/madmin-go/tree/6897865311e2be91d814ea0ef4814a730d87d1cd)。信封实现是 [`encrypt.go`](https://github.com/minio/madmin-go/blob/6897865311e2be91d814ea0ef4814a730d87d1cd/encrypt.go)。
- secure-io/sio-go `v0.3.1`，commit [`a455d2cd8fcacdfe18557d117db15c0629fb7e2c`](https://github.com/secure-io/sio-go/tree/a455d2cd8fcacdfe18557d117db15c0629fb7e2c)。官方向量源是 [`test_vectors.json`](https://github.com/secure-io/sio-go/blob/a455d2cd8fcacdfe18557d117db15c0629fb7e2c/test_vectors.json)，分帧实现见 [`sio.go`](https://github.com/secure-io/sio-go/blob/a455d2cd8fcacdfe18557d117db15c0629fb7e2c/sio.go) 和 [`writer.go`](https://github.com/secure-io/sio-go/blob/a455d2cd8fcacdfe18557d117db15c0629fb7e2c/writer.go)。
- madmin-go 该 tag 固定 `golang.org/x/crypto v0.37.0`；Argon2id 参数及原始 key 生成语义见 [`argon2/argon2.go`](https://github.com/golang/crypto/blob/v0.37.0/argon2/argon2.go)。

本目录文件 SHA-256：

- `v3_0_109_vectors.json`: `4c32a34b98b1042706177433db5cdb4f7aa9e3a5b7256d2cebd7865af388dee9`
- `sio_v0_3_1_vectors.json`: `ce85bb077e624787c7414d6b9be3b2b067b9f2c303747c61574976817b702a90`

第二个文件是固定 commit 中 canonical Git blob 的 LF、逐字节副本，没有改名字段、重排或重写 JSON。它是 8,283 bytes，不含 CRLF；SHA-256 如上，Git blob OID 是 `b88d2960352827d3ce917542e61ae218305fa5ca`，与上游 commit 中 `test_vectors.json` 相同。不能以启用 `core.autocrlf` 的 Windows checkout 工作树字节作为 provenance oracle；那会得到 8,315-byte CRLF 文件。canonical 上游 blob 本身以 `]\n\n\n` 结束；byte-exact evidence 必须保留这些 LF。对 staged/no-index evidence diff 运行 whitespace gate 时，只对此文件关闭 `blank-at-eof`，其余 whitespace 规则仍保持启用。

## 信封和 framing 契约

madmin Admin API 信封是：

```text
salt[32] | algorithm_id[1] | base_nonce[8] | headerless secure-io ciphertext
```

算法 ID：

- `0`: Argon2id + AES-256-GCM
- `1`: Argon2id + ChaCha20-Poly1305（12-byte IETF nonce variant）
- `2`: PBKDF2-HMAC-SHA256 + AES-256-GCM

KDF 参数与 madmin-go `v3.0.109` 相同：

- Argon2id: version 19、`t=1`、`m=65536 KiB`、`p=4`、输出 32 bytes
- PBKDF2-HMAC-SHA256: 8192 iterations、输出 32 bytes

secure-io 默认明文 frame 是 16,384 bytes，每个 AEAD tag 是 16 bytes。完整 nonce 为 `base_nonce[8] || uint32_le(sequence)`。sequence 0 用空明文计算 binding tag；数据从 sequence 1 开始。每个数据 frame 的 AAD 是 `marker[1] || binding_tag[16]`，非末帧 marker 为 `0x00`，末帧为 `0x80`。流本身没有 MinIO DARE v2 package header。空明文仍产生一个 16-byte final tag。

因此长度公式是：

```text
41 + plaintext_length + 16 * max(1, ceil(plaintext_length / 16384))
```

这里的目标是 `github.com/secure-io/sio-go v0.3.1`，不是 `github.com/minio/sio` DARE v2。

## `v3_0_109_vectors.json`

该文件包含 18 条确定性向量：三个算法 ID 分别覆盖明文长度 `0, 1, 16383, 16384, 16385, 32768`。所有向量使用公开、仅供测试的固定输入：

```text
password = maxio-madmin-v3.0.109-public-fixture-password
salt     = 000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
nonce    = 2021222324252627
byte[i]  = (i * 31 + 17) mod 256
```

同一 password/salt/nonce 的重复使用只为得到可复现已知答案，生产代码不得照做。

字段解释：

- `algorithm_id`, `kdf`, `cipher`: madmin 算法选择。
- `expected_plaintext_hex`, `expected_plaintext_sha256`: 解密预期值。
- `derived_key_hex`: KDF 的 32-byte 原始输出，用于定位 KDF/hex 解码错误；它对应公开 fixture 密码，不是生产秘密。
- `frame_count`, `expected_envelope_length`: 16 KiB framing 边界证据。
- `envelope_hex`, `envelope_sha256`: 完整 41-byte header 加 headerless SIO ciphertext。
- `oracle`: 生成时该信封已经由固定版本原版 `madmin.DecryptData` 成功解密并与预期明文逐字节比较。

同一条向量支持两个方向：

1. Go 到 Elixir：Elixir 解密 `envelope_hex`，必须得到 `expected_plaintext_hex`。
2. Elixir 到 Go：给 Elixir 加密入口注入相同测试 salt、nonce 和 ID，输出必须逐字节等于 `envelope_hex`；该字节串已被原版 `madmin.DecryptData` 接受。

### 为什么不用 `madmin.EncryptData` 直接生成固定向量

公开 `EncryptData` 内部直接读取随机 salt/nonce，并依据 FIPS 状态及 `sioutil.NativeAES()` 选择算法；它没有 RNG 或算法注入参数。因此公开 API 无法同时固定 salt/nonce 并可靠强制 ID 0/1/2。

生成器只在仓库外临时目录中存在。它逐字实现 `encrypt.go` 的确定性部分，直接调用同一固定 module graph 中的 `argon2.IDKey`、`pbkdf2.Key` 和 secure-io `EncryptWriter`。每条结果随后交给未修改的 `madmin-go v3.0.109` 公共 `DecryptData`。所以这些是来源等价、由原版解密器确认的 deterministic oracle；不是伪称为随机 `EncryptData` 的原始输出。

## `sio_v0_3_1_vectors.json`

这是 secure-io 官方文件的 28 条原始向量：

- 14 条 AES-128-GCM
- 14 条 XChaCha20-Poly1305
- `BufSize` 为 16 或 17

它们验证 secure-io 通用的 headerless stream、binding tag、AAD、nonce sequence、final marker 和分帧语义。它们不直接覆盖 madmin 所用的 AES-256-GCM、普通 ChaCha20-Poly1305 或默认 16 KiB buffer；这些精确组合由 `v3_0_109_vectors.json` 覆盖。测试不得把官方文件中的 XChaCha 20-byte base nonce误当成 madmin 的 8-byte base nonce。

转录时应从固定 commit 的 Git blob 提取原始 bytes，或在禁用换行转换的环境中复制；不要从启用 `core.autocrlf` 的 Windows working tree 复制。可用 `git rev-parse a455d2cd8fcacdfe18557d117db15c0629fb7e2c:test_vectors.json` 核对 blob OID，并对目标文件同时检查 8,283-byte 大小、零 CRLF 和上述 SHA-256。

## 工具链和 module sums

生成使用 madmin-go 自身 `go.mod` 指定的官方工具链：

```text
go version go1.24.2 windows/amd64
go1.24.2.windows-amd64.zip SHA-256:
29c553aabee0743e2ffa3e9fa0cda00ef3b3cc4ff0bc92007f31f80fd69892e1
```

压缩包和校验值来自 `https://go.dev/dl/?mode=json&include=all`。

直接 module sums：

```text
github.com/minio/madmin-go/v3 v3.0.109
  h1:hRHlJ6yaIB3tlIj5mz9L9mGcyLC37S9qL1WtFrRtyQ0=
  go.mod h1:WOe2kYmYl1OIlY2DSRHVQ8j1v4OItARQ6jGyQqcCud8=

github.com/secure-io/sio-go v0.3.1
  h1:dNvY9awjabXTYGsTF1PiCySl9Ltofk9GA3VdWlo7rRc=
  go.mod h1:+xbkjDzPjwh4Axd07pRKSNriS9SCiYksWnZqdnfpQxs=

golang.org/x/crypto v0.37.0
  h1:kJNSjF/Xp7kU0iB2Z+9viTPMW4EqqsrywMXLJOOsXSE=
  go.mod h1:vg+k43peMZ0pUMhYmVAWysMK35e6ioLh3wB8ZCAfbVc=
```

`go mod download -json` 还确认 madmin tag 的 VCS origin hash 是 `6897865311e2be91d814ea0ef4814a730d87d1cd`，`x/crypto v0.37.0` 的 origin hash 是 `959f8f3db0fb8c3fb1f9507101058dda21e1fdcf`。

## 可复现命令

在仓库外临时目录创建下述 `go.mod` 和 `main.go` 后运行：

```powershell
$go = '<verified-go1.24.2>\go\bin\go.exe'
& $go fmt .
& $go mod tidy
& $go mod download -json `
  github.com/minio/madmin-go/v3@v3.0.109 `
  github.com/secure-io/sio-go@v0.3.1 `
  golang.org/x/crypto@v0.37.0
& $go run . v3_0_109_vectors.json
& $go run . v3_0_109_vectors.second.json
Get-FileHash -Algorithm SHA256 `
  v3_0_109_vectors.json, v3_0_109_vectors.second.json
```

两次输出 SHA-256 都是 `4c32a34b98b1042706177433db5cdb4f7aa9e3a5b7256d2cebd7865af388dee9`。

固定 secure-io checkout 中运行：

```powershell
git checkout --detach a455d2cd8fcacdfe18557d117db15c0629fb7e2c
& $go test ./...
```

生成时结果为：

```text
ok github.com/secure-io/sio-go
ok github.com/secure-io/sio-go/sioutil
```

### `go.mod`

```go
module maxio.local/admin-envelope-vector-generator

go 1.24.0

toolchain go1.24.2

require (
	github.com/minio/madmin-go/v3 v3.0.109
	github.com/secure-io/sio-go v0.3.1
	golang.org/x/crypto v0.37.0
)
```

### `main.go`

下列源文件经 `gofmt` 后 SHA-256 为 `bb2506092fb63dba878c48aa13f835101944ccfaf6a515a9f2eaef28e674aaf7`。

```go
package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"

	madmin "github.com/minio/madmin-go/v3"
	"github.com/secure-io/sio-go"
	"golang.org/x/crypto/argon2"
	"golang.org/x/crypto/pbkdf2"
)

const (
	password = "maxio-madmin-v3.0.109-public-fixture-password"
	bufSize  = 1 << 14
	tagSize  = 16
)

var (
	salt  = mustHex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
	nonce = mustHex("2021222324252627")
)

type document struct {
	Format              string   `json:"format"`
	Generator           string   `json:"generator"`
	GeneratorCommit     string   `json:"generator_commit"`
	SIOCommit           string   `json:"sio_commit"`
	Password            string   `json:"password_utf8"`
	SaltHex             string   `json:"salt_hex"`
	BaseNonceHex        string   `json:"base_nonce_hex"`
	PlaintextDefinition string   `json:"plaintext_definition"`
	Vectors             []vector `json:"vectors"`
}

type vector struct {
	Name                  string `json:"name"`
	AlgorithmID           int    `json:"algorithm_id"`
	KDF                   string `json:"kdf"`
	Cipher                string `json:"cipher"`
	PlaintextLength       int    `json:"plaintext_length"`
	PlaintextHex          string `json:"expected_plaintext_hex"`
	PlaintextSHA256       string `json:"expected_plaintext_sha256"`
	DerivedKeyHex         string `json:"derived_key_hex"`
	FrameCount            int    `json:"frame_count"`
	ExpectedEnvelopeBytes int    `json:"expected_envelope_length"`
	EnvelopeHex           string `json:"envelope_hex"`
	EnvelopeSHA256        string `json:"envelope_sha256"`
	Oracle                string `json:"oracle"`
}

func main() {
	if len(os.Args) != 2 {
		panic("usage: generator OUTPUT.json")
	}

	doc := document{
		Format:              "madmin-go-v3.0.109-envelope-v1",
		Generator:           "temporary deterministic Go generator recorded in README.md",
		GeneratorCommit:     "6897865311e2be91d814ea0ef4814a730d87d1cd",
		SIOCommit:           "a455d2cd8fcacdfe18557d117db15c0629fb7e2c",
		Password:            password,
		SaltHex:             hex.EncodeToString(salt),
		BaseNonceHex:        hex.EncodeToString(nonce),
		PlaintextDefinition: "byte[i] = (i*31 + 17) mod 256 for zero-based i",
	}

	lengths := []int{0, 1, 16383, 16384, 16385, 32768}
	for id := 0; id <= 2; id++ {
		for _, n := range lengths {
			v, err := makeVector(id, n)
			if err != nil {
				panic(err)
			}
			doc.Vectors = append(doc.Vectors, v)
		}
	}

	data, err := json.MarshalIndent(doc, "", "  ")
	if err != nil {
		panic(err)
	}
	data = append(data, '\n')
	if err := os.WriteFile(os.Args[1], data, 0o644); err != nil {
		panic(err)
	}
}

func makeVector(id, n int) (vector, error) {
	plain := makePlaintext(n)
	key, kdf, algorithm, err := deriveKey(id)
	if err != nil {
		return vector{}, err
	}

	stream, err := algorithm.Stream(key)
	if err != nil {
		return vector{}, err
	}
	if stream.NonceSize() != len(nonce) {
		return vector{}, fmt.Errorf("id %d nonce size = %d", id, stream.NonceSize())
	}

	var out bytes.Buffer
	out.Write(salt)
	out.WriteByte(byte(id))
	out.Write(nonce)
	w := stream.EncryptWriter(&out, nonce, nil)
	if _, err := w.Write(plain); err != nil {
		return vector{}, err
	}
	if err := w.Close(); err != nil {
		return vector{}, err
	}
	ciphertext := out.Bytes()

	decrypted, err := madmin.DecryptData(password, bytes.NewReader(ciphertext))
	if err != nil {
		return vector{}, fmt.Errorf("madmin DecryptData id=%d length=%d: %w", id, n, err)
	}
	if !bytes.Equal(decrypted, plain) {
		return vector{}, fmt.Errorf("madmin DecryptData mismatch id=%d length=%d", id, n)
	}

	frames := max(1, (n+bufSize-1)/bufSize)
	expectedLen := 32 + 1 + 8 + n + tagSize*frames
	if len(ciphertext) != expectedLen {
		return vector{}, fmt.Errorf("length mismatch id=%d plaintext=%d actual=%d expected=%d", id, n, len(ciphertext), expectedLen)
	}

	plainHash := sha256.Sum256(plain)
	cipherHash := sha256.Sum256(ciphertext)
	return vector{
		Name:                  fmt.Sprintf("id%d_len%d", id, n),
		AlgorithmID:           id,
		KDF:                   kdf,
		Cipher:                algorithm.String(),
		PlaintextLength:       n,
		PlaintextHex:          hex.EncodeToString(plain),
		PlaintextSHA256:       hex.EncodeToString(plainHash[:]),
		DerivedKeyHex:         hex.EncodeToString(key),
		FrameCount:            frames,
		ExpectedEnvelopeBytes: expectedLen,
		EnvelopeHex:           hex.EncodeToString(ciphertext),
		EnvelopeSHA256:        hex.EncodeToString(cipherHash[:]),
		Oracle:                "accepted_by_madmin_go_v3.0.109_DecryptData",
	}, nil
}

func deriveKey(id int) ([]byte, string, sio.Algorithm, error) {
	switch id {
	case 0:
		return argon2.IDKey([]byte(password), salt, 1, 64*1024, 4, 32),
			"Argon2id(v=19,t=1,m=65536KiB,p=4,L=32)", sio.AES_256_GCM, nil
	case 1:
		return argon2.IDKey([]byte(password), salt, 1, 64*1024, 4, 32),
			"Argon2id(v=19,t=1,m=65536KiB,p=4,L=32)", sio.ChaCha20Poly1305, nil
	case 2:
		return pbkdf2.Key([]byte(password), salt, 8192, 32, sha256.New),
			"PBKDF2-HMAC-SHA256(iterations=8192,L=32)", sio.AES_256_GCM, nil
	default:
		return nil, "", "", fmt.Errorf("unsupported algorithm id %d", id)
	}
}

func makePlaintext(n int) []byte {
	p := make([]byte, n)
	for i := range p {
		p[i] = byte((i*31 + 17) & 0xff)
	}
	return p
}

func mustHex(s string) []byte {
	b, err := hex.DecodeString(s)
	if err != nil {
		panic(err)
	}
	return b
}
```

## 已执行验证

- 两个 JSON 均可由 PowerShell `ConvertFrom-Json` 完整解析。
- madmin 文件恰有 18 条，算法 ID 0/1/2 各 6 条，并且每组长度恰为计划要求的六个边界值。
- 每条 plaintext hex、SHA-256、生成公式、salt、ID、nonce、frame count、信封长度和信封 SHA-256 均重新计算核对。
- 每条信封均由未修改的 `madmin.DecryptData` 解密验证。
- 同一生成器运行两次，输出字节和 SHA-256 完全相同。
- 官方 SIO 文件是 8,283-byte canonical LF blob、零 CRLF，恰有 28 条，分为 14 条 AES-128-GCM 与 14 条 XChaCha20-Poly1305；其 Git blob OID 与固定上游 commit 相同，固定 checkout 的 `go test ./...` 通过。

正式 Elixir 实现仍须运行实际的 Go-to-Elixir / Elixir-to-Go 测试；本 evidence pack 不把尚未发生的 Elixir 执行伪装成已验证结果。
