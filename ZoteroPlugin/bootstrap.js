var SummarizoPlugin;

function log(message) {
  Zotero.debug(`Summarizo Importer: ${message}`);
}

function install() {
  log("Installed");
}

async function startup({ id, version, rootURI }) {
  log(`Starting ${version}`);
  Services.scriptloader.loadSubScript(rootURI + "summarizo-core.js");
  Services.scriptloader.loadSubScript(rootURI + "summarizo-plugin.js");
  SummarizoPlugin.init({ id, version, rootURI });
  SummarizoPlugin.addToAllWindows();
  await SummarizoPlugin.writeStatusMarker("startup");
}

function onMainWindowLoad({ window }) {
  SummarizoPlugin?.addToWindow(window);
}

function onMainWindowUnload({ window }) {
  SummarizoPlugin?.removeFromWindow(window);
}

function shutdown() {
  log("Shutting down");
  SummarizoPlugin?.removeFromAllWindows();
  SummarizoPlugin = undefined;
}

function uninstall() {
  log("Uninstalled");
}
