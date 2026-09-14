import SwiftUI

struct BatteryIndicator: View {
    let percentage: Int
    private var charge: Int { min(100, max(0, percentage)) }

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 1) {
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(lineWidth: 1)
                    .frame(width: 18, height: 9)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 0.5)
                            .frame(width: 14 * CGFloat(charge) / 100, height: 5)
                            .padding(.leading, 2)
                    }
                Capsule().frame(width: 1.5, height: 4)
            }.accessibilityHidden(true)
            Text("\(charge)%").monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery \(charge) percent")
    }
}
