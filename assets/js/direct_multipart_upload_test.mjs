import assert from "node:assert/strict"
import DirectMultipartUpload, {
  collectAdvancedFields,
  duplicateTargetKeys,
  normalizeConcurrency,
  parseListParts,
  storageSafeSession,
  validStoredSession,
  validateRemoteParts,
  withConcurrency,
} from "./direct_multipart_upload.js"

class FakeElement {
  constructor(tagName, text = "", children = []) {
    this.tagName = tagName
    this._text = text
    this.children = children
  }

  get textContent() {
    if(this.children.length === 0){
      return this._text
    }

    return this.children.map(child => child.textContent).join("")
  }

  getElementsByTagName(tagName) {
    const matches = []
    const visit = node => {
      for(const child of node.children){
        if(child.tagName === tagName){
          matches.push(child)
        }
        visit(child)
      }
    }

    visit(this)
    return matches
  }
}

class FakeDocument extends FakeElement {
  get documentElement() {
    return this.children[0] || null
  }
}

class FakeInput {
  constructor(value = "", checked = false) {
    this.value = value
    this.checked = checked
  }
}

class FakeRoot {
  constructor(fields = {}) {
    this.fields = fields
  }

  querySelector(selector) {
    const match = selector.match(/\[data-role='([^']+)'\]/)
    return match ? this.fields[match[1]] || null : null
  }
}

function elementFromText(xml, tagName) {
  const match = xml.match(new RegExp(`<${tagName}>([\\s\\S]*?)</${tagName}>`))
  return match ? new FakeElement(tagName, match[1]) : null
}

class FakeDOMParser {
  parseFromString(xml) {
    if(xml.includes("<parsererror")){
      return new FakeElement("Document", "", [new FakeElement("parsererror")])
    }

    const rootMatches = Array.from(xml.matchAll(/<ListPartsResult\b[^>]*>([\s\S]*?)<\/ListPartsResult>/g))
    const roots = rootMatches.map(match => {
      const body = match[1]
      const children = [
        elementFromText(body, "IsTruncated"),
        elementFromText(body, "NextPartNumberMarker"),
        ...Array.from(body.matchAll(/<Part>([\s\S]*?)<\/Part>/g)).map(partMatch => {
          const partBody = partMatch[1]
          return new FakeElement("Part", "", [
            elementFromText(partBody, "PartNumber"),
            elementFromText(partBody, "ETag"),
            elementFromText(partBody, "Size"),
          ].filter(Boolean))
        }),
      ].filter(Boolean)

      return new FakeElement("ListPartsResult", "", children)
    })

    if(xml.startsWith("<Wrapper>")){
      return new FakeDocument("Document", "", [new FakeElement("Wrapper", "", roots)])
    }

    return new FakeDocument("Document", "", roots)
  }
}

globalThis.DOMParser = FakeDOMParser

function wait(ms) {
  return new Promise(resolve => setTimeout(resolve, ms))
}

assert.equal(normalizeConcurrency("4", 2), 4)
assert.equal(normalizeConcurrency(2.8, 1), 2)
assert.equal(normalizeConcurrency("0", 2), 2)
assert.equal(normalizeConcurrency("not-a-number", 2), 2)
assert.deepEqual(duplicateTargetKeys([{name: "a.bin"}, {name: "b.bin"}], "docs/"), [])
assert.deepEqual(
  duplicateTargetKeys([{name: "a.bin"}, {name: "a.bin"}, {name: "b.bin"}], "docs/"),
  ["docs/a.bin"]
)

let activeWorkers = 0
let maxActiveWorkers = 0
const processedItems = []

await withConcurrency([1, 2, 3, 4, 5], 2, async item => {
  activeWorkers += 1
  maxActiveWorkers = Math.max(maxActiveWorkers, activeWorkers)
  await wait(item === 1 ? 15 : 5)
  processedItems.push(item)
  activeWorkers -= 1
})

assert.equal(maxActiveWorkers, 2)
assert.deepEqual([...processedItems].sort((a, b) => a - b), [1, 2, 3, 4, 5])

