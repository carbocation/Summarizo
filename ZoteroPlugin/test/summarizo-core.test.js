const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const SummarizoCore = require("../summarizo-core.js");

function row(overrides = {}) {
  return {
    libraryID: 1,
    parentKey: "PARENT1",
    attachmentKey: "ATTACH1",
    status: "ready",
    summary: "First paragraph.\n\nSecond <paragraph> & detail.",
    promptVersion: "summary-v4",
    modelID: "system.apple-intelligence",
    modelName: "Apple Intelligence",
    ...overrides
  };
}

function jsonl(records) {
  return records.map((record) => JSON.stringify(record)).join("\n") + "\n";
}

async function run() {
  testManifestCompatibility();
  testPluginUsesZotero9FilePickerParent();
  testPluginUsesSummarizoExportDirectoryConfig();
  await testPluginAdapterHardensChildCreation();
  testPluginProgressWindowLifecycle();
  await testPluginConfiguredImportDirectory();
  await testPluginImportDirectoryFallback();
  testStrictJSONLParser();
  testMetadataAndHTML();
  await testCreateUpdateDuplicateAndSkips();
  await testCreatedNoteVerificationCleansFailedNote();
  await testLargeChunkedImport();
  console.log("summarizo-core tests passed");
}

function testManifestCompatibility() {
  const manifest = JSON.parse(
    fs.readFileSync(path.join(__dirname, "..", "manifest.json"), "utf8")
  );
  const zotero = manifest.applications && manifest.applications.zotero;
  assert.equal(zotero.id, "summarizo-importer@carbocation.com");
  assert.match(zotero.update_url, /^https:\/\/.+\.json$/);
  assert.equal(zotero.strict_min_version, "9.0");
  assert.equal(zotero.strict_max_version, "9.*");
  assert.match(zotero.strict_max_version, /^\d+\.\*$/);
}

