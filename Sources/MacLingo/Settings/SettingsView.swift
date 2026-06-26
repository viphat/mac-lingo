import KeyboardShortcuts
import SwiftUI

/// The Settings window (spec §7). Provider-specific settings (AI/Cloud keys,
/// auto-enhance, thresholds) arrive in Phases 5–6; this is the Phase 1 surface:
/// target language, hotkey, default engine, capture method, appearance,
/// launch-at-login, and the Accessibility gate.
struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var permissions: PermissionsCoordinator
    let model: AppModel

    /// Transient key entry — never persisted to Defaults; the key goes to Keychain
    /// on Save and the field is cleared (spec §9).
    @State private var apiKeyDraft = ""
    @State private var aiModelDraft = ""
    @State private var validationMessage: String?
    @State private var isValidating = false

    /// Transient Cloud key entry — same Keychain-on-Save / clear contract as the AI
    /// key (spec §9).
    @State private var cloudKeyDraft = ""
    @State private var cloudValidationMessage: String?
    @State private var isValidatingCloud = false

    /// Local-only availability snapshot (spec §6.1/§9) — loaded from the on-device
    /// monitor; never sent anywhere.
    @State private var availabilitySnapshot = "No translations yet."

    var body: some View {
        Form {
            if case .resetToDefaults = model.migrationOutcome {
                Section {
                    Label(
                        "Your settings couldn’t be read and were reset to defaults. "
                            + "A backup was kept.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
            }

            accessibilitySection
            generalSection
            aiSection
            cloudSection
            hotkeySection
            startupSection
            diagnosticsSection
            updatesSection
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear {
            permissions.recheck()
            if aiModelDraft.isEmpty { aiModelDraft = settings.aiModel }
            Task { availabilitySnapshot = await model.availabilityMonitor.snapshot }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var accessibilitySection: some View {
        Section("Accessibility") {
            if permissions.isAccessibilityTrusted {
                Label("Accessibility access granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label(
                    "MacLingo needs Accessibility access to read the selected text.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                HStack {
                    Button("Grant Access…") { permissions.promptForAccessibility() }
                    Button("Open System Settings") { permissions.openAccessibilitySettings() }
                }
            }
        }
    }

    @ViewBuilder
    private var generalSection: some View {
        Section("General") {
            Picker("Target language", selection: $settings.targetLanguage) {
                ForEach(TargetLanguage.allCases, id: \.self) { language in
                    Text(language.displayName).tag(language)
                }
            }

            Picker("Default engine", selection: $settings.defaultEngine) {
                ForEach(availableDefaultEngines, id: \.self) { engine in
                    Text(engine.displayName).tag(engine)
                }
            }

            Picker("Capture method", selection: $settings.captureMethod) {
                ForEach(CaptureMethod.allCases, id: \.self) { method in
                    Text(method.displayName).tag(method)
                }
            }

            Picker("Appearance", selection: $settings.appearance) {
                ForEach(AppearanceMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
        }
    }

    @ViewBuilder
    private var aiSection: some View {
        Section("AI provider (BYOK)") {
            Picker("Provider", selection: aiProviderBinding) {
                ForEach(AIProvider.allCases, id: \.self) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }

            TextField("Model", text: $aiModelDraft, prompt: Text(defaultModelPrompt))
                .onSubmit { model.setAIModel(aiModelDraft) }

            SecureField("API key", text: $apiKeyDraft, prompt: Text("Paste your key"))
            HStack {
                Button("Save key") {
                    model.setAIKey(apiKeyDraft, provider: aiProviderBinding.wrappedValue)
                    apiKeyDraft = ""
                    validationMessage = nil
                }
                .disabled(apiKeyDraft.isEmpty)

                Button("Validate") { validateKey() }
                    .disabled(!settings.hasKeyProvider || isValidating)

                if settings.hasKeyProvider {
                    Button("Remove key", role: .destructive) {
                        model.removeAIKey()
                        validationMessage = nil
                    }
                }
                if isValidating { ProgressView().controlSize(.small) }
            }

            keyStatus
            if let validationMessage {
                Text(validationMessage).font(.caption).foregroundStyle(.secondary)
            }

            Toggle("Auto-enhance with AI after a non-AI translation", isOn: $settings.autoEnhance)
                .disabled(settings.configuredEngines.aiProvider == nil)

            Stepper(
                "Confirm paid translations over \(settings.paidConfirmThreshold) characters",
                value: $settings.paidConfirmThreshold, in: 0...50_000, step: 500)

            Stepper(
                autoSpendLabel,
                value: $settings.autoSpendLimit, in: 0...50_000, step: 500)
        }
    }

    @ViewBuilder
    private var keyStatus: some View {
        if settings.aiKeyInvalid {
            Label("Key was rejected — Validate or replace it.", systemImage: "xmark.circle.fill")
                .foregroundStyle(.orange).font(.caption)
        } else if settings.hasKeyProvider {
            Label("Key stored in Keychain.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.caption)
        } else {
            Text("No key stored. Paste one and Save.").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var cloudSection: some View {
        Section("Google Cloud Translation") {
            Toggle(
                "Enable Google Cloud engine",
                isOn: Binding(
                    get: { settings.googleCloudEnabled },
                    set: { model.setCloudEnabled($0) }))

            SecureField("API key", text: $cloudKeyDraft, prompt: Text("Paste your key"))
            HStack {
                Button("Save key") {
                    model.setCloudKey(cloudKeyDraft)
                    cloudKeyDraft = ""
                    cloudValidationMessage = nil
                }
                .disabled(cloudKeyDraft.isEmpty)

                Button("Validate") { validateCloudKey() }
                    .disabled(!settings.hasKeyCloud || isValidatingCloud)

                if settings.hasKeyCloud {
                    Button("Remove key", role: .destructive) {
                        model.removeCloudKey()
                        cloudValidationMessage = nil
                    }
                }
                if isValidatingCloud { ProgressView().controlSize(.small) }
            }

            cloudKeyStatus
            if let cloudValidationMessage {
                Text(cloudValidationMessage).font(.caption).foregroundStyle(.secondary)
            }

            Label(
                "Google Cloud bills per character. Over-threshold translations ask for "
                    + "confirmation before sending.",
                systemImage: "dollarsign.circle"
            )
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var cloudKeyStatus: some View {
        if settings.cloudKeyInvalid {
            Label("Key was rejected — Validate or replace it.", systemImage: "xmark.circle.fill")
                .foregroundStyle(.orange).font(.caption)
        } else if settings.hasKeyCloud {
            Label("Key stored in Keychain.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.caption)
        } else {
            Text("No key stored. Paste one and Save.").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var hotkeySection: some View {
        Section("Hotkey") {
            KeyboardShortcuts.Recorder("Translate selection:", name: .translateSelection)
        }
    }

    @ViewBuilder
    private var startupSection: some View {
        Section("Startup") {
            Toggle(
                "Launch at login",
                isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }))
        }
    }

    @ViewBuilder
    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            if !settings.googleFreeAvailable {
                Label(
                    "Google Translate (free) is currently disabled by a signed config. "
                        + "MacLingo falls back to your AI or Cloud engine.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange).font(.caption)
            }
            Text(availabilitySnapshot)
                .font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
            Button("Refresh") {
                Task { availabilitySnapshot = await model.availabilityMonitor.snapshot }
            }
            Text("Availability is tracked on-device only. No analytics or telemetry is sent.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var updatesSection: some View {
        Section("Updates") {
            Button("Check for Updates…") { model.checkForUpdates() }
            Text("Updates are EdDSA-signed and verified before install (Sparkle).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Derived

    /// Only offer engines that are currently configured (spec §7). Centralized via
    /// `SettingsStore.configuredEngines` so the selector agrees with resolution.
    private var availableDefaultEngines: [DefaultEngine] {
        let configured = settings.configuredEngines
        return DefaultEngine.allCases.filter {
            EngineResolver.isAvailable($0, available: configured)
        }
    }

    private var aiProviderBinding: Binding<AIProvider> {
        Binding(
            get: { settings.aiProvider ?? .openAI },
            set: { newValue in
                settings.aiProvider = newValue
                aiModelDraft = settings.aiModel
                model.onProviderChanged()
            })
    }

    private var defaultModelPrompt: String {
        (settings.aiProvider ?? .openAI).defaultModel
    }

    private var autoSpendLabel: String {
        settings.autoSpendLimit == 0
            ? "Auto-spend: always confirm over threshold"
            : "Auto-spend up to \(settings.autoSpendLimit) characters without confirming"
    }

    private func validateKey() {
        isValidating = true
        validationMessage = nil
        Task {
            let result = await model.validateAIKey()
            isValidating = false
            switch result {
            case .valid: validationMessage = "Key is valid."
            case .invalidKey: validationMessage = "Key was rejected (401/403)."
            case .failed(let reason): validationMessage = "Couldn’t validate: \(reason)"
            }
        }
    }

    private func validateCloudKey() {
        isValidatingCloud = true
        cloudValidationMessage = nil
        Task {
            let result = await model.validateCloudKey()
            isValidatingCloud = false
            switch result {
            case .valid: cloudValidationMessage = "Key is valid."
            case .invalidKey: cloudValidationMessage = "Key was rejected (401/403)."
            case .failed(let reason): cloudValidationMessage = "Couldn’t validate: \(reason)"
            }
        }
    }
}
