import SwiftUI

// MARK: - Splash View
// Single SwiftUI layout for all platforms. Sizing adapts via compile-time
// platform flags (#if os) and — on iOS/iPadOS — the horizontal size class
// so iPhones and iPads each get proportionate logo/text sizes.

struct SplashView: View {
    @Binding var isFinished: Bool

    var body: some View {
        UniversalSplashView(isFinished: $isFinished)
    }
}

// MARK: - Universal Splash

private struct UniversalSplashView: View {
    @Binding var isFinished: Bool
    @State private var opacity: Double = 0.0

    /// On iOS/iPadOS, compact = iPhone, regular = iPad.
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                Image("AerioLogo")
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: logoSize, height: logoSize)
                    .clipShape(RoundedRectangle(cornerRadius: logoCornerRadius,
                                               style: .continuous))
                    .shadow(color: Color(hex: "1AC4D8").opacity(0.55),
                            radius: shadowRadius,
                            y: logoSize * 0.075)
                    .padding(.bottom, logoBottomPad)

                Text("AerioTV")
                    .font(.system(size: titleSize, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                Text("Live TV  ·  Movies  ·  Series")
                    .font(.system(size: subtitleSize, weight: .light))
                    .foregroundColor(Color(hex: "1AC4D8"))
                    .padding(.top, subtitleTopPad)

                Spacer()
            }
        }
        .opacity(opacity)
        .onAppear {
            withAnimation(.easeIn(duration: 0.4)) { opacity = 1.0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.3) {
                withAnimation(.easeOut(duration: 0.4)) { opacity = 0 }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) {
                isFinished = true
            }
        }
    }

    // MARK: - Per-Platform Metrics

    private var logoSize: CGFloat {
        #if os(tvOS)
        return 160
        #elseif os(macOS)
        return 120
        #else
        return sizeClass == .compact ? 100 : 130   // iPhone : iPad
        #endif
    }

    private var logoCornerRadius: CGFloat {
        #if os(tvOS)
        return 32
        #elseif os(macOS)
        return 24
        #else
        return sizeClass == .compact ? 20 : 28     // iPhone : iPad
        #endif
    }

    private var titleSize: CGFloat {
        #if os(tvOS)
        return 72
        #elseif os(macOS)
        return 58
        #else
        return sizeClass == .compact ? 50 : 64     // iPhone : iPad
        #endif
    }

    private var subtitleSize: CGFloat {
        #if os(tvOS)
        return 28
        #elseif os(macOS)
        return 22
        #else
        return sizeClass == .compact ? 18 : 24     // iPhone : iPad
        #endif
    }

    private var logoBottomPad: CGFloat {
        #if os(tvOS)
        return 40
        #elseif os(macOS)
        return 30
        #else
        return sizeClass == .compact ? 24 : 32     // iPhone : iPad
        #endif
    }

    private var subtitleTopPad: CGFloat {
        #if os(tvOS)
        return 12
        #else
        return 10
        #endif
    }

    private var shadowRadius: CGFloat {
        #if os(tvOS)
        return 40
        #elseif os(macOS)
        return 28
        #else
        return sizeClass == .compact ? 20 : 30     // iPhone : iPad
        #endif
    }
}
