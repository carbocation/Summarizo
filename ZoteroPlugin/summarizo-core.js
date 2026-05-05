(function (root, factory) {
  if (typeof module === "object" && module.exports) {
    module.exports = factory();
  } else {
    root.SummarizoCore = factory();
  }
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  const BASE_TAG = "summarizo";
  const DEFAULT_CHUNK_SIZE = 50;

  function parseStrictJSONL(text) {
    if (typeof text !== "string") {
      throw new Error("Summarizo import must be UTF-8 text.");
    }

    const records = [];
    const lines = text.split(/\r?\n/);
    for (let index = 0; index < lines.length; index += 1) {
      const line = lines[index].trim();
      if (!line) {
        continue;
      }

      if (!line.startsWith("{")) {
        throw new Error(`Line ${index + 1} is not a JSON object.`);
      }
      if (!line.endsWith("}")) {
        throw new Error(`Line ${index + 1} is not a complete single-line JSON object.`);
      }

      let record;
      try {
        record = JSON.parse(line);
      } catch (error) {
        throw new Error(`Line ${index + 1} is not valid JSON: ${error.message}`);
      }
      if (!record || typeof record !== "object" || Array.isArray(record)) {
        throw new Error(`Line ${index + 1} is not a JSON object.`);
      }
      records.push(record);
    }
    return records;
  }

  function isEligibleRecord(record) {
    return record?.status === "ready" && Boolean(firstNonBlank(record.summary));
  }

  function validateRecord(record) {
    if (!record || typeof record !== "object" || Array.isArray(record)) {
      return "record is not an object";
    }
    if (!Number.isFinite(Number(record.libraryID))) {
      return "libraryID is missing or invalid";
    }
    if (!firstNonBlank(record.parentKey)) {
      return "parentKey is missing";
    }
    return null;
  }

  function noteMetadata(record) {
    const promptVersion = firstNonBlank(
      record.promptVersion,
      record.diagnostic?.promptVersion,
      "unknown-prompt"
    );
    const modelIdentity = firstNonBlank(
      record.modelID,
      record.modelName,
      record.model,
      record.diagnostic?.modelID,
      record.diagnostic?.modelName,
      "unknown-model"
    );
    const modelLabel = firstNonBlank(
      record.modelName,
      record.model,
      record.diagnostic?.modelName,
      record.modelID,
      "unknown-model"
    );

    const promptSlug = slugify(promptVersion, "unknown-prompt");
    const modelSlug = slugify(modelLabel, "unknown-model");
    const modelHash8 = sha256Hex(modelIdentity).slice(0, 8);
    const cohortHash12 = sha256Hex(`${promptVersion}\n${modelIdentity}`).slice(0, 12);
    const promptTag = `${BASE_TAG}:prompt:${promptSlug}`;
    const modelTag = `${BASE_TAG}:model:${modelSlug}-${modelHash8}`;
    const cohortTag = `${BASE_TAG}:cohort:${cohortHash12}`;
    const titleLine = `SUMMARIZO SUMMARY ${promptTag}:model:${modelSlug}-${modelHash8}`;
    const tags = [BASE_TAG, promptTag, modelTag, cohortTag];

    return {
      promptVersion,
      modelIdentity,
      modelLabel,
      promptSlug,
      modelSlug,
      modelHash8,
      cohortHash12,
      promptTag,
      modelTag,
      cohortTag,
      titleLine,
      tags
    };
  }

  function renderNoteHTML(record, metadata = noteMetadata(record)) {
    const summary = firstNonBlank(record.summary, "");
    const paragraphs = summary
      .split(/\n{2,}/)
      .map((part) => part.trim())
      .filter(Boolean);

    return [
      paragraphHTML(metadata.titleLine),
      ...paragraphs.map(paragraphHTML),
      paragraphHTML(metadata.tags.join("\n"))
    ].join("\n");
  }

  function matchingSummarizoNotes(notes, metadata) {
    return notes.filter((note) => {
      const tags = new Set(noteTags(note));
      return tags.has(BASE_TAG) && tags.has(metadata.cohortTag);
    });
  }

  async function importRecords(records, adapter, options = {}) {
    if (!Array.isArray(records)) {
      throw new Error("records must be an array");
    }
    if (!adapter) {
      throw new Error("adapter is required");
    }

    const chunkSize = Math.max(1, options.chunkSize || DEFAULT_CHUNK_SIZE);
    const report = {
      totalRows: records.length,
      processedRows: 0,
      eligibleRows: 0,
      created: 0,
      updated: 0,
      unchanged: 0,
      skippedNotReady: 0,
      skippedMissingParent: 0,
      duplicateCohort: 0,
      invalidRow: 0,
      failed: 0,
      orphanCleanedUp: 0,
      details: []
    };

    for (let start = 0; start < records.length; start += chunkSize) {
      const chunk = records.slice(start, start + chunkSize);
      const runChunk = async () => {
        for (let offset = 0; offset < chunk.length; offset += 1) {
          const rowIndex = start + offset;
          await importOneRecord(records[rowIndex], rowIndex, adapter, report);
        }
      };

      if (adapter.withTransaction) {
        await adapter.withTransaction(runChunk);
      } else {
        await runChunk();
      }

      report.processedRows = Math.min(start + chunk.length, records.length);
      if (options.onProgress) {
        await options.onProgress({ ...report });
      }
    }

    return report;
  }

  async function importOneRecord(record, rowIndex, adapter, report) {
    const invalidReason = validateRecord(record);
    if (invalidReason) {
      report.invalidRow += 1;
      report.details.push({ row: rowIndex + 1, status: "invalid-row", reason: invalidReason });
      return;
    }

    if (!isEligibleRecord(record)) {
      report.skippedNotReady += 1;
      return;
    }

    report.eligibleRows += 1;
    const metadata = noteMetadata(record);
    try {
      const parent = await adapter.resolveParent(record);
      if (!parent) {
        report.skippedMissingParent += 1;
        report.details.push({
          row: rowIndex + 1,
          status: "missing-parent",
          libraryID: record.libraryID,
          parentKey: record.parentKey
        });
        return;
      }

      const notes = await adapter.getChildNotes(parent);
      const matches = matchingSummarizoNotes(notes, metadata);
      if (matches.length > 1) {
        report.duplicateCohort += 1;
        report.details.push({
          row: rowIndex + 1,
          status: "duplicate-cohort",
          parentKey: record.parentKey,
          cohortTag: metadata.cohortTag,
          noteIDs: matches.map((note) => note.id)
        });
        return;
      }

      const html = renderNoteHTML(record, metadata);
      if (matches.length === 1) {
        if (noteMatchesExpected(matches[0], html, metadata.tags)) {
          report.unchanged += 1;
        } else {
          await adapter.updateNote(matches[0], html, metadata.tags, record, metadata);
          report.updated += 1;
        }
      } else {
        const note = await adapter.createChildNote(parent, html, metadata.tags, record, metadata);
        const verificationError = createdNoteVerificationError(note, parent, html, metadata.tags);
        if (verificationError) {
          if (adapter.eraseNote) {
            await adapter.eraseNote(note, record, metadata);
            report.orphanCleanedUp += 1;
          }
          throw new Error(`Created note failed verification: ${verificationError}`);
        }
        report.created += 1;
      }
    } catch (error) {
      report.failed += 1;
      report.details.push({
        row: rowIndex + 1,
        status: "failed",
        parentKey: record.parentKey,
        error: error.message || String(error)
      });
    }
  }

  function noteTags(note) {
    const tags = typeof note?.getTags === "function" ? note.getTags() : note?.tags || [];
    return tags
      .map((tag) => {
        if (typeof tag === "string") {
          return tag;
        }
        return tag?.tag;
      })
      .filter(Boolean);
  }

  function noteMatchesExpected(note, html, tags) {
    return normalizeNoteHTML(noteHTML(note)) === normalizeNoteHTML(html) && hasExpectedTags(note, tags);
  }

  function createdNoteVerificationError(note, parent, html, tags) {
    if (!note || typeof note !== "object") {
      return "created note was not returned";
    }

    const expectedParentID = numericValue(parent?.id);
    const actualParentID = numericValue(firstDefined(note.parentID, note.parentItemID));
    if (expectedParentID && actualParentID !== expectedParentID) {
      return `created note parent ${actualParentID || "none"} did not match ${expectedParentID}`;
    }

    const expectedLibraryID = numericValue(parent?.libraryID);
    const actualLibraryID = numericValue(note.libraryID);
    if (expectedLibraryID && actualLibraryID && actualLibraryID !== expectedLibraryID) {
      return `created note library ${actualLibraryID} did not match ${expectedLibraryID}`;
    }

    if (!firstNonBlank(normalizeNoteHTML(noteHTML(note))).length) {
      return "created note HTML was empty";
    }
    if (normalizeNoteHTML(noteHTML(note)) !== normalizeNoteHTML(html)) {
      return "created note HTML did not match expected content";
    }
    if (!hasExpectedTags(note, tags)) {
      return "created note was missing expected Summarizo tags";
    }
    return null;
  }

  function hasExpectedTags(note, tags) {
    const existingTags = new Set(noteTags(note));
    return tags.every((tag) => existingTags.has(tag));
  }

  function noteHTML(note) {
    if (typeof note?.getNote === "function") {
      return note.getNote();
    }
    return firstDefined(note?.html, note?.note, "");
  }

  function normalizeNoteHTML(html) {
    let normalized = String(html || "").replace(/\r\n/g, "\n").trim();
    const wrapperMatch = normalized.match(/^<div class="zotero-note znv[0-9]+">([\s\S]*)<\/div>$/);
    if (wrapperMatch) {
      normalized = wrapperMatch[1].trim();
    }
    return normalized;
  }

  function numericValue(value) {
    const number = Number(value);
    return Number.isFinite(number) && number > 0 ? number : null;
  }

  function firstDefined(...values) {
    return values.find((value) => value !== null && value !== undefined);
  }

  function paragraphHTML(text) {
    return `<p>${escapeHTML(text).replace(/\r?\n/g, "<br/>")}</p>`;
  }

  function escapeHTML(value) {
    return String(value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;");
  }

  function firstNonBlank(...values) {
    for (const value of values) {
      if (value === null || value === undefined) {
        continue;
      }
      const text = String(value).trim();
      if (text) {
        return text;
      }
    }
    return "";
  }

  function slugify(value, fallback) {
    const normalized = firstNonBlank(value)
      .normalize("NFKD")
      .replace(/[\u0300-\u036f]/g, "")
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "")
      .slice(0, 72);
    return normalized || fallback;
  }

  function utf8Bytes(text) {
    if (typeof TextEncoder !== "undefined") {
      return Array.from(new TextEncoder().encode(text));
    }
    return Array.from(Buffer.from(text, "utf8"));
  }

  function sha256Hex(text) {
    const bytes = utf8Bytes(String(text));
    const bitLength = bytes.length * 8;
    bytes.push(0x80);
    while ((bytes.length % 64) !== 56) {
      bytes.push(0);
    }

    const high = Math.floor(bitLength / 0x100000000);
    const low = bitLength >>> 0;
    for (const word of [high, low]) {
      bytes.push((word >>> 24) & 0xff);
      bytes.push((word >>> 16) & 0xff);
      bytes.push((word >>> 8) & 0xff);
      bytes.push(word & 0xff);
    }

    const h = [
      0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
      0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    ];
    const k = [
      0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
      0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
      0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
      0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
      0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
      0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
      0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
      0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ];

    for (let chunk = 0; chunk < bytes.length; chunk += 64) {
      const w = new Array(64);
      for (let i = 0; i < 16; i += 1) {
        const offset = chunk + i * 4;
        w[i] = (
          (bytes[offset] << 24) |
          (bytes[offset + 1] << 16) |
          (bytes[offset + 2] << 8) |
          bytes[offset + 3]
        ) >>> 0;
      }
      for (let i = 16; i < 64; i += 1) {
        const s0 = rotateRight(w[i - 15], 7) ^ rotateRight(w[i - 15], 18) ^ (w[i - 15] >>> 3);
        const s1 = rotateRight(w[i - 2], 17) ^ rotateRight(w[i - 2], 19) ^ (w[i - 2] >>> 10);
        w[i] = (w[i - 16] + s0 + w[i - 7] + s1) >>> 0;
      }

      let [a, b, c, d, e, f, g, hValue] = h;
      for (let i = 0; i < 64; i += 1) {
        const s1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25);
        const ch = (e & f) ^ ((~e) & g);
        const temp1 = (hValue + s1 + ch + k[i] + w[i]) >>> 0;
        const s0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22);
        const maj = (a & b) ^ (a & c) ^ (b & c);
        const temp2 = (s0 + maj) >>> 0;
        hValue = g;
        g = f;
        f = e;
        e = (d + temp1) >>> 0;
        d = c;
        c = b;
        b = a;
        a = (temp1 + temp2) >>> 0;
      }

      h[0] = (h[0] + a) >>> 0;
      h[1] = (h[1] + b) >>> 0;
      h[2] = (h[2] + c) >>> 0;
      h[3] = (h[3] + d) >>> 0;
      h[4] = (h[4] + e) >>> 0;
      h[5] = (h[5] + f) >>> 0;
      h[6] = (h[6] + g) >>> 0;
      h[7] = (h[7] + hValue) >>> 0;
    }

    return h.map((value) => value.toString(16).padStart(8, "0")).join("");
  }

  function rotateRight(value, bits) {
    return (value >>> bits) | (value << (32 - bits));
  }

  return {
    BASE_TAG,
    parseStrictJSONL,
    isEligibleRecord,
    noteMetadata,
    renderNoteHTML,
    matchingSummarizoNotes,
    noteMatchesExpected,
    importRecords,
    sha256Hex,
    slugify
  };
});
