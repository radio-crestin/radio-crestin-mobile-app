import SwiftUI
import WidgetKit

@main
struct RadioCrestinWidgets: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        FavoritesWidget()
    }
}
