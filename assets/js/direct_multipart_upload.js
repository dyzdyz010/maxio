const DEFAULT_PART_SIZE = 8 * 1024 * 1024
const DEFAULT_EXPIRES = 900
const DEFAULT_CONCURRENCY = 3
const DEFAULT_FILE_CONCURRENCY = 2
const PART_RETRY_ATTEMPTS = 3
const SIGN_PART_BATCH_SIZE = 64
const LIST_PARTS_PAGE_SIZE = 1000

function csrfToken() {
  return document.querySelector("meta[name='csrf-token']")?.getAttribute("content") || ""
}

function encodeKeyPath(key) {
  return key.split("/").map(encodeURIComponent).join("/")
}

function headersFromList(headers) {
  return Object.fromEntries((headers || []).map(({name, value}) => [name, value]))
}

function fieldByRole(root, role) {
  return root?.querySelector?.(`[data-role='${role}']`) || null
}

function fieldValue(root, role) {
  return (fieldByRole(root, role)?.value || "").trim()
}

function fieldChecked(root, role) {
  return Boolean(fieldByRole(root, role)?.checked)
}

export function collectAdvancedFields(root, file, defaultContentType = "application/octet-stream") {
  const contentType = fieldValue(root, "content-type") || file?.type || defaultContentType

  return {
    content_type: contentType || defaultContentType,
    storage_class: fieldValue(root, "storage-class"),
    cache_control: fieldValue(root, "cache-control"),
    content_disposition: fieldValue(root, "content-disposition"),
    content_encoding: fieldValue(root, "content-encoding"),
    expires: fieldValue(root, "expires"),
    metadata: fieldValue(root, "metadata"),
    tagging: fieldValue(root, "tagging"),
    sse_algorithm: fieldValue(root, "sse-algorithm"),
    sse_kms_key_id: fieldValue(root, "sse-kms-key-id"),
    sse_context: fieldValue(root, "sse-context"),
    sse_bucket_key: fieldChecked(root, "sse-bucket-key"),
    sse_customer_key: fieldValue(root, "sse-customer-key"),
    sse_customer_key_md5: fieldValue(root, "sse-customer-key-md5"),
    request_payer: fieldChecked(root, "request-payer"),
    checksum_algorithm: fieldValue(root, "checksum-algorithm"),
    checksum_type: fieldValue(root, "checksum-type"),
  }
}

function collectSseCustomerFields(root) {
  const sse_customer_key = fieldValue(root, "sse-customer-key")
  const sse_customer_key_md5 = fieldValue(root, "sse-customer-key-md5")

  if(!sse_customer_key && !sse_customer_key_md5){
    return null
  }

  return {sse_customer_key, sse_customer_key_md5}
}

function parseUploadId(xml) {
  const document = new DOMParser().parseFromString(xml, "application/xml")
  return document.getElementsByTagName("UploadId")[0]?.textContent || null
}

function textOf(parent, tagName) {
  return parent.getElementsByTagName(tagName)[0]?.textContent || ""
}

function directChildren(parent, tagName) {
  return Array.from(parent.children || []).filter(child => child.tagName === tagName)
}

export function parseListParts(xml) {
  const document = new DOMParser().parseFromString(xml, "application/xml")
  const roots = Array.from(document.getElementsByTagName("ListPartsResult"))
  if(document.getElementsByTagName("parsererror").length > 0 ||
      roots.length !== 1 ||
      document.documentElement?.tagName !== "ListPartsResult"){
    throw new Error("S3 ListParts returned invalid XML")
  }

  const root = roots[0]
  const parts = directChildren(root, "Part").map(part => ({
    part_number: Number(textOf(part, "PartNumber")),
    etag: textOf(part, "ETag").replace(/^"|"$/g, ""),
    size: Number(textOf(part, "Size") || "0"),
  }))

  return {
    parts,
    is_truncated: textOf(root, "IsTruncated") === "true",
    next_part_number_marker: Number(textOf(root, "NextPartNumberMarker") || "0"),
  }
}

