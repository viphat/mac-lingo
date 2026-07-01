import SwiftUI

/// View model bridging a `PanelSession.Display` to the SwiftUI modal (spec §3.3).
/// Carries the rich `FormattedText` so the view can render styled runs and 1:1
/// block breaks (`FormattedTextRenderer`), plus the engine/target selectors. User
/// actions are forwarded via closures the `ModalController` wires to the session.
@MainActor
final class ModalViewModel: ObservableObject {

    struct ResultDisplay: Equatable {
        let formatted: FormattedText
        let sourceTag: String
        let targetTag: String
        let engineName: String
    }

    struct ConfirmDisplay: Equatable {
        let characters: Int
        let approxTokens: Int
        let engineName: String
    }

    enum State: Equatable {
        case loading(engine: String, target: String)
        case result(ResultDisplay)
        case error(message: String, retryable: Bool)
        case confirmPaid(ConfirmDisplay)
        case noSelection
    }

    @Published var state: State = .noSelection
    @Published var pinned = false
    /// Engine/target selector state, kept in sync by the controller.
    @Published var currentEngine: EngineID = .googleFree
    @Published var availableEngines: [EngineID] = [.googleFree]
    @Published var currentTarget: TargetLanguage = .en

    /// Whether an AI engine is available to enhance to (drives the Enhance button).
    var canEnhance: Bool {
        availableEngines.contains { $0.isAI } && !currentEngine.isAI
    }

    var onCopy: () -> Void = {}
    var onRetry: () -> Void = {}
    var onClose: () -> Void = {}
    var onTogglePin: () -> Void = {}
    var onHoverChange: (Bool) -> Void = { _ in }
    var onEnhance: () -> Void = {}
    var onReset: () -> Void = {}
    var onSwitchEngine: (EngineID) -> Void = { _ in }
    var onSwitchTarget: (TargetLanguage) -> Void = { _ in }
    var onConfirmPaid: () -> Void = {}
    var onCancelPaid: () -> Void = {}

    /// Map a session display into renderable state. `target` is supplied because a
    /// `TranslationResult` carries only the detected source, not the target.
    func apply(_ display: PanelSession.Display, target: TargetLanguage) {
        switch display {
        case .loading(let engine, let target):
            state = .loading(engine: engine.displayName, target: target.displayTag)
        case .result(let result):
            state = .result(
                ResultDisplay(
                    formatted: result.text,
                    sourceTag: result.detectedSource.displayTag,
                    targetTag: target.displayTag,
                    engineName: result.engine.displayName))
        case .error(let error, let retryable):
            state = .error(message: Self.message(for: error), retryable: retryable)
        case .confirmPaid(let estimate):
            state = .confirmPaid(
                ConfirmDisplay(
                    characters: estimate.characters,
                    approxTokens: estimate.approxTokens,
                    engineName: estimate.engine.displayName))
        case .noSelection:
            state = .noSelection
        }
    }

    private static func message(for error: TranslationError) -> String {
        switch error {
        case .emptySelection: "No text selected."
        case .providerUnavailable: "This engine isn't available. Check settings."
        case .unsupportedHost: "Translation endpoint is not allowed."
        case .invalidEndpoint: "Translation endpoint is misconfigured."
        case .http(let status): "Translation failed (HTTP \(status))."
        case .malformedResponse: "Couldn't read the translation response."
        case .unauthorized: "The API key was rejected. Update it in Settings."
        case .selectionTooLarge(let limit):
            "Selection is too large (over \(limit) characters). Trim it and try again."
        }
    }
}

/// The floating modal's content (spec §3.3). Panel mechanics (key/Esc, dismissal,
/// Pin suppression, positioning) live in `ModalController` — not here.
struct TranslationModalView: View {
    @ObservedObject var model: ModalViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 360)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { model.onHoverChange($0) }
    }

    @ViewBuilder private var header: some View {
        HStack(spacing: 6) {
            switch model.state {
            case .result(let result):
                Text(result.sourceTag).fontWeight(.semibold)
                Image(systemName: "arrow.right").font(.caption2)
                targetMenu
                resetButton
                Spacer()
                engineMenu(current: result.engineName)
            case .loading(let engine, _):
                targetMenu
                resetButton
                Spacer()
                Text(engine).font(.caption).foregroundStyle(.secondary)
            default:
                Text("MacLingo").fontWeight(.semibold)
                Spacer()
            }
        }
        .font(.callout)
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Translating…").foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
        case .result(let result):
            ScrollView {
                FormattedTextRenderer.text(result.formatted)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 400)
        case .error(let message, _):
            Text(message).foregroundStyle(.secondary)
        case .confirmPaid(let confirm):
            VStack(alignment: .leading, spacing: 6) {
                Text("Translate with \(confirm.engineName)?").fontWeight(.semibold)
                Text(
                    "\(confirm.characters) characters (~\(confirm.approxTokens) tokens). "
                        + "This is a paid engine and will be billed to your account."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        case .noSelection:
            Text("No text selected.").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: 8) {
            if case .confirmPaid = model.state {
                Button("Translate", action: model.onConfirmPaid)
                Button("Cancel", action: model.onCancelPaid)
                Spacer()
            } else {
                if case .error(_, let retryable) = model.state, retryable {
                    Button("Retry", action: model.onRetry)
                }
                if case .result = model.state {
                    if model.canEnhance {
                        Button("Enhance with AI", action: model.onEnhance)
                    }
                    Button("Copy", action: model.onCopy)
                }
                Spacer()
                pinButton
                closeButton
            }
        }
        .buttonStyle(.borderless)
    }

    // MARK: - Selectors

    @ViewBuilder private var targetMenu: some View {
        Menu {
            ForEach(TargetLanguage.allCases, id: \.self) { language in
                Button(language.displayName) { model.onSwitchTarget(language) }
            }
        } label: {
            Text(model.currentTarget.displayTag).fontWeight(.semibold)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder private func engineMenu(current: String) -> some View {
        Menu {
            ForEach(model.availableEngines, id: \.self) { engine in
                Button(engine.displayName) { model.onSwitchEngine(engine) }
            }
        } label: {
            Text(current).font(.caption).foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder private var resetButton: some View {
        Button {
            model.onReset()
        } label: {
            Image(systemName: "arrow.counterclockwise")
        }
        .help("Reset to Settings default")
    }

    @ViewBuilder private var pinButton: some View {
        Button {
            model.onTogglePin()
        } label: {
            Image(systemName: model.pinned ? "pin.fill" : "pin")
        }
        .help(model.pinned ? "Unpin" : "Pin (keep open)")
    }

    @ViewBuilder private var closeButton: some View {
        Button {
            model.onClose()
        } label: {
            Image(systemName: "xmark")
        }
        .help("Close")
    }
}
