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
            hotkeySection
            startupSection
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onAppear { permissions.recheck() }
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

    // MARK: - Derived

    /// Only offer engines that are currently configured (spec §7). Google Free is
    /// always available; Cloud/AI appear once their keys are present (Phases 5–6).
    private var availableDefaultEngines: [DefaultEngine] {
        let configured = ConfiguredEngines(
            googleFreeAvailable: true,
            googleCloudConfigured: settings.googleCloudEnabled && settings.hasKeyCloud,
            aiProvider: settings.hasKeyProvider ? settings.aiProvider : nil)
        return DefaultEngine.allCases.filter {
            EngineResolver.isAvailable($0, available: configured)
        }
    }
}