function testPluginUsesZotero9FilePickerParent() {
  const source = fs.readFileSync(
    path.join(__dirname, "..", "summarizo-plugin.js"),
    "utf8"
  );
  assert.match(source, /window\?\.browsingContext/);
  assert.match(source, /picker\.init\(parent,/);
  assert.match(source, /writeStatusMarker/);
}

function testPluginUsesSummarizoExportDirectoryConfig() {
  const source = fs.readFileSync(
    path.join(__dirname, "..", "summarizo-plugin.js"),
    "utf8"
  );
  assert.match(source, /config\.json/);
  assert.match(source, /picker\.displayDirectory = displayDirectory/);
  assert.match(source, /configuredExportDirectory/);
  assert.match(source, /fallbackExportDirectory/);
  assert.match(source, /com\.carbocation\.Summarizo/);
}

async function testPluginAdapterHardensChildCreation() {
  class MockItem {
    constructor(type) {
      this.type = type;
      this.tags = [];
      this.saved = false;
      this.erasedOptions = null;
    }

    setNote(html) {
      this.html = html;
    }

    getTags() {
      return this.tags.map((tag) => ({ tag }));
    }

    addTag(tag) {
      this.tags.push(tag);
    }

    async save() {
      this.saved = true;
    }

    async erase(options) {
      this.erasedOptions = options;
    }
  }

  const plugin = loadPluginWithMockFS({
    home: "/Users/example",
    directories: ["/Users/example"],
    files: new Map(),
    zoteroOverrides: { Item: MockItem }
  });
  const adapter = plugin.makeZoteroAdapter();
  const note = await adapter.createChildNote(
    { id: 42, libraryID: 7 },
    "<p>expected</p>",
    ["summarizo", "summarizo:cohort:abc"]
  );

  assert.equal(note.type, "note");
  assert.equal(note.libraryID, 7);
  assert.equal(note.parentID, 42);
  assert.equal(note.html, "<p>expected</p>");
  assert.deepEqual(note.tags, ["summarizo", "summarizo:cohort:abc"]);
  assert.equal(note.saved, true);

  await adapter.eraseNote(note);
  assert.equal(note.erasedOptions.skipDeleteLog, true);
}

function testPluginProgressWindowLifecycle() {
  const events = [];
  class MockProgressWindow {
    constructor(options) {
      events.push(["construct", options.closeOnClick]);
      this.ItemProgress = class {
        constructor(itemType, text) {
          events.push(["item", itemType, text]);
        }

        setItemTypeAndIcon(itemType, icon) {
          events.push(["icon", itemType, icon]);
        }

        setProgress(percent) {
          events.push(["progress", percent]);
        }

        setText(text) {
          events.push(["text", text]);
        }

        setError() {
          events.push(["error"]);
        }
      };
    }

    changeHeadline(text) {
      events.push(["headline", text]);
    }

    show() {
      events.push(["show"]);
    }

    startCloseTimer(milliseconds) {
      events.push(["close-timer", milliseconds]);
    }
  }

  const plugin = loadPluginWithMockFS({
    home: "/Users/example",
    directories: ["/Users/example"],
    files: new Map(),
    zoteroOverrides: { ProgressWindow: MockProgressWindow }
  });

  const progressWindow = plugin.createImportProgressWindow({}, 100);
  progressWindow.update({
    totalRows: 100,
    processedRows: 50,
    created: 10,
    updated: 5,
    unchanged: 20,
    skippedNotReady: 3,
    skippedMissingParent: 2,
    duplicateCohort: 1,
    invalidRow: 4,
    failed: 1
  });
  progressWindow.finish({
    totalRows: 100,
    processedRows: 100,
    created: 20,
    updated: 10,
    unchanged: 60,
    skippedNotReady: 4,
    skippedMissingParent: 2,
    duplicateCohort: 1,
    invalidRow: 2,
    failed: 1
  });
  progressWindow.fail(new Error("boom"));

  assert.deepEqual(events[0], ["construct", false]);
  assert.deepEqual(events[1], ["headline", "Importing Summarizo summaries"]);
  assert.equal(events[2][0], "item");
  assert.equal(events[2][2], "0/100 rows processed | 0 created | 0 updated | 0 unchanged | 0 skipped | 0 failed");
  assert.deepEqual(events[3], ["icon", null, "unfiled"]);
  assert.deepEqual(events[4], ["progress", 0]);
  assert.deepEqual(events[5], ["show"]);
  assert.ok(events.some((event) => event[0] === "text" && event[1].startsWith("50/100 rows processed")));
  assert.ok(events.some((event) => event[0] === "progress" && event[1] === 50));
  assert.ok(events.some((event) => event[0] === "headline" && event[1] === "Summarizo import complete"));
  assert.ok(events.some((event) => event[0] === "close-timer" && event[1] === 8000));
  assert.ok(events.some((event) => event[0] === "headline" && event[1] === "Summarizo import failed"));
  assert.ok(events.some((event) => event[0] === "text" && event[1] === "boom"));
  assert.ok(events.some((event) => event[0] === "error"));
  assert.equal(plugin.importProgressPercent({ totalRows: 0, processedRows: 0 }), 100);
}

async function testPluginConfiguredImportDirectory() {
  const home = "/Users/example";
  const sharedDirectory = `${home}/Library/Group Containers/group.com.carbocation.shared/ZoteroPlugin`;
  const exportDirectory = "/tmp/SummarizoExports";
  const plugin = loadPluginWithMockFS({
    home,
    directories: [
      `${home}/Library`,
      `${home}/Library/Group Containers`,
      `${home}/Library/Group Containers/group.com.carbocation.shared`,
      sharedDirectory,
      exportDirectory
    ],
    files: new Map([
      [`${sharedDirectory}/config.json`, JSON.stringify({
        schemaVersion: 1,
        pluginID: "summarizo-importer@carbocation.com",
        exportDirectory,
        updatedAt: "2026-05-04T00:00:00Z"
      })]
    ])
  });

  const directory = await plugin.defaultImportDirectory();
  assert.equal(directory.path, exportDirectory);
}

async function testPluginImportDirectoryFallback() {
  const home = "/Users/example";
  const fallback = `${home}/Library/Containers/com.carbocation.Summarizo/Data/Library/Application Support/Summarizo/Exports`;
  const plugin = loadPluginWithMockFS({
    home,
    directories: [
      `${home}/Library`,
      fallback
    ],
    files: new Map()
  });

  const directory = await plugin.defaultImportDirectory();
  assert.equal(directory.path, fallback);
}

function testStrictJSONLParser() {
  const records = [row({ parentKey: "A" }), row({ parentKey: "B" })];
  assert.deepEqual(
    SummarizoCore.parseStrictJSONL(`\n${jsonl(records)}\n`).map((record) => record.parentKey),
    ["A", "B"]
  );
  assert.throws(() => SummarizoCore.parseStrictJSONL(JSON.stringify(records)));
  assert.throws(() => SummarizoCore.parseStrictJSONL("{\n  \"libraryID\": 1\n}\n"));
  assert.throws(() => SummarizoCore.parseStrictJSONL("not-json\n"));
}

function testMetadataAndHTML() {
  const record = row();
  const metadata = SummarizoCore.noteMetadata(record);
  const expectedModelHash = crypto
    .createHash("sha256")
    .update(record.modelID)
    .digest("hex")
    .slice(0, 8);
  const expectedCohortHash = crypto
    .createHash("sha256")
    .update(`${record.promptVersion}\n${record.modelID}`)
    .digest("hex")
    .slice(0, 12);

  assert.equal(metadata.modelHash8, expectedModelHash);
  assert.equal(metadata.cohortHash12, expectedCohortHash);
  assert.equal(
    metadata.titleLine,
    `SUMMARIZO SUMMARY summarizo:prompt:summary-v4:model:apple-intelligence-${expectedModelHash}`
  );
  assert.deepEqual(metadata.tags, [
    "summarizo",
    "summarizo:prompt:summary-v4",
    `summarizo:model:apple-intelligence-${expectedModelHash}`,
    `summarizo:cohort:${expectedCohortHash}`
  ]);

  const html = SummarizoCore.renderNoteHTML(record, metadata);
  assert.match(html, /^<p>SUMMARIZO SUMMARY /);
  assert.match(html, /Second &lt;paragraph&gt; &amp; detail\./);
  assert.match(html, /summarizo<br\/>summarizo:prompt:summary-v4<br\/>summarizo:model:/);
}

async function testCreateUpdateDuplicateAndSkips() {
  const createRow = row({ parentKey: "CREATE" });
  const updateRow = row({ parentKey: "UPDATE" });
  const unchangedRow = row({ parentKey: "UNCHANGED" });
  const missingTagRow = row({ parentKey: "MISSING_TAG" });
  const duplicateRow = row({ parentKey: "DUPLICATE" });
  const updateMetadata = SummarizoCore.noteMetadata(updateRow);
  const unchangedMetadata = SummarizoCore.noteMetadata(unchangedRow);
  const missingTagMetadata = SummarizoCore.noteMetadata(missingTagRow);
  const duplicateMetadata = SummarizoCore.noteMetadata(duplicateRow);

  const parents = new Map([
    ["CREATE", { id: 1, libraryID: 1, key: "CREATE", notes: [] }],
    ["UPDATE", {
      id: 2,
      libraryID: 1,
      key: "UPDATE",
      notes: [{ id: 20, html: "old", tags: updateMetadata.tags.slice() }]
    }],
    ["UNCHANGED", {
      id: 3,
      libraryID: 1,
      key: "UNCHANGED",
      notes: [{
        id: 30,
        parentID: 3,
        libraryID: 1,
        html: `<div class="zotero-note znv1">${SummarizoCore.renderNoteHTML(unchangedRow, unchangedMetadata)}</div>`,
        tags: unchangedMetadata.tags.slice()
      }]
    }],
    ["MISSING_TAG", {
      id: 4,
      libraryID: 1,
      key: "MISSING_TAG",
      notes: [{
        id: 40,
        parentID: 4,
        libraryID: 1,
        html: SummarizoCore.renderNoteHTML(missingTagRow, missingTagMetadata),
        tags: missingTagMetadata.tags.filter((tag) => tag !== missingTagMetadata.modelTag)
      }]
    }],
    ["DUPLICATE", {
      id: 5,
      libraryID: 1,
      key: "DUPLICATE",
      notes: [
        { id: 30, html: "old 1", tags: duplicateMetadata.tags.slice() },
        { id: 31, html: "old 2", tags: duplicateMetadata.tags.slice() }
      ]
    }]
  ]);
  const adapter = memoryAdapter(parents);
  const report = await SummarizoCore.importRecords([
    createRow,
    updateRow,
    unchangedRow,
    missingTagRow,
    duplicateRow,
    row({ parentKey: "MISSING" }),
    row({ parentKey: "QUEUED", status: "queued" }),
    row({ parentKey: "" })
  ], adapter, { chunkSize: 2 });

  assert.equal(report.created, 1);
  assert.equal(report.updated, 2);
  assert.equal(report.unchanged, 1);
  assert.equal(report.duplicateCohort, 1);
  assert.equal(report.skippedMissingParent, 1);
  assert.equal(report.skippedNotReady, 1);
  assert.equal(report.invalidRow, 1);
  assert.equal(report.orphanCleanedUp, 0);
  assert.equal(adapter.stats.updated, 2);
  assert.equal(parents.get("CREATE").notes.length, 1);
  assert.match(parents.get("CREATE").notes[0].html, /^<p>SUMMARIZO SUMMARY /);
  assert.match(parents.get("UPDATE").notes[0].html, /^<p>SUMMARIZO SUMMARY /);
  assert.deepEqual(
    new Set(parents.get("MISSING_TAG").notes[0].tags),
    new Set(missingTagMetadata.tags)
  );
}

async function testCreatedNoteVerificationCleansFailedNote() {
  const parents = new Map([
    ["BROKEN", { id: 9, libraryID: 1, key: "BROKEN", notes: [] }]
  ]);
  const adapter = memoryAdapter(parents, {
    createChildNote: async (parent) => {
      const note = {
        id: 999,
        parentID: null,
        parentKey: parent.key,
        libraryID: parent.libraryID,
        html: "",
        tags: []
      };
      parent.notes.push(note);
      return note;
    }
  });

  const report = await SummarizoCore.importRecords([
    row({ parentKey: "BROKEN" })
  ], adapter);

  assert.equal(report.created, 0);
  assert.equal(report.failed, 1);
  assert.equal(report.orphanCleanedUp, 1);
  assert.equal(adapter.stats.erased, 1);
  assert.equal(parents.get("BROKEN").notes.length, 0);
  assert.match(report.details[0].error, /Created note failed verification/);
}

async function testLargeChunkedImport() {
  const parents = new Map();
  const records = [];
  for (let index = 0; index < 3000; index += 1) {
    const parentKey = `P${index}`;
    parents.set(parentKey, { id: index + 1, key: parentKey, notes: [] });
    records.push(row({ parentKey }));
  }

  let progressCalls = 0;
  const processedRows = [];
  const report = await SummarizoCore.importRecords(records, memoryAdapter(parents), {
    chunkSize: 50,
    onProgress: (progress) => {
      progressCalls += 1;
      processedRows.push(progress.processedRows);
    }
  });

  assert.equal(report.processedRows, 3000);
  assert.equal(report.created, 3000);
  assert.equal(report.updated, 0);
  assert.equal(report.unchanged, 0);
  assert.equal(report.failed, 0);
  assert.equal(report.orphanCleanedUp, 0);
  assert.equal(progressCalls, 60);
  assert.equal(processedRows[0], 50);
  assert.equal(processedRows.at(-1), 3000);
}

function memoryAdapter(parents, overrides = {}) {
  const stats = {
    created: 0,
    updated: 0,
    erased: 0
  };
  const adapter = {
    stats,
    resolveParent: async (record) => parents.get(record.parentKey) || null,
    getChildNotes: async (parent) => parent.notes,
    createChildNote: async (parent, html, tags) => {
      if (overrides.createChildNote) {
        return overrides.createChildNote(parent, html, tags);
      }
      stats.created += 1;
      const note = {
        id: parent.notes.length + 1000,
        parentID: parent.id,
        parentItemID: parent.id,
        parentKey: parent.key,
        libraryID: parent.libraryID || 1,
        html,
        tags: tags.slice()
      };
      parent.notes.push(note);
      return note;
    },
    updateNote: async (note, html, tags) => {
      stats.updated += 1;
      note.html = html;
      note.tags = Array.from(new Set([...note.tags, ...tags]));
      return note;
    },
    eraseNote: async (note) => {
      stats.erased += 1;
      const parent = parents.get(note.parentKey);
      if (parent) {
        parent.notes = parent.notes.filter((existing) => existing !== note);
      }
    },
    withTransaction: async (fn) => fn()
  };
  return adapter;
}

function loadPluginWithMockFS({ home, directories, files, zoteroOverrides = {} }) {
  const directorySet = new Set(directories);

  class MockFile {
    constructor(filePath = "") {
      this.path = filePath;
    }

    append(part) {
      this.path = this.path ? `${this.path}/${part}` : part;
    }

    clone() {
      return new MockFile(this.path);
    }

    exists() {
      return directorySet.has(this.path) || files.has(this.path);
    }

    isDirectory() {
      return directorySet.has(this.path);
    }

    create() {
      directorySet.add(this.path);
    }

    initWithPath(filePath) {
      this.path = filePath;
    }
  }

  const context = {
    console,
    Cc: {
      "@mozilla.org/file/local;1": {
        createInstance: () => new MockFile()
      }
    },
    Ci: {
      nsIFile: { DIRECTORY_TYPE: 1 }
    },
    Services: {
      appinfo: { OS: "Darwin" },
      dirsvc: {
        get: (key) => {
          assert.equal(key, "Home");
          return new MockFile(home);
        }
      }
    },
    Zotero: {
      debug: () => {},
      File: {
        getContentsAsync: async (filePath) => {
          if (!files.has(filePath)) {
            throw new Error(`missing file: ${filePath}`);
          }
          return files.get(filePath);
        }
      },
      ...zoteroOverrides
    }
  };
  vm.createContext(context);
  vm.runInContext(
    fs.readFileSync(path.join(__dirname, "..", "summarizo-plugin.js"), "utf8"),
    context
  );
  context.SummarizoPlugin.init({
    id: "summarizo-importer@carbocation.com",
    version: "0.1.4",
    rootURI: "resource://summarizo/"
  });
  return context.SummarizoPlugin;
}

run().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