async function jsonRequest(url, body, options = {}) {
  const response = await fetch(url, {
    method: "POST",
    credentials: "same-origin",
    signal: options.signal,
    headers: {
      "accept": "application/json",
      "content-type": "application/json",
      "x-csrf-token": csrfToken(),
    },
    body: JSON.stringify(body || {}),
  })

  const contentType = response.headers.get("content-type") || ""
  const payload = contentType.includes("application/json") ? await response.json().catch(() => ({})) : {}
  if(!response.ok){
    throw new Error(payload.message || payload.error || `Console API failed (${response.status})`)
  }
  if(!contentType.includes("application/json")){
    throw new Error("Console API returned a non-JSON response")
  }
  return payload
}

async function signedRequest(request, body, options = {}) {
  const response = await fetch(request.url, requestOptions(request, body, options))

  if(!response.ok){
    const text = await response.text().catch(() => "")
    throw new Error(`S3 ${request.method} failed (${response.status}) ${text}`.trim())
  }

  return response
}

async function signedRequestWithRetry(request, body, attempts = PART_RETRY_ATTEMPTS, options = {}) {
  let lastError

  for(let attempt = 1; attempt <= attempts; attempt++){
    let response

    try {
      response = await fetch(request.url, requestOptions(request, body, options))
    } catch (error) {
      if(isAbortError(error)){
        throw error
      }

      lastError = error
      if(attempt === attempts){
        throw error
      }

      await delay(200 * attempt * attempt)
      continue
    }

    if(response.ok){
      return response
    }

    const text = await response.text().catch(() => "")
    lastError = new Error(`S3 ${request.method} failed (${response.status}) ${text}`.trim())

    if(!retryableStatus(response.status) || attempt === attempts){
      throw lastError
    }

    await delay(200 * attempt * attempt)
  }

  throw lastError
}

function requestOptions(request, body, options = {}) {
  const requestOptions = {
    method: request.method,
    headers: headersFromList(request.headers),
  }

  if(body != null && request.method !== "GET" && request.method !== "HEAD"){
    requestOptions.body = body
  }

  if(options.signal){
    requestOptions.signal = options.signal
  }

  return requestOptions
}

function retryableStatus(status) {
  return status === 408 || status === 429 || status === 500 || status === 502 ||
    status === 503 || status === 504
}

function delay(ms) {
  return new Promise(resolve => setTimeout(resolve, ms))
}

export function normalizeConcurrency(value, fallback = DEFAULT_CONCURRENCY) {
  const integer = Math.floor(Number(value))
  if(Number.isFinite(integer) && integer > 0){
    return integer
  }

  return fallback
}

function uploadedPartMap(parts) {
  return new Map((parts || []).map(part => [part.part_number, part]))
}

function sseCustomerSecretKey(key) {
  if(typeof key !== "string"){
    return false
  }

  const normalized = key.toLowerCase()
  return normalized === "sse_customer_key" ||
    normalized === "sse_customer_key_md5" ||
    normalized === "sse_customer_headers" ||
    normalized === "x-amz-server-side-encryption-customer-algorithm" ||
    normalized === "x-amz-server-side-encryption-customer-key" ||
    normalized === "x-amz-server-side-encryption-customer-key-md5" ||
    normalized === "x-amz-copy-source-server-side-encryption-customer-algorithm" ||
    normalized === "x-amz-copy-source-server-side-encryption-customer-key" ||
    normalized === "x-amz-copy-source-server-side-encryption-customer-key-md5"
}

function containsSseCustomerSecret(value) {
  if(!value || typeof value !== "object"){
    return false
  }

  if(sseCustomerSecretKey(value.name)){
    return true
  }

  if(Array.isArray(value)){
    return value.some(containsSseCustomerSecret)
  }

  return Object.entries(value).some(([key, child]) =>
    sseCustomerSecretKey(key) || containsSseCustomerSecret(child)
  )
}

function scrubSseCustomerSecrets(value) {
  if(!value || typeof value !== "object"){
    return value
  }

  if(sseCustomerSecretKey(value.name)){
    return undefined
  }

  if(Array.isArray(value)){
    return value
      .map(scrubSseCustomerSecrets)
      .filter(item => item !== undefined)
  }

  const result = {}
  for(const [key, child] of Object.entries(value)){
    if(sseCustomerSecretKey(key)){
      continue
    }

    const scrubbed = scrubSseCustomerSecrets(child)
    if(scrubbed !== undefined){
      result[key] = scrubbed
    }
  }

  return result
}

export function storageSafeSession(session) {
  return scrubSseCustomerSecrets(session || {})
}

