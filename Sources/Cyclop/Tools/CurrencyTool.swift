import SwiftUI

@MainActor
final class CurrencyTool: NotchTool {
    let id: ToolID = "currency"
    let title = localized("Currency")
    let symbol = "dollarsign.circle"
    let rail = ToolRail.right
    let needsKeyboard = true
    // Disabled out of the box; the code stays and Settings turns it on.
    let enabledByDefault = false

    let store = CurrencyStore()

    func start() { store.start() }
    func stop() { store.stop() }
    func didEnter() { store.refreshIfNeeded() }

    func headerAccessory() -> AnyView { AnyView(RateDate(store: store)) }

    func pane(_ context: ToolContext) -> AnyView {
        AnyView(CurrencyPane(currencies: store, wantsKeyboard: context.wantsKeyboard))
    }

    private struct RateDate: View {
        @ObservedObject var store: CurrencyStore
        var body: some View {
            if let date = store.rateDate {
                Text(date)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
            }
        }
    }
}
