import SwiftUI

/// Placeholder root view — real shell (rail + grid + Now Playing) lands
/// in `TvHome.swift` once the project builds.
struct ContentView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 24) {
                Image(systemName: "radio.fill")
                    .font(.system(size: 96))
                    .foregroundStyle(Color(red: 0.91, green: 0.12, blue: 0.39))
                Text("Radio Crestin")
                    .font(.system(size: 56, weight: .bold))
                    .foregroundStyle(.white)
                Text("Apple TV — în construcție")
                    .font(.system(size: 24))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }
}

#Preview {
    ContentView()
}