const failedConcurrencyStarted = []
const failedConcurrencySettled = []
await assert.rejects(
  withConcurrency([1, 2, 3, 4], 2, async item => {
    failedConcurrencyStarted.push(item)
    if(item === 1){
      await wait(5)
      failedConcurrencySettled.push(item)
      throw new Error("part failed")
    }

    await wait(15)
    failedConcurrencySettled.push(item)
  }),
  /part failed/
)
assert.deepEqual([...failedConcurrencyStarted].sort((a, b) => a - b), [1, 2])
assert.deepEqual([...failedConcurrencySettled].sort((a, b) => a - b), [1, 2])

const queueHook = {
  ...DirectMultipartUpload,
  fileConcurrency: 2,
  activeBatch: null,
  paused: false,
  pauseWaiters: [],
  setStatus() {},
  setProgress() {},
}
const queuedFiles = [
  {name: "one.bin", size: 3},
  {name: "two.bin", size: 3},
  {name: "three.bin", size: 3},
  {name: "four.bin", size: 3},
]
const uploadBatch = queueHook.createBatch(queuedFiles)
queueHook.activeBatch = uploadBatch
let activeUploads = 0
let maxActiveUploads = 0
const uploadedFiles = []

queueHook.uploadFile = async file => {
  activeUploads += 1
  maxActiveUploads = Math.max(maxActiveUploads, activeUploads)
  await wait(file.name === "one.bin" ? 15 : 5)
  uploadedFiles.push(file.name)
  activeUploads -= 1
}

await queueHook.runFileQueue(queuedFiles, uploadBatch)
assert.equal(maxActiveUploads, 2)
assert.equal(uploadBatch.completedFiles, 4)
assert.equal(uploadBatch.failedFiles, 0)
assert.deepEqual([...uploadedFiles].sort(), ["four.bin", "one.bin", "three.bin", "two.bin"])

const advancedRoot = new FakeRoot({
  "content-type": new FakeInput("application/custom"),
  "storage-class": new FakeInput("STANDARD_IA"),
  "cache-control": new FakeInput("max-age=3600"),
  "content-disposition": new FakeInput("attachment; filename=\"object.bin\""),
  "content-encoding": new FakeInput("gzip"),
  "expires": new FakeInput("Wed, 21 Oct 2037 07:28:00 GMT"),
  "metadata": new FakeInput("origin=console\nteam=storage"),
  "tagging": new FakeInput("env=prod\nteam=storage"),
  "sse-algorithm": new FakeInput("aws:kms"),
  "sse-kms-key-id": new FakeInput("alias/maxio-local"),
  "sse-context": new FakeInput("eyJ0ZW5hbnQiOiJjb25zb2xlIn0="),
  "sse-bucket-key": new FakeInput("", true),
  "sse-customer-key": new FakeInput("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="),
  "sse-customer-key-md5": new FakeInput("rL0Y20zC+Fzt72VPzMSk2A=="),
  "request-payer": new FakeInput("", true),
  "checksum-algorithm": new FakeInput("CRC32C"),
  "checksum-type": new FakeInput("COMPOSITE"),
})

assert.deepEqual(collectAdvancedFields(advancedRoot, {type: "text/plain"}), {
  content_type: "application/custom",
  storage_class: "STANDARD_IA",
  cache_control: "max-age=3600",
  content_disposition: "attachment; filename=\"object.bin\"",
  content_encoding: "gzip",
  expires: "Wed, 21 Oct 2037 07:28:00 GMT",
  metadata: "origin=console\nteam=storage",
  tagging: "env=prod\nteam=storage",
  sse_algorithm: "aws:kms",
  sse_kms_key_id: "alias/maxio-local",
  sse_context: "eyJ0ZW5hbnQiOiJjb25zb2xlIn0=",
  sse_bucket_key: true,
  sse_customer_key: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
  sse_customer_key_md5: "rL0Y20zC+Fzt72VPzMSk2A==",
  request_payer: true,
  checksum_algorithm: "CRC32C",
  checksum_type: "COMPOSITE",
})

assert.equal(
  collectAdvancedFields(new FakeRoot(), {type: "text/plain"}).content_type,
  "text/plain"
)

assert.equal(
  collectAdvancedFields(new FakeRoot(), {type: ""}).content_type,
  "application/octet-stream"
)

const storedSession = {
  upload_id: "upload-1",
  part_size: 3,
  request_payer: false,
  sse_customer_key_required: true,
  uploaded_parts: [],
}

