import XCTest
@testable import ShellHost
import ShellUI

final class ShellSettingsStoreTests: XCTestCase {
    func testGameWinsShellWinsBuiltin() {
        let game = UserDefaults(suiteName: "t-game-\(UUID().uuidString)")!
        let shell = ShellSettingsStore(defaults: UserDefaults(suiteName: "t-shell-\(UUID().uuidString)")!)
        // 无任何设置 → nil（游戏自己的行决定）
        XCTAssertNil(ShellSettingsStore.effective(game, shell: shell, key: "hud"))
        // 只有壳设置 → 壳的值
        shell.storePerformanceHUD(true)
        XCTAssertEqual(ShellSettingsStore.effective(game, shell: shell, key: "hud"), true)
        // 游戏也设了 → 游戏的值
        game.set(false, forKey: "hud")
        XCTAssertEqual(ShellSettingsStore.effective(game, shell: shell, key: "hud"), false)
    }
}
