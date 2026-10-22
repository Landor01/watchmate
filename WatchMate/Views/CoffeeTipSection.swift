import StoreKit
import SwiftUI

struct CoffeeTipSection: View {
    @Environment(TipStore.self) private var tips
    @Environment(\.themeAccent) private var themeAccent
    @Environment(\.openURL) private var openURL

    private static let appStoreID = "6822334851"

    private var reviewURL: URL? {
        guard !Self.appStoreID.isEmpty else { return nil }
        return URL(string: "https://apps.apple.com/app/id\(Self.appStoreID)?action=write-review")
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 20) {
                CoffeeTipHeader()
                CoffeeTipOptions()
                Text("This app was built to address a need I had to track shows across platforms and is released on a non-commercial basis. All existing and new features are free, forever! However, if you find the app useful, I'd appreciate a positive review, and a coffee! This is entirely optional though.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
//                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .center)
                Button("Review on App Store") {
                    if let reviewURL {
                        openURL(reviewURL)
                    }
                }
                .buttonStyle(.bordered)
                .tint(themeAccent)
                .disabled(reviewURL == nil)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(themeAccent.opacity(0.10), in: RoundedRectangle(cornerRadius: 20))
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
        }
        .task { await tips.loadProduct() }
    }
}

private struct CoffeeTipHeader: View {
    @Environment(\.themeAccent) private var themeAccent

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "cup.and.saucer.fill")
                .font(.largeTitle)
                .foregroundStyle(themeAccent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Enjoying WatchMate?")
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("Buy me a coffee and help support future development work.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct CoffeeTipOptions: View {
    @Environment(TipStore.self) private var tips
    @Environment(\.purchase) private var purchase
    @Environment(\.themeAccent) private var themeAccent
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if tips.loading {
                ProgressView("Loading tip prices…")
            }
            ForEach(tips.products) { product in
                Button {
                    Task { await tips.buyCoffee(product) { try await purchase($0) } }
                } label: {
                    let layout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                        : AnyLayout(HStackLayout(spacing: 12))
                    layout {
                        Text(product.displayName)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(product.displayPrice)
                            .fontWeight(.semibold)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .foregroundStyle(themeAccent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(minHeight: 44)
                    .background(.background, in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(themeAccent.opacity(0.5), lineWidth: 1)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(tips.purchasing)
                .opacity(tips.purchasing ? 0.5 : 1)
            }
            if !tips.loading && tips.hasMissingProducts {
                Button("Retry loading tip prices") {
                    Task { await tips.loadProduct() }
                }
                .buttonStyle(.bordered)
                .disabled(tips.purchasing)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            if tips.purchasing {
                ProgressView("Waiting for purchase…")
            }
            if let message = tips.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }
}

#if DEBUG

#Preview("Coffee tips") {
    PreviewHost { data in
        Form { CoffeeTipSection() }
    }
}
#endif
