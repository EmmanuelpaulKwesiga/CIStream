import SwiftUI

struct EffortRatingView: View {
    let pending: PendingSession
    let onRate:  (Int) -> Void
    let onSkip:  () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                VStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.blue)
                    Text("How hard was it to follow speech?")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Text("Scene: \(pending.scene)  ·  \(durationLabel(pending.durationSeconds))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top)

                VStack(spacing: 10) {
                    ForEach(1...5, id: \.self) { rating in
                        Button { onRate(rating) } label: {
                            HStack(spacing: 16) {
                                Text("\(rating)")
                                    .font(.title2.weight(.bold))
                                    .foregroundStyle(ratingColor(rating))
                                    .frame(width: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(ratingLabel(rating))
                                        .font(.subheadline.weight(.medium))
                                    Text(ratingDetail(rating))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding()
                            .background(Color(.secondarySystemGroupedBackground),
                                        in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer()
            }
            .padding(.horizontal)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Listening Effort")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Skip", action: onSkip)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func durationLabel(_ s: Double) -> String {
        if s < 60 { return "\(Int(s)) s" }
        let m = Int(s) / 60
        let sec = Int(s) % 60
        return sec > 0 ? "\(m) min \(sec) s" : "\(m) min"
    }

    private func ratingLabel(_ r: Int) -> String {
        ["Effortless", "Slight effort", "Moderate effort", "High effort", "Exhausting"][r - 1]
    }

    private func ratingDetail(_ r: Int) -> String {
        switch r {
        case 1: return "Understood everything without trying"
        case 2: return "Needed occasional concentration"
        case 3: return "Had to concentrate noticeably"
        case 4: return "Struggled to follow — missed parts"
        case 5: return "Could barely follow — very tiring"
        default: return ""
        }
    }

    private func ratingColor(_ r: Int) -> Color {
        [.green, .mint, .yellow, .orange, .red][r - 1]
    }
}
