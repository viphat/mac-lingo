import SwiftUI

/// View model bridging a `PanelSession.Display` to the SwiftUI modal (spec §3.3).
/// Phase 3 renders **plain text**; Phase 4 swaps the body for an `AttributedString`
/// once `RichTextCodec` lands. User actions are forwarded via closures the
/// `ModalController` wires to the session.
@MainActor
final class ModalViewModel: ObservableObject {

    struct ResultDisplay: Equatable {
        let text: String
        let sourceTag: String
        let targetTag: String
        let engineName: String
    }

    enum State: Equatable {
        case loading(engine: String, target: String)
        case result(ResultDisplay)
        case error(message: String, retryable: Bool)
        case noSelection
    }

    @Published var state: State = .noSelection
    @Published var pinned = false

    var onCopy: () -> Void = {}
    var onRetry: () -> Void = {}
    var onClose: () -> Void = {}
    var onTogglePin: () -> Void = {}
    var onHoverChange: (Bool) -> Void = { _ in }

    /// Map a session display into renderable state. `target` is supplied because a
    /// `TranslationResult` carries only the detected source, not the target.
    func apply(_ display: PanelSession.Display, target: TargetLanguage) {
        switch display {
        case .loading(let engine, let target):
            state = .loading(engine: engine.displayName, target: target.displayTag)
        case .result(let result):
            state = .result(
                ResultDisplay(
                    text: result.text.plainText,
                    sourceTag: result.detectedSource.displayTag,
                    targetTag: target.displayTag,
                    engineName: result.engine.displayName))
        case .error(let error, let retryable):
            state = .error(message: Self.message(for: error), retryable: retryable)
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
                Text(result.targetTag).fontWeight(.semibold)
                Spacer()
                Text(result.engineName).font(.caption).foregroundStyle(.secondary)
            case .loading(let engine, let target):
                Text("→ \(target)").fontWeight(.semibold)
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
                Text(result.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
        case .error(let message, _):
            Text(message).foregroundStyle(.secondary)
        case .noSelection:
            Text("No text selected.").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: 8) {
            if case .error(_, let retryable) = model.state, retryable {
                Button("Retry", action: model.onRetry)
            }
            if case .result = model.state {
                Button("Copy", action: model.onCopy)
            }
            Spacer()
            Button {
                model.onTogglePin()
            } label: {
                Image(systemName: model.pinned ? "pin.fill" : "pin")
            }
            .help(model.pinned ? "Unpin" : "Pin (keep open)")
            Button {
                model.onClose()
            } label: {
                Image(systemName: "xmark")
            }
            .help("Close")
        }
        .buttonStyle(.borderless)
    }
}