export function validStoredSession(session) {
  return session &&
    typeof session.upload_id === "string" &&
    session.upload_id.length > 0 &&
    Number.isInteger(Number(session.part_size)) &&
    Number(session.part_size) > 0 &&
    Array.isArray(session.uploaded_parts) &&
    (session.request_payer == null || typeof session.request_payer === "boolean") &&
    (session.sse_customer_key_required == null ||
      typeof session.sse_customer_key_required === "boolean") &&
    !containsSseCustomerSecret(session)
}

function sseCustomerRequestFields(session, context) {
  if(!session?.sse_customer_key_required){
    return {}
  }

  if(!context?.sseCustomer?.sse_customer_key){
    throw new Error("SSE-C customer key is required to resume this multipart upload")
  }

  return context.sseCustomer
}

function directMultipartAbortError() {
  const error = new Error("Direct multipart upload aborted")
  error.name = "AbortError"
  return error
}

function isAbortError(error) {
  return error?.name === "AbortError"
}

function isNoSuchUploadError(error) {
  const message = error?.message || ""
  return message.includes("NoSuchUpload") ||
    message.includes("no_such_upload") ||
    message.includes("multipart upload not found")
}

function isRegisteredUploadNotFound(error) {
  const message = error?.message || ""
  return message.includes("registered_upload_not_found") ||
    message.includes("registered upload not found")
}

function validPartEtag(etag) {
  return typeof etag === "string" && /^[0-9a-fA-F]{32}$/.test(etag)
}

function expectedPartSize(file, partSize, partNumber, totalParts) {
  if(partNumber === totalParts){
    return file.size - (partNumber - 1) * partSize
  }

  return partSize
}

export function validateRemoteParts(parts, file, partSize) {
  const totalParts = Math.ceil(file.size / partSize)
  const seen = new Set()

  for(const part of parts){
    const partNumber = Number(part.part_number)
    const size = Number(part.size)

    if(!Number.isInteger(partNumber) || partNumber < 1 || partNumber > totalParts){
      throw new Error("S3 ListParts returned an out-of-range part")
    }

    if(seen.has(partNumber)){
      throw new Error("S3 ListParts returned duplicate parts")
    }

    if(!validPartEtag(part.etag)){
      throw new Error("S3 ListParts returned an invalid ETag")
    }

    if(size !== expectedPartSize(file, partSize, partNumber, totalParts)){
      throw new Error("S3 ListParts returned a part size that does not match the selected file")
    }

    seen.add(partNumber)
  }
}

export async function withConcurrency(items, limit, fn) {
  const queue = [...items]
  if(queue.length === 0){
    return
  }

  const errors = []
  const workerCount = Math.min(normalizeConcurrency(limit, 1), queue.length)
  const workers = Array.from({length: workerCount}, async () => {
    while(queue.length > 0){
      if(errors.length > 0){
        return
      }

      const item = queue.shift()

      try {
        await fn(item)
      } catch (error) {
        errors.push(error)
        return
      }
    }
  })
  await Promise.all(workers)

  if(errors.length > 0){
    throw errors[0]
  }
}

function chunks(items, size) {
  const result = []
  for(let index = 0; index < items.length; index += size){
    result.push(items.slice(index, index + size))
  }
  return result
}

export function duplicateTargetKeys(files, prefix = "") {
  const seen = new Set()
  const duplicates = []

  for(const file of files || []){
    const key = `${prefix}${file.name}`
    if(seen.has(key) && !duplicates.includes(key)){
      duplicates.push(key)
    }
    seen.add(key)
  }

  return duplicates
}

function uploadedBytesFromParts(parts, file, partSize) {
  const totalParts = Math.ceil(file.size / partSize)

  return (parts || []).reduce((total, part) => {
    const size = Number(part.size)
    if(Number.isFinite(size) && size >= 0){
      return total + size
    }

    const partNumber = Number(part.part_number)
    if(Number.isInteger(partNumber) && partNumber >= 1 && partNumber <= totalParts){
      return total + expectedPartSize(file, partSize, partNumber, totalParts)
    }

    return total
  }, 0)
}

function pluralize(count, singular, plural = `${singular}s`) {
  return count === 1 ? singular : plural
}

