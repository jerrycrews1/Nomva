import Combine
import Foundation

@MainActor
final class NomvaRouteCenter: ObservableObject {
    static let shared = NomvaRouteCenter()

    @Published private(set) var currentRoute: NomvaWidgetRoute?

    private init() {}

    func handle(url: URL) {
        guard let route = NomvaWidgetRoute.from(url: url) else { return }
        currentRoute = route
    }

    func consumeStoredRouteIfNeeded() {
        guard let route = NomvaWidgetRouteStore.consume() else { return }
        currentRoute = route
    }

    func clear(_ route: NomvaWidgetRoute? = nil) {
        guard route == nil || currentRoute == route else { return }
        currentRoute = nil
    }
}
