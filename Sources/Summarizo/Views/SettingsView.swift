import SwiftUI

struct SettingsView: View {
    @AppStorage("llama.selectedModelID") private var selectedModelID = ""
    @AppStorage("llama.optionsMode") private var optionsModeRaw = GenerationOptionsMode.extractionSafe.rawValue
    @AppStorage("llama.temperature") private var temperature = 0.0
    @AppStorage("llama.topP") private var topP = 0.9
    @AppStorage("llama.topK") private var topK = 40
    @AppStorage(SummaryLLMThinkingPreferences.summarizationKey) private var summarizationThinking = SummaryLLMThinkingPreferences.defaultSummarization
    @AppStorage("summarizo.ocrEnabled") private var ocrEnabled = false
    @AppStorage("summarizo.verboseDiagnostics") private var verboseDiagnostics = false

    @State private var showModelPicker = false
    @State private var zoteroPath = ""
    @State private var alertMessage: String?

    private let modelLibrary = ModelLibrary.shared

    var body: some View {
        Form {
            Section("Zotero") {
                HStack {
                    TextField("Zotero data directory", text: $zoteroPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Choose") {
                        chooseZoteroDirectory()
                    }
                }
                Text(zoteroHelpText)
                    .foregroundStyle(.secondary)
            }

            Section("Model") {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(selectedModelLabel)
                        Text("Local inference runs through CarbocationLocalLLM.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Choose Model") {
                        showModelPicker = true
                    }
                }
            }

            Section("Generation") {
                Picker("Options", selection: $optionsModeRaw) {
                    Text("Extraction-safe").tag(GenerationOptionsMode.extractionSafe.rawValue)
                    Text("Custom").tag(GenerationOptionsMode.custom.rawValue)
                }
                .pickerStyle(.segmented)

                if GenerationOptionsMode(rawValue: optionsModeRaw) == .custom {
                    Slider(value: $temperature, in: 0...1) {
                        Text("Temperature")
                    }
                    HStack {
                        Text("Top P")
                        Slider(value: $topP, in: 0.1...1)
                        Text(topP, format: .number.precision(.fractionLength(2)))
                            .monospacedDigit()
                    }
                    Stepper("Top K: \(topK)", value: $topK, in: 1...200)
                }

                Toggle("Enable model-native thinking for summaries", isOn: $summarizationThinking)
                Toggle("Use Apple Vision OCR only when text extraction fails", isOn: $ocrEnabled)
                Text("Safe fallback: Summarizo first uses Zotero's full-text cache, then PDFKit. OCR runs only for PDFs whose extracted text is empty or very sparse.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Store full prompts and responses in diagnostics", isOn: $verboseDiagnostics)
            }
        }
        .formStyle(.grouped)
        .frame(width: 620, height: 520)
        .padding()
        .task {
            await modelLibrary.refresh()
            zoteroPath = SecurityScopedBookmarkStore.shared.resolvedZoteroDirectory()?.path
                ?? ZoteroProfileLocator.suggestedDataDirectory()?.path
                ?? ""
        }
        .sheet(isPresented: $showModelPicker) {
            ModelLibraryPickerView(
                library: modelLibrary,
                selectedModelID: $selectedModelID,
                title: "Choose a Summary Model",
                confirmTitle: "Use Model",
                systemModels: LocalLLMEngine.availableSystemModels(),
                calibrationAdapter: calibrationAdapter,
                onModelDeleted: { model in
                    if selectedModelID == model.id.uuidString {
                        selectedModelID = ""
                    }
                },
                onConfirmSelection: { _ in
                    showModelPicker = false
                }
            )
            .frame(width: 760, height: 720)
        }
        .alert(
            "Settings",
            isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )
        ) {
            Button("OK") { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private var selectedModelLabel: String {
        guard let selection = LLMModelSelection(storageValue: selectedModelID) else {
            return "No model selected"
        }
        switch selection {
        case .installed(let id):
            return modelLibrary.model(id: id)?.displayName ?? "Installed model missing"
        case .system:
            return LocalLLMEngine.availableSystemModels().first { $0.selection == selection }?.displayName ?? "System model"
        }
    }

    private var zoteroHelpText: String {
        if let granted = SecurityScopedBookmarkStore.shared.resolvedZoteroDirectory() {
            return "Granted Zotero directory: \(granted.path). Summarizo snapshots zotero.sqlite read-only and stores summaries in its own app support folder."
        }

        if let suggested = ZoteroProfileLocator.suggestedDataDirectory() {
            return "Detected \(suggested.path). Choose it once so the sandboxed app can read Zotero."
        }

        let standard = ZoteroProfileLocator.standardDataDirectory().path
        return "No local Zotero data directory was detected at \(standard). Choose the folder containing zotero.sqlite and storage."
    }

    private var calibrationAdapter: ModelLibraryPickerCalibrationAdapter {
        ModelLibraryPickerCalibrationAdapter(
            runtimeFingerprint: LocalLLMEngine.contextCalibrationRuntimeFingerprint(),
            calibrate: { model, progress in
                try await LocalLLMEngine.calibrateContext(for: model, in: modelLibrary) { value in
                    await MainActor.run { progress(value) }
                }
            }
        )
    }

    private func chooseZoteroDirectory() {
        do {
            let suggested = ZoteroProfileLocator.suggestedDataDirectory()
            if let url = try SecurityScopedBookmarkStore.shared.chooseZoteroDirectory(suggestedURL: suggested) {
                zoteroPath = url.path
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }
}
