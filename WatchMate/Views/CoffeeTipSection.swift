import StoreKit
import SwiftUI

struct CoffeeTipSection: View {
    @Environment(TipStore.self) private var tips
    @Environment(\.purchase) private var purchase

    var body: some View {
        Section {
            Text("Buy me a coffee")
                .font(.headline)
            if tips.loading {
                ProgressView("Loading tip prices…")
            }
            ForEach(tips.products) { product in
                Button {
                    Task { await tips.buyCoffee(product) { try await purchase($0) } }
                } label: {
                    HStack(spacing: 12) {
                        Label(product.displayName, systemImage: "cup.and.saucer")
                        Spacer(minLength: 8)
                        Text(product.displayPrice)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .disabled(tips.purchasing)
            }
            if !tips.loading && tips.hasMissingProducts {
                Button("Retry loading tip prices") {
                    Task { await tips.loadProduct() }
                }
                .disabled(tips.purchasing)
            }
            if tips.purchasing {
                ProgressView("Waiting for purchase…")
            }
            if let message = tips.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Support WatchMate")
        } footer: {
            Text("Enjoying WatchMate? You can leave an optional, one-off tip. All features stay free, whether you tip or not.")
        }
        .task { await tips.loadProduct() }
    }
}

#if DEBUG

#Preview("Coffee tips") {
    PreviewHost { data in
        Form { CoffeeTipSection() }
    }
}
#endif
