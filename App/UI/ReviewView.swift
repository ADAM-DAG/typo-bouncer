import AppKit
import BouncerCore
import Observation
import SwiftUI

@MainActor @Observable
final class ReviewFocusState {
    var keyboardReady = false
}

struct IslandReviewView: View {
    @Bindable var coordinator: ProofreadingCoordinator
    let focus: ReviewFocusState
    let apply: () -> Void
    let collapse: () -> Void
    @State private var showChanges = true
    @Namespace private var tabs
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let accent = Color(red: 1, green: 159.0 / 255, blue: 11.0 / 255)

    /// Size once when opening; long corrections and notices scroll within the card.
    @MainActor static func preferredHeight(for coordinator: ProofreadingCoordinator, width: CGFloat) -> CGFloat {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 5
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14), .paragraphStyle: paragraph
        ]
        func height(_ text: String) -> CGFloat {
            NSAttributedString(string: text, attributes: attributes).boundingRect(
                with: NSSize(width: max(120, width - 84), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        }
        var textHeight: CGFloat = 0
        if let result = coordinator.result {
            // Allow room for both deleted and inserted text in the Changes tab.
            textHeight = height(result.segments.map(\.text).joined())
            if !result.warnings.isEmpty { textHeight += 52 }
            if coordinator.copyOnly { textHeight += 52 }
            else if let notice = coordinator.externalFormattingMessage { textHeight += height(notice) + 12 }
        }
        if let message = coordinator.message { textHeight += height(message) + 12 }
        return min(380, max(264, 208 + ceil(textHeight)))
    }

    var body: some View {
        GeometryReader { geometry in
            reviewContent(compact: geometry.size.height < 190)
        }.environment(\.colorScheme, .dark)
    }

    private func reviewContent(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 12) {
            HStack(spacing: 9) {
                Image(systemName: "text.badge.checkmark")
                    .font(.system(size: 17, weight: .medium)).foregroundStyle(accent)
                    .frame(width: 24, height: 28)
                Text(coordinator.result == nil ? "Correction details" : "Review changes")
                    .font(.system(size: 14, weight: .semibold))
                Spacer(minLength: 8)
                Button(action: collapse) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        .frame(width: 26, height: 26)
                }.buttonStyle(IslandControlStyle())
                    .accessibilityLabel("Collapse preview")
                    .help(focus.keyboardReady ? String(localized: "Collapse preview · Esc") : String(localized: "Collapse preview"))
                    .disabled(coordinator.applying)
            }
            if let result = coordinator.result, !result.isUnchanged {
                HStack(spacing: 10) {
                    HStack(spacing: 2) {
                        previewTab("Changes", selected: true, compact: compact)
                        previewTab("Corrected", selected: false, compact: compact)
                    }.padding(compact ? 2 : 3)
                        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(0.04), lineWidth: 0.5))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: showChanges)
                        .accessibilityElement(children: .contain).accessibilityLabel("Preview")
                    Spacer(minLength: 0)
                    if let app = coordinator.sourceAppName {
                        Text(app).font(.system(size: 11)).foregroundStyle(.white.opacity(0.42))
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(showChanges ? islandCorrectionDiff(result.segments) : AttributedString(result.corrected))
                            .font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
                            .foregroundStyle(.white.opacity(0.92))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if !result.warnings.isEmpty {
                            notice(String(localized: "Review carefully: this includes a name change or substantial edits."), symbol: "exclamationmark.triangle", tint: accent)
                        }
                        if coordinator.copyOnly {
                            notice(String(localized: "Copy the correction, then paste it where you need it. Your original stays unchanged."), symbol: "doc.on.clipboard")
                        } else if let message = coordinator.externalFormattingMessage {
                            notice(message, symbol: "textformat")
                        }
                        if let message = coordinator.message { notice(message, symbol: "info.circle") }
                    }.padding(compact ? 8 : 14)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.065), lineWidth: 0.5))
                HStack(spacing: 10) {
                    Button { coordinator.copyCorrection() } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 12).frame(height: compact ? 28 : 32)
                    }.buttonStyle(IslandControlStyle()).disabled(coordinator.applying)
                        .accessibilityLabel("Copy correction")
                    Spacer()
                    if !coordinator.copyOnly && coordinator.result != nil {
                        Button(action: apply) {
                            HStack(spacing: 12) {
                                Text("Apply").font(.system(size: 12, weight: .semibold))
                                if focus.keyboardReady {
                                    Image(systemName: "return").font(.system(size: 10, weight: .medium)).opacity(0.6)
                                }
                            }.padding(.horizontal, 14).frame(height: compact ? 28 : 32)
                        }.buttonStyle(IslandControlStyle(prominent: true))
                            .disabled(!coordinator.canApply).accessibilityLabel("Apply to selection")
                    }
                }
            } else {
                ScrollView {
                    Text(coordinator.message ?? String(localized: "No changes suggested. The model can still miss errors."))
                        .font(.system(size: 13)).lineSpacing(4).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(compact ? 8 : 14)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                HStack {
                    Spacer()
                    Button(action: collapse) {
                        Text("Close").font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 14).frame(height: compact ? 28 : 32)
                    }.buttonStyle(IslandControlStyle())
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func previewTab(_ title: LocalizedStringKey, selected: Bool, compact: Bool) -> some View {
        Button { showChanges = selected } label: {
            Text(title).font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(showChanges == selected ? 0.95 : 0.48))
                .padding(.horizontal, 11).frame(height: compact ? 21 : 23)
                .background {
                    if showChanges == selected {
                        RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.10))
                            .matchedGeometryEffect(id: "tab", in: tabs)
                    }
                }
        }.buttonStyle(.plain).accessibilityAddTraits(showChanges == selected ? .isSelected : [])
    }

    private func notice(_ text: String, symbol: String, tint: Color = .white.opacity(0.55)) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).font(.system(size: 10))
        }.font(.system(size: 11)).foregroundStyle(tint)
    }
}

private struct IslandControlStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(prominent ? Color.black.opacity(0.88) : Color.white.opacity(0.72))
            .background {
                RoundedRectangle(cornerRadius: 9)
                    .fill(prominent ? Color.white.opacity(hovered ? 1 : 0.92) : Color.white.opacity(hovered ? 0.10 : 0.055))
            }
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(prominent ? 0 : 0.055), lineWidth: 0.5))
            .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.35)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: configuration.isPressed)
            .onHover { hovered = $0 }
    }
}

private func islandCorrectionDiff(_ segments: [DiffSegment]) -> AttributedString {
    var output = AttributedString()
    let inserted = Color(red: 0.43, green: 0.89, blue: 0.66)
    for (index, segment) in segments.enumerated() {
        var text = AttributedString(segment.text)
        switch segment.kind {
        case .unchanged: break
        case .removed:
            text.foregroundColor = .white.opacity(0.40); text.strikethroughStyle = .single
        case .inserted:
            text.foregroundColor = inserted; text.backgroundColor = inserted.opacity(0.10)
        }
        output.append(text)
        if segment.kind == .removed && index + 1 < segments.count && segments[index + 1].kind == .inserted {
            output.append(AttributedString(" "))
        }
    }
    return output
}
