SummarizoPlugin = {
  id: null,
  version: null,
  rootURI: null,
  menuItemID: "summarizo-import-jsonl",

  init({ id, version, rootURI }) {
    this.id = id;
    this.version = version;
    this.rootURI = rootURI;
  },

  log(message) {
    Zotero.debug(`Summarizo Importer: ${message}`);
  },

  addToAllWindows() {
    for (const win of Zotero.getMainWindows()) {
      if (win.ZoteroPane) {
        this.addToWindow(win);
      }
    }
  },

  addToWindow(window) {
    const doc = window.document;
    if (doc.getElementById(this.menuItemID)) {
      return;
    }

    const toolsMenu = doc.getElementById("menu_ToolsPopup");
    if (!toolsMenu) {
      this.log("Could not find Tools menu.");
      return;
    }

    const menuitem = doc.createXULElement("menuitem");
    menuitem.id = this.menuItemID;
    menuitem.setAttribute("label", "Import Summarizo Summaries...");
    menuitem.addEventListener("command", () => {
      this.runImport(window).catch((error) => {
        this.log(error.stack || error.message || String(error));
        this.alert(window, "Summarizo import failed", error.message || String(error));
      });
    });
    toolsMenu.appendChild(menuitem);
  },

  removeFromWindow(window) {
    window.document.getElementById(this.menuItemID)?.remove();
  },

  removeFromAllWindows() {
    for (const win of Zotero.getMainWindows()) {
      if (win.ZoteroPane) {
        this.removeFromWindow(win);
      }
    }
  },

  async runImport(window) {
    await this.writeStatusMarker("import-started");
    const path = await this.chooseJSONLFile(window);
    if (!path) {
      return;
    }

    const text = await Zotero.File.getContentsAsync(path);
    const records = SummarizoCore.parseStrictJSONL(text);
    const adapter = this.makeZoteroAdapter();
    const progressWindow = this.createImportProgressWindow(window, records.length);
    await this.yieldToZotero();

    let report;
    try {
      report = await SummarizoCore.importRecords(records, adapter, {
        chunkSize: 50,
        onProgress: (progress) => {
          progressWindow.update(progress);
          this.log(
            `Imported ${progress.processedRows}/${progress.totalRows} rows ` +
            `(${progress.created} created, ${progress.updated} updated, ${progress.unchanged} unchanged).`
          );
        }
      });
      progressWindow.finish(report);
    } catch (error) {
      progressWindow.fail(error);
      await this.yieldToZotero();
      throw error;
    }

    const reportPath = this.reportPath(path);
    await Zotero.File.putContentsAsync(reportPath, JSON.stringify(report, null, 2));
    await this.writeStatusMarker("import-complete");
    this.alert(window, "Summarizo import complete", this.reportSummary(report, reportPath));
  },

  async chooseJSONLFile(window) {
    const displayDirectory = await this.defaultImportDirectory();
    return new Promise((resolve) => {
      const picker = Cc["@mozilla.org/filepicker;1"].createInstance(Ci.nsIFilePicker);
      const parent = window?.browsingContext || window;
      picker.init(parent, "Import Summarizo JSONL Export", Ci.nsIFilePicker.modeOpen);
      picker.appendFilter("Summarizo JSONL", "*.jsonl");
      picker.appendFilters(Ci.nsIFilePicker.filterAll);
      if (displayDirectory) {
        picker.displayDirectory = displayDirectory;
      }
      picker.open((result) => {
        if (result === Ci.nsIFilePicker.returnOK) {
          resolve(picker.file.path);
        } else {
          resolve(null);
        }
      });
    });
  },

  async defaultImportDirectory() {
    const configured = await this.configuredExportDirectory();
    return configured || this.fallbackExportDirectory();
  },

  async configuredExportDirectory() {
    try {
      const configFile = this.sharedPluginFile("config.json", false);
      if (!configFile?.exists()) {
        return null;
      }

      const text = await Zotero.File.getContentsAsync(configFile.path);
      const config = JSON.parse(text);
      if (
        config?.schemaVersion !== 1 ||
        config?.pluginID !== this.id ||
        typeof config?.exportDirectory !== "string"
      ) {
        return null;
      }

      return this.existingDirectoryFromPath(config.exportDirectory);
    } catch (error) {
      this.log(`Could not read Summarizo export directory config: ${error.message || String(error)}`);
      return null;
    }
  },

  fallbackExportDirectory() {
    if (Services.appinfo.OS !== "Darwin") {
      return null;
    }

    const directory = Services.dirsvc.get("Home", Ci.nsIFile);
    for (const part of [
      "Library",
      "Containers",
      "com.carbocation.Summarizo",
      "Data",
      "Library",
      "Application Support",
      "Summarizo",
      "Exports"
    ]) {
      directory.append(part);
    }
    return directory.exists() && directory.isDirectory() ? directory : null;
  },

  existingDirectoryFromPath(path) {
    try {
      const directory = Cc["@mozilla.org/file/local;1"].createInstance(Ci.nsIFile);
      directory.initWithPath(path);
      return directory.exists() && directory.isDirectory() ? directory : null;
    } catch (error) {
      return null;
    }
  },

  makeZoteroAdapter() {
    return {
      resolveParent: async (record) => {
        const libraryID = Number(record.libraryID);
        const key = String(record.parentKey).trim();
        return Zotero.Items.getByLibraryAndKeyAsync(libraryID, key);
      },

      getChildNotes: async (parent) => {
        const noteIDs = parent.getNotes();
        return Zotero.Items.getAsync(noteIDs);
      },

      createChildNote: async (parent, html, tags) => {
        const note = new Zotero.Item("note");
        note.libraryID = parent.libraryID;
        note.parentID = parent.id;
        note.setNote(html);
        this.applyTags(note, tags);
        await note.save();
        return note;
      },

      updateNote: async (note, html, tags) => {
        note.setNote(html);
        this.applyTags(note, tags);
        await note.save();
        return note;
      },

      eraseNote: async (note) => {
        await note.erase({ skipDeleteLog: true });
      },

      withTransaction: async (fn) => Zotero.DB.executeTransaction(fn)
    };
  },

  applyTags(item, tags) {
    const existingTags = new Set(
      (typeof item.getTags === "function" ? item.getTags() : [])
        .map((tag) => typeof tag === "string" ? tag : tag?.tag)
        .filter(Boolean)
    );
    for (const tag of tags) {
      if (!existingTags.has(tag)) {
        item.addTag(tag);
      }
    }
  },

  createImportProgressWindow(window, totalRows) {
    if (!Zotero.ProgressWindow) {
      return this.noopImportProgressWindow();
    }

    const progressWindow = new Zotero.ProgressWindow({
      window,
      closeOnClick: false
    });
    progressWindow.changeHeadline("Importing Summarizo summaries");
    const itemProgress = new progressWindow.ItemProgress(
      null,
      this.importProgressText({
        totalRows,
        processedRows: 0,
        created: 0,
        updated: 0,
        unchanged: 0,
        skippedNotReady: 0,
        skippedMissingParent: 0,
        duplicateCohort: 0,
        invalidRow: 0,
        failed: 0
      })
    );
    itemProgress.setItemTypeAndIcon(null, "unfiled");
    itemProgress.setProgress(0);
    progressWindow.show();

    return {
      update: (progress) => {
        itemProgress.setText(this.importProgressText(progress));
        itemProgress.setProgress(this.importProgressPercent(progress));
      },

      finish: (report) => {
        progressWindow.changeHeadline("Summarizo import complete");
        itemProgress.setText(this.importProgressText(report));
        itemProgress.setProgress(100);
        progressWindow.startCloseTimer(8000);
      },

      fail: (error) => {
        progressWindow.changeHeadline("Summarizo import failed");
        itemProgress.setText(error?.message || String(error));
        itemProgress.setError();
      }
    };
  },

  noopImportProgressWindow() {
    return {
      update: () => {},
      finish: () => {},
      fail: () => {}
    };
  },

  importProgressText(progress) {
    const totalRows = Number(progress.totalRows || 0);
    const processedRows = Math.min(Number(progress.processedRows || 0), totalRows);
    const skipped = Number(progress.skippedNotReady || 0) +
      Number(progress.skippedMissingParent || 0) +
      Number(progress.duplicateCohort || 0) +
      Number(progress.invalidRow || 0);
    return [
      `${processedRows}/${totalRows} rows processed`,
      `${Number(progress.created || 0)} created`,
      `${Number(progress.updated || 0)} updated`,
      `${Number(progress.unchanged || 0)} unchanged`,
      `${skipped} skipped`,
      `${Number(progress.failed || 0)} failed`
    ].join(" | ");
  },

  importProgressPercent(progress) {
    const totalRows = Number(progress.totalRows || 0);
    if (totalRows <= 0) {
      return 100;
    }

    const processedRows = Math.min(Number(progress.processedRows || 0), totalRows);
    return Math.max(0, Math.min(100, processedRows / totalRows * 100));
  },

  async yieldToZotero() {
    if (Zotero.Promise?.delay) {
      await Zotero.Promise.delay(0);
      return;
    }
    await new Promise((resolve) => setTimeout(resolve, 0));
  },

  async writeStatusMarker(event) {
    try {
      if (Services.appinfo.OS !== "Darwin") {
        return;
      }

      const marker = this.sharedPluginFile("status.json", true);
      await Zotero.File.putContentsAsync(marker.path, JSON.stringify({
        pluginID: this.id,
        version: this.version,
        enabled: true,
        event,
        lastSeenAt: new Date().toISOString()
      }, null, 2));
    } catch (error) {
      this.log(`Could not write status marker: ${error.message || String(error)}`);
    }
  },

  sharedPluginFile(fileName, createDirectory) {
    if (Services.appinfo.OS !== "Darwin") {
      return null;
    }

    const directory = Services.dirsvc.get("Home", Ci.nsIFile);
    for (const part of ["Library", "Group Containers", "group.com.carbocation.shared", "ZoteroPlugin"]) {
      directory.append(part);
      if (!directory.exists()) {
        if (!createDirectory) {
          return null;
        }
        directory.create(Ci.nsIFile.DIRECTORY_TYPE, 0o700);
      }
    }

    const file = directory.clone();
    file.append(fileName);
    return file;
  },

  reportPath(path) {
    if (/\.jsonl$/i.test(path)) {
      return path.replace(/\.jsonl$/i, "-summarizo-import-report.json");
    }
    return `${path}-summarizo-import-report.json`;
  },

  reportSummary(report, reportPath) {
    return [
      `${report.created} created`,
      `${report.updated} updated`,
      `${report.unchanged} unchanged`,
      `${report.skippedNotReady} skipped because not ready or empty`,
      `${report.skippedMissingParent} skipped because parent was missing`,
      `${report.duplicateCohort} skipped because multiple matching Summarizo notes already exist`,
      `${report.invalidRow} invalid rows`,
      `${report.failed} failed`,
      `${report.orphanCleanedUp} orphaned new notes cleaned up`,
      "",
      ...(report.eligibleRows > 1000 ? [
        "Large imports can leave Zotero refreshing its item list or search index after this message.",
        "If Zotero stays blank or spinning for several minutes, quit and relaunch Zotero.",
        ""
      ] : []),
      `Report: ${reportPath}`
    ].join("\n");
  },

  alert(window, title, message) {
    if (Services?.prompt?.alert) {
      Services.prompt.alert(window, title, message);
    } else {
      window.alert(`${title}\n\n${message}`);
    }
  }
};