assert.equal(validStoredSession(storedSession), true)
assert.equal(validStoredSession({...storedSession, sse_customer_key: "secret"}), false)
assert.equal(
  validStoredSession({...storedSession, nested: {sse_customer_key_md5: "secret-md5"}}),
  false
)
assert.equal(
  validStoredSession({
    ...storedSession,
    headers: [{"name": "x-amz-server-side-encryption-customer-key", "value": "secret"}],
  }),
  false
)
assert.equal(
  validStoredSession({
    ...storedSession,
    create: {
      headers: {
        "X-Amz-Server-Side-Encryption-Customer-Key-MD5": "secret-md5",
      },
    },
  }),
  false
)

assert.deepEqual(storageSafeSession({
  ...storedSession,
  sse_customer_key: "secret",
  headers: [
    {name: "content-type", value: "application/octet-stream"},
    {name: "x-amz-server-side-encryption-customer-key", value: "secret"},
  ],
  nested: {
    "X-Amz-Server-Side-Encryption-Customer-Key-MD5": "secret-md5",
    sse_customer_key_md5: "secret-md5",
    kept: true,
  },
}), {
  upload_id: "upload-1",
  part_size: 3,
  request_payer: false,
  sse_customer_key_required: true,
  uploaded_parts: [],
  headers: [{name: "content-type", value: "application/octet-stream"}],
  nested: {kept: true},
})

function listPartsXml(parts, extra = "") {
  return `<ListPartsResult>${parts.map(part => `<Part>${part}</Part>`).join("")}${extra}<IsTruncated>false</IsTruncated><NextPartNumberMarker>0</NextPartNumberMarker></ListPartsResult>`
}

function assertThrowsMessage(fn, pattern) {
  assert.throws(fn, error => pattern.test(error.message))
}

const file = {size: 6}

let parsed = parseListParts(listPartsXml([
  "<PartNumber>1</PartNumber><ETag>\"900150983cd24fb0d6963f7d28e17f72\"</ETag><Size>3</Size>",
  "<PartNumber>2</PartNumber><ETag>\"4ed9407630eb1000c0f6b63842defa7d\"</ETag><Size>3</Size>",
]))
validateRemoteParts(parsed.parts, file, 3)
assert.equal(parsed.parts.length, 2)

parsed = parseListParts(listPartsXml([
  "<PartNumber>1</PartNumber><ETag>\"900150983cd24fb0d6963f7d28e17f72\"</ETag><Size>3</Size>",
  "<PartNumber>2</PartNumber><Size>3</Size>",
]))
assert.equal(parsed.parts.length, 2)
assertThrowsMessage(() => validateRemoteParts(parsed.parts, file, 3), /invalid ETag/)

parsed = parseListParts(listPartsXml([
  "<PartNumber>not-a-number</PartNumber><ETag>\"900150983cd24fb0d6963f7d28e17f72\"</ETag><Size>3</Size>",
]))
assertThrowsMessage(() => validateRemoteParts(parsed.parts, file, 3), /out-of-range/)

parsed = parseListParts(listPartsXml([
  "<PartNumber>1</PartNumber><ETag>\"900150983cd24fb0d6963f7d28e17f72\"</ETag><Size>3</Size>",
  "<PartNumber>1</PartNumber><ETag>\"4ed9407630eb1000c0f6b63842defa7d\"</ETag><Size>3</Size>",
]))
assertThrowsMessage(() => validateRemoteParts(parsed.parts, file, 3), /duplicate/)

parsed = parseListParts(listPartsXml([
  "<PartNumber>2</PartNumber><ETag>\"4ed9407630eb1000c0f6b63842defa7d\"</ETag><Size>2</Size>",
]))
assertThrowsMessage(() => validateRemoteParts(parsed.parts, file, 3), /part size/)

assertThrowsMessage(
  () => parseListParts("<ListPartsResult></ListPartsResult><ListPartsResult></ListPartsResult>"),
  /invalid XML/
)

assertThrowsMessage(
  () => parseListParts(`<Wrapper>${listPartsXml([
    "<PartNumber>1</PartNumber><ETag>\"900150983cd24fb0d6963f7d28e17f72\"</ETag><Size>3</Size>",
  ])}</Wrapper>`),
  /invalid XML/
)
