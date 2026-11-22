import SwiftUI

/// 沉浸式游戏库视图（宽屏 / 横屏布局）。
///
/// 全屏 key art 背景 + 顶部横向封面条 + 左下标题与操作区。
/// 与 CoverFlowView 接口一致，可在 LibraryView 里一行切换。
struct ArtworkLibrary: View, Equatable {
    let games: [GameDetail]
    let selected: GameDetail
    let controllers: Int
    let showsHints: Bool
    var obscured = false
    var screenInsets = EdgeInsets()
    let select: (String) -> Void
    let primary: (GameDetail) -> Void
    let openSettings: () -> Void
    let openControllers: () -> Void
    let openShellSettings: () -> Void
    /// The same optional actions `CoverFlowView` takes, so either view can stand in for the other
    /// in `LibraryView` without losing the long-press menu.
    var openHomeScreen: ((String) -> Void)? = nil
    var openCoverPicker: ((String) -> Void)? = nil
    var resetCover: ((String) -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.shellFocus) private var focus
    @Namespace private var glass

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.games.map(\.game) == rhs.games.map(\.game)
            && lhs.selected.game == rhs.selected.game
            && lhs.controllers == rhs.controllers
            && lhs.showsHints == rhs.showsHints
            && lhs.obscured == rhs.obscured
            && lhs.screenInsets == rhs.screenInsets
    }

    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width
            let h = geometry.size.height
            ZStack(alignment: .topLeading) {
                backdrop(size: geometry.size)
                VStack(alignment: .leading, spacing: 0) {
                    coverRow(width: w)
                        .padding(.top, max(16, screenInsets.top + 12))
                    Spacer(minLength: 0)
                    infoBlock(width: w)
                        .padding(.horizontal, max(24, w * 0.035))
                        .padding(.bottom, max(24, screenInsets.bottom + 20))
                }
            }
            .frame(width: w, height: h)
            .background(Color.black)
        }
        .ignoresSafeArea()
        .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: selected.id)
    }

    // MARK: 背景

    @ViewBuilder private func backdrop(size: CGSize) -> some View {
        ZStack {
            Color.black
            // 清晰 key art：不做模糊，只用渐变保证文字可读
            // With a banner, the full-resolution art; without one (icon only, or nothing at all),
            // the backdrop mode: a whole-screen treatment instead of the 16:9 IconCard, which is
            // built for a card and leaves a full-bleed frame mostly empty.
            ArtView(game: selected.game, backdrop: selected.game.banner == nil, lettering: false)
                .frame(width: size.width, height: size.height)
                .clipped()
            LinearGradient(stops: [
                .init(color: .black.opacity(0.55), location: 0.0),
                .init(color: .black.opacity(0.10), location: 0.35),
                .init(color: .black.opacity(0.55), location: 0.72),
                .init(color: .black.opacity(0.92), location: 1.0)
            ], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }

    // MARK: 顶部封面条

    @ViewBuilder private func coverRow(width: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(games) { detail in
                        coverCard(detail, rowWidth: width)
                            .id(detail.id)
                    }
                }
                .padding(.horizontal, max(24, width * 0.035))
                .padding(.vertical, 6)
            }
            .frame(height: cardHeight(width: width) + 30)
            .onChange(of: selected.id) { _, id in
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onChange(of: focus.id) { _, newID in
                guard let newID, newID.hasPrefix("lib.tile.") else { return }
                let id = String(newID.dropFirst("lib.tile.".count))
                select(id)
                withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func cardHeight(width: CGFloat) -> CGFloat {
        min(132, max(88, width * 0.092))
    }

    @ViewBuilder private func coverCard(_ detail: GameDetail, rowWidth: CGFloat) -> some View {
        let chosen = detail.id == selected.id
        let side = cardHeight(width: rowWidth)
        Button {
            select(detail.id)
        } label: {
            // 方形 App 图标（大壁纸才用宽幅 key art）
            ZStack {
                RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
                    .fill(Color(white: 0.12))
                if let icon = detail.game.icon {
                    Image(decorative: icon.image, scale: 1)
                        .resizable().interpolation(.high).scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
                } else {
                    // A game with neither banner nor icon still has to be recognisable in the strip.
                    PlaceholderArt(title: detail.game.title, seed: detail.id, lettering: true)
                        .clipShape(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
                }
            }
            .frame(width: side, height: side)
            .overlay {
                RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
                    .strokeBorder(.white.opacity(chosen ? 0.95 : 0.10), lineWidth: chosen ? 3 : 1)
            }
            .overlay(alignment: .topLeading) {
                StateDot(state: detail.game.state, size: 9)
                    .offset(x: -3, y: -3)
                    .opacity(chosen ? 1 : 0.7)
            }
            .shadow(color: .black.opacity(chosen ? 0.6 : 0.35), radius: chosen ? 16 : 8, y: 8)
            .scaleEffect(chosen ? 1.0 : 0.9)
            .animation(reduceMotion ? nil : .smooth(duration: 0.22), value: chosen)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Group {
                Button(ShellStrings.text("Play"), systemImage: "play.fill") { primary(detail) }
                    .disabled(detail.game.state != .playable)
                Button(ShellStrings.text("Game settings"), systemImage: "slider.horizontal.3") {
                    select(detail.id); openSettings()
                }
                if let openHomeScreen {
                    Button(ShellStrings.text("Add to Home Screen…"), systemImage: "plus.square") {
                        openHomeScreen(detail.id)
                    }
                }
                if let openCoverPicker {
                    Button(ShellStrings.text("Change Cover…"), systemImage: "photo.on.rectangle.angled") {
                        openCoverPicker(detail.id)
                    }
                }
                if let resetCover, detail.game.hasCustomCover {
                    Button(ShellStrings.text("Reset Cover"), systemImage: "arrow.uturn.backward") {
                        resetCover(detail.id)
                    }
                }
            }
        }
        // 注册给壳的焦点系统：手柄/键盘左右才能移动选中项
        .shellTarget("lib.tile.\(detail.id)", radius: side * 0.22) { primary(detail) }
        .accessibilityLabel(detail.game.title)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    // MARK: 左下信息与按钮

    @ViewBuilder private func infoBlock(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Circle().fill(selected.game.state == .playable ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(selected.game.state.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
            }
            Text(selected.game.title)
                .font(.system(size: min(52, max(28, width * 0.042)), weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .shadow(color: .black.opacity(0.5), radius: 12, y: 3)
            HStack(spacing: 10) {
                Text(selected.id)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                Text("v\(selected.game.version)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                if let played = selected.game.recentlyPlayed, !played.isEmpty {
                    Text("·").font(.system(size: 12)).foregroundStyle(.white.opacity(0.3))
                    HStack(spacing: 4) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 11, weight: .semibold))
                        Text(played).font(.system(size: 12))
                    }
                    .foregroundStyle(.white.opacity(0.55))
                }
            }
            HStack(spacing: 12) {
                Button {
                    primary(selected)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill").font(.system(size: 16, weight: .bold))
                        Text(ShellStrings.text("Play")).font(.system(size: 17, weight: .semibold))
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 26).padding(.vertical, 14)
                    .background(Capsule().fill(ShellPalette.cream))
                }
                .buttonStyle(.plain)
                .disabled(selected.game.state != .playable)

                circleButton("slider.horizontal.3") { openSettings() }
                circleButton("gamecontroller") { openControllers() }
                circleButton("gearshape") { openShellSettings() }
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder private func circleButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 48, height: 48)
                .background(Circle().fill(.white.opacity(0.12)))
                .overlay(Circle().strokeBorder(.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
    }
}
