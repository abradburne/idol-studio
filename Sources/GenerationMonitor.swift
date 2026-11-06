import SwiftUI

struct GenerationMonitor: View {
    let progress: GenerationProgress
    private let accent = Color(red: 0.76, green: 0.96, blue: 0.57)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("GENERATING ON THIS MAC", systemImage: "circle.hexagongrid.fill")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(accent)
            Text(progress.title)
                .font(.system(size: 17, weight: .medium))
                .contentTransition(.numericText())
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
                    .tint(accent)
            } else {
                ProgressView().progressViewStyle(.linear)
                    .tint(accent)
            }
            ForEach(GenerationProgress.Stage.allCases, id: \.self) { stage in
                let complete = stage.rawValue < progress.stage.rawValue
                let active = stage == progress.stage
                Label(stage.label, systemImage: complete ? "checkmark.circle.fill" : active ? "circle.inset.filled" : "circle")
                    .font(.system(size: 12, weight: active ? .semibold : .regular))
                    .foregroundStyle(complete || active ? accent : Color.secondary)
            }
        }
        .padding(24)
        .frame(width: 315)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.09)) }
        .accessibilityElement(children: .combine)
    }
}