const DirectMultipartUpload = {
  mounted() {
    this.configure()
    this.input = this.el.querySelector("[data-role='file-input']")
    this.startButton = this.el.querySelector("[data-role='start']")
    this.pauseButton = this.el.querySelector("[data-role='pause']")
    this.resumeButton = this.el.querySelector("[data-role='resume']")
    this.abortButton = this.el.querySelector("[data-role='abort']")
    this.statusEl = this.el.querySelector("[data-role='status']")
    this.progressEl = this.el.querySelector("[data-role='progress']")
    this.activeBatch = null
    this.activeSession = null
    this.paused = false
    this.pauseWaiters = []

    this.startButton?.addEventListener("click", () => this.startSelected())
    this.pauseButton?.addEventListener("click", () => this.pauseActive())
    this.resumeButton?.addEventListener("click", () => this.resumeActive())
    this.abortButton?.addEventListener("click", () => this.abortActive())
  },

  updated() {
    this.configure()
  },

  configure() {
    this.bucket = this.el.dataset.bucket
    this.prefix = this.el.dataset.prefix || ""
    this.partSize = Number(this.el.dataset.partSize || DEFAULT_PART_SIZE)
    this.expiresIn = Number(this.el.dataset.expiresIn || DEFAULT_EXPIRES)
    this.concurrency = normalizeConcurrency(this.el.dataset.concurrency, DEFAULT_CONCURRENCY)
    this.fileConcurrency = normalizeConcurrency(
      this.el.dataset.fileConcurrency,
      DEFAULT_FILE_CONCURRENCY
    )
  },

  storageKey(key, file) {
    return `maxio:direct-multipart:${this.bucket}:${key}:${file.size}:${file.lastModified}`
  },

  consoleUrl(action, key) {
    return `/console/api/buckets/${encodeURIComponent(this.bucket)}/direct-multipart/${action}/${encodeKeyPath(key)}`
  },

  setStatus(text, level = "info") {
    if(this.statusEl){
      this.statusEl.textContent = text
      this.statusEl.dataset.level = level
    }
    window.__maxio?.log("direct multipart", {level, text})
  },

  setProgress(done, total) {
    if(this.progressEl){
      this.progressEl.max = total || 1
      this.progressEl.value = done
    }
  },

  async startSelected() {
    const files = Array.from(this.input?.files || [])
    if(files.length === 0){
      this.setStatus("No file selected", "error")
      return
    }

    const duplicates = duplicateTargetKeys(files, this.prefix)
    if(duplicates.length > 0){
      this.setStatus(`Duplicate selected object key: ${duplicates[0]}`, "error")
      return
    }

    const batch = this.createBatch(files)
    this.activeBatch = batch
    this.activeSession = null
    this.paused = false
    this.startButton.disabled = true
    this.setProgress(0, batch.totalBytes)
    this.updateBatchStatus(batch, `Queued ${files.length} ${pluralize(files.length, "file")}`)

    try {
      await this.runFileQueue(files, batch)
      this.input.value = ""
      this.setStatus(
        `Direct multipart upload complete (${batch.completedFiles}/${batch.totalFiles} files)`
      )
    } catch (error) {
      if(isAbortError(error)){
        this.setStatus("Direct multipart upload queue aborted")
      } else {
        this.setStatus(error.message || String(error), "error")
      }
    } finally {
      if(this.activeBatch === batch){
        this.activeBatch = null
      }
      this.activeSession = null
      this.paused = false
      this.releasePauseWaiters()
      this.startButton.disabled = false
    }
  },

  createBatch(files) {
    return {
      cancelled: false,
      contexts: new Set(),
      bytesByContext: new Map(),
      totalFiles: files.length,
      completedFiles: 0,
      failedFiles: 0,
      totalBytes: files.reduce((total, file) => total + Number(file.size || 0), 0),
      fileConcurrency: this.fileConcurrency,
    }
  },

  async runFileQueue(files, batch) {
    const failures = []

    await withConcurrency(files, batch.fileConcurrency, async file => {
      if(batch.cancelled){
        return
      }

      try {
        await this.waitWhilePaused(batch)
        if(batch.cancelled){
          return
        }

        this.updateBatchStatus(batch, `Uploading ${file.name}`)
        await this.uploadFile(file, batch)
        batch.completedFiles += 1
        this.updateBatchStatus(batch, `Uploaded ${file.name}`)
      } catch (error) {
        if(isAbortError(error) && batch.cancelled){
          return
        }

        batch.failedFiles += 1
        failures.push({file, error})
        this.updateBatchStatus(batch, `${file.name} failed`, "error")
      } finally {
        this.updateBatchProgress(batch)
      }
    })

    if(batch.cancelled){
      throw directMultipartAbortError()
    }

    if(failures.length > 0){
      const first = failures[0]
      throw new Error(
        `${failures.length} of ${batch.totalFiles} direct multipart uploads failed; ` +
          `first failure ${first.file.name}: ${first.error?.message || first.error}`
      )
    }
  },

  updateBatchStatus(batch, message, level = "info") {
    const active = batch.contexts.size
    const failed = batch.failedFiles > 0 ? `, ${batch.failedFiles} failed` : ""
    this.setStatus(
      `${message} - ${batch.completedFiles}/${batch.totalFiles} complete${failed}, ${active} active`,
      level
    )
  },

  updateContextProgress(context, bytes) {
    context.completedBytes = Math.max(0, Math.min(Number(bytes || 0), context.file.size))
    context.batch.bytesByContext.set(context, context.completedBytes)
    this.updateBatchProgress(context.batch)
  },

  updateBatchProgress(batch) {
    const done = Array.from(batch.bytesByContext.values()).reduce((total, bytes) => total + bytes, 0)
    this.setProgress(done, batch.totalBytes)
  },

  async uploadFile(file, batch) {
    const key = `${this.prefix}${file.name}`
    const context = {
      batch,
      key,
      file,
      session: null,
      sseCustomer: collectSseCustomerFields(this.el),
      cancelled: false,
      controllers: new Set(),
      completedBytes: 0,
    }
    batch.contexts.add(context)
    batch.bytesByContext.set(context, 0)
    this.activeSession = context

    try {
      const stored = this.loadSession(key, file)
      const registered = stored ? null : await this.lookupRegisteredSession(key, file, context)
      const resumable = stored || registered
      const resumed = Boolean(resumable)
      const session = resumable ? await this.reconcileSession(key, file, resumable, context) : await this.createSession(key, file, context)
      this.ensureActive(context)
      context.session = session

      const totalParts = Math.ceil(file.size / session.part_size)
      const uploaded = uploadedPartMap(session.uploaded_parts)
      const remaining = []

      for(let partNumber = 1; partNumber <= totalParts; partNumber++){
        if(!uploaded.has(partNumber)){
          remaining.push(partNumber)
        }
      }

      this.setStatus(`Uploading ${file.name}`)
      this.updateContextProgress(
        context,
        uploadedBytesFromParts(session.uploaded_parts, file, session.part_size)
      )

      if(remaining.length > 0){
        for(const partBatch of chunks(remaining, SIGN_PART_BATCH_SIZE)){
          this.ensureActive(context)
          const sign = await this.withUploadSignal(context, signal => jsonRequest(this.consoleUrl("sign-parts", key), {
            upload_id: session.upload_id,
            part_numbers: partBatch,
            expires_in: this.expiresIn,
            ...sseCustomerRequestFields(session, context),
          }, {signal}))
          this.ensureActive(context)

          const signedParts = new Map(sign.parts.map(part => [part.part_number, part]))

          await withConcurrency(partBatch, this.concurrency, async partNumber => {
            await this.waitWhilePaused(context)
            this.ensureActive(context)
            const start = (partNumber - 1) * session.part_size
            const end = Math.min(start + session.part_size, file.size)
            const response = await this.withUploadSignal(context, signal => signedRequestWithRetry(
              signedParts.get(partNumber),
              file.slice(start, end),
              PART_RETRY_ATTEMPTS,
              {signal}
            ))
            this.ensureActive(context)
            const etag = response.headers.get("etag")
            if(!etag){
              throw new Error("S3 response did not expose ETag; configure CORS ExposeHeaders for ETag")
            }

            uploaded.set(partNumber, {part_number: partNumber, etag, size: end - start})
            session.uploaded_parts = Array.from(uploaded.values()).sort((a, b) => a.part_number - b.part_number)
            this.saveSession(key, file, session, context)
            this.updateContextProgress(
              context,
              uploadedBytesFromParts(session.uploaded_parts, file, session.part_size)
            )
          })
        }
      }

      this.ensureActive(context)
      const completeSession = resumed ? await this.reconcileSession(key, file, session, context) : session
      const completedParts = Array.from(uploadedPartMap(completeSession.uploaded_parts).values()).sort((a, b) => a.part_number - b.part_number)
      if(completedParts.length !== totalParts){
        throw new Error("Multipart upload is missing parts after reconciliation")
      }
      const complete = await this.withUploadSignal(context, signal => jsonRequest(this.consoleUrl("complete", key), {
        upload_id: session.upload_id,
        parts: completedParts,
        expires_in: this.expiresIn,
        ...sseCustomerRequestFields(session, context),
      }, {signal}))
      this.ensureActive(context)

      await this.withUploadSignal(context, signal => signedRequest(complete.complete, complete.complete.body, {signal}))
      this.ensureActive(context)
      localStorage.removeItem(this.storageKey(key, file))
      this.updateContextProgress(context, file.size)
      this.pushEvent("direct_multipart_uploaded", {key})
    } catch (error) {
      if(isNoSuchUploadError(error)){
        localStorage.removeItem(this.storageKey(key, file))
      }
      throw error
    } finally {
      batch.contexts.delete(context)
      if(this.activeSession === context){
        this.activeSession = null
      }
    }
  },

  async createSession(key, file, context) {
    const advanced = collectAdvancedFields(this.el, file)
    const init = await this.withUploadSignal(context, signal => jsonRequest(this.consoleUrl("initiate", key), {
      size: file.size,
      part_size: this.partSize,
      expires_in: this.expiresIn,
      file_name: file.name,
      file_last_modified: file.lastModified,
      ...advanced,
    }, {signal}))
    this.ensureActive(context)

    const createResponse = await this.withUploadSignal(context, signal => signedRequest(init.create, "", {signal}))
    this.ensureActive(context)
    const createXml = await createResponse.text()
    const uploadId = parseUploadId(createXml)
    if(!uploadId){
      throw new Error("S3 CreateMultipartUpload response did not include UploadId")
    }

    const session = {
      upload_id: uploadId,
      part_size: init.part_size,
      request_payer: Boolean(init.request_payer),
      sse_customer_key_required: Boolean(init.sse_customer_key_required),
      uploaded_parts: [],
    }
    context.session = session
    this.saveSession(key, file, session, context)
    return session
  },

  async lookupRegisteredSession(key, file, context) {
    try {
      const payload = await this.withUploadSignal(context, signal => jsonRequest(this.consoleUrl("lookup", key), {
        size: file.size,
        file_last_modified: file.lastModified,
      }, {signal}))

      return payload.session || null
    } catch (error) {
      if(isRegisteredUploadNotFound(error)){
        return null
      }

      throw error
    }
  },

  async registerSession(key, file, session, context) {
    await this.withUploadSignal(context, signal => jsonRequest(this.consoleUrl("register", key), {
      upload_id: session.upload_id,
      size: file.size,
      part_size: session.part_size,
      file_name: file.name,
      file_last_modified: file.lastModified,
      request_payer: Boolean(session.request_payer),
    }, {signal}))
  },

  async reconcileSession(key, file, session, context) {
    if(!validStoredSession(session)){
      localStorage.removeItem(this.storageKey(key, file))
      throw new Error("Saved multipart upload state is invalid; start the upload again")
    }
    sseCustomerRequestFields(session, context)

    await this.registerSession(key, file, session, context)
    this.setStatus(`Reconciling ${file.name}`)
    const remoteParts = []
    let marker = 0

    try {
      while(true){
        this.ensureActive(context)
        const signed = await this.withUploadSignal(context, signal => jsonRequest(this.consoleUrl("list-parts", key), {
          upload_id: session.upload_id,
          part_number_marker: marker,
          max_parts: LIST_PARTS_PAGE_SIZE,
          expires_in: this.expiresIn,
        }, {signal}))

        const response = await this.withUploadSignal(context, signal => signedRequest(signed.list_parts, null, {signal}))
        const page = parseListParts(await response.text())
        remoteParts.push(...page.parts)

        if(!page.is_truncated){
          break
        }

        if(!page.next_part_number_marker || page.next_part_number_marker <= marker){
          throw new Error("S3 ListParts returned an invalid pagination marker")
        }

        marker = page.next_part_number_marker
      }
    } catch (error) {
      if(isNoSuchUploadError(error)){
        localStorage.removeItem(this.storageKey(key, file))
        throw new Error("Saved multipart upload no longer exists; start the upload again")
      }

      throw error
    }

    validateRemoteParts(remoteParts, file, Number(session.part_size))
    session.uploaded_parts = remoteParts.sort((a, b) => a.part_number - b.part_number)
    this.saveSession(key, file, session, context)
    this.updateContextProgress(
      context,
      uploadedBytesFromParts(session.uploaded_parts, file, session.part_size)
    )
    return session
  },

  pauseActive() {
    if(!this.activeBatch){
      this.setStatus("No active direct multipart upload", "error")
      return
    }

    this.paused = true
    this.setStatus("Direct multipart upload queue paused")
  },

  resumeActive() {
    if(!this.activeBatch){
      this.setStatus("No active direct multipart upload", "error")
      return
    }

    this.paused = false
    this.releasePauseWaiters()
    this.updateBatchStatus(this.activeBatch, "Resumed direct multipart upload queue")
  },

  waitWhilePaused(context) {
    if(!this.paused){
      return Promise.resolve()
    }

    return new Promise((resolve, reject) => this.pauseWaiters.push({context, resolve, reject}))
  },

  releasePauseWaiters(error = null) {
    const waiters = this.pauseWaiters.splice(0)
    waiters.forEach(waiter => {
      if(error){
        waiter.reject(error)
      } else {
        waiter.resolve()
      }
    })
  },

  loadSession(key, file) {
    const raw = localStorage.getItem(this.storageKey(key, file))
    if(!raw){
      return null
    }

    try {
      const session = JSON.parse(raw)
      if(validStoredSession(session)){
        return session
      }

      localStorage.removeItem(this.storageKey(key, file))
      return null
    } catch (_error) {
      localStorage.removeItem(this.storageKey(key, file))
      return null
    }
  },

  saveSession(key, file, session, context = null) {
    if(context){
      this.ensureActive(context)
    }
    localStorage.setItem(this.storageKey(key, file), JSON.stringify(storageSafeSession(session)))
  },

  ensureActive(context) {
    if(
      !context ||
      context.cancelled ||
      context.batch?.cancelled ||
      this.activeBatch !== context.batch
    ){
      throw directMultipartAbortError()
    }
  },

  async withUploadSignal(context, callback) {
    this.ensureActive(context)
    const controller = new AbortController()
    context.controllers.add(controller)

    try {
      return await callback(controller.signal)
    } finally {
      context.controllers.delete(controller)
    }
  },

  cancelContext(context) {
    context.cancelled = true
    context.controllers.forEach(controller => controller.abort())
  },

  cancelBatch(batch) {
    batch.cancelled = true
    this.paused = false
    batch.contexts.forEach(context => this.cancelContext(context))
    this.releasePauseWaiters(directMultipartAbortError())
  },

  async abortActive() {
    if(!this.activeBatch){
      this.setStatus("No active direct multipart upload", "error")
      return
    }

    const batch = this.activeBatch
    const contexts = Array.from(batch.contexts)
    this.cancelBatch(batch)

    const failures = []
    try {
      for(const context of contexts){
        const {key, file, session} = context

        if(!session?.upload_id){
          continue
        }

        try {
          const response = await jsonRequest(this.consoleUrl("abort", key), {
            upload_id: session.upload_id,
            expires_in: this.expiresIn,
          })
          await signedRequest(response.abort, "")
          localStorage.removeItem(this.storageKey(key, file))
          this.pushEvent("direct_multipart_aborted", {key})
        } catch (error) {
          if(isNoSuchUploadError(error)){
            localStorage.removeItem(this.storageKey(key, file))
          } else {
            failures.push(error)
          }
        }
      }

      const ownsActiveBatch = this.activeBatch === batch
      if(ownsActiveBatch){
        this.activeBatch = null
      }
      if(this.activeSession?.batch === batch){
        this.activeSession = null
      }
      if(ownsActiveBatch){
        if(failures.length > 0){
          this.setStatus(failures[0].message || String(failures[0]), "error")
        } else {
          this.setStatus("Direct multipart upload queue aborted")
        }
      }
    } catch (error) {
      const ownsActiveBatch = this.activeBatch === batch
      if(ownsActiveBatch){
        this.activeBatch = null
      }
      if(this.activeSession?.batch === batch){
        this.activeSession = null
      }
      if(ownsActiveBatch){
        this.setStatus(error.message || String(error), "error")
      }
    }
  },
}

export default DirectMultipartUpload
