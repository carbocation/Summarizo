# Summarizo Zotero Importer

This is the Zotero 9 plugin source for importing Summarizo strict JSONL exports as tagged child notes.

The plugin never writes `zotero.sqlite` directly. It runs inside Zotero and creates or updates notes through Zotero's JavaScript item API.

## Import Behavior

- Accepts only Summarizo strict JSONL: one compact JSON object per non-empty line.
- Imports only rows where `status` is `ready` and `summary` is not blank.
- Resolves parent items by local Zotero `libraryID` and `parentKey`.
- Creates or updates one child note per parent/cohort.
- Skips a row if more than one matching Summarizo note already exists for the same parent/cohort.
- Writes an import report next to the JSONL file.

## Note Shape

The first note line is:

```text
SUMMARIZO SUMMARY summarizo:prompt:<promptVersionSlug>:model:<modelSlug>-<modelHash8>
```

Then the note contains the AI summary. The final paragraph contains the machine tags as visible text:

```text
summarizo
summarizo:prompt:<promptVersionSlug>
summarizo:model:<modelSlug>-<modelHash8>
summarizo:cohort:<cohortHash12>
```

The same four values are applied as Zotero note tags.

## Development

Run the core tests from the repository root:

```sh
node ZoteroPlugin/test/summarizo-core.test.js
```

Build the installable `.xpi` from the repository root:

```sh
script/build_zotero_plugin.sh
```

To load the plugin from source, create a Zotero extension proxy file named `summarizo-importer@carbocation.com` in the Zotero profile's `extensions` directory. The file should contain the absolute path to this `ZoteroPlugin` directory.

## End-User Installation

Summarizo bundles `Summarizo Zotero Importer.xpi`. In Summarizo, open Settings and click **Install Zotero Plugin...**. Summarizo copies the plugin to an app-support install folder, reveals it in Finder, and opens Zotero if it is installed.

Then install through Zotero:

1. Open Zotero.
2. Choose **Tools > Plugins**.
3. Drag `Summarizo Zotero Importer.xpi` from Finder into the Plugins window, or use Zotero's install-from-file control if visible.
4. Restart Zotero if prompted.
5. Confirm **Tools > Import Summarizo Summaries...** appears.

Summarizo does not write into Zotero's profile or silently install the plugin. Source-proxy loading is for development only.

## Manual QA

1. Build the plugin package with `script/build_zotero_plugin.sh`.
2. Build and run Summarizo.
3. Use Settings > Install Zotero Plugin... and install the revealed `.xpi` in Zotero 9.
4. Restart Zotero if prompted.
5. Export a small Summarizo JSONL file.
6. In Zotero, choose Tools > Import Summarizo Summaries...
7. Verify tagged child notes are created and an import report is written next to the JSONL file.
