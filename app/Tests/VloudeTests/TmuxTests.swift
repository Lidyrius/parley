import XCTest
@testable import Vloude

final class TmuxTests: XCTestCase {
    func testCommandsForPane() {
        let cmds = Tmux.sendKeysCommands(pane: "%3", text: "ja bitte")
        XCTAssertEqual(cmds?.count, 2)
        XCTAssertEqual(cmds?[0], ["send-keys", "-t", "%3", "-l", "ja bitte"])
        XCTAssertEqual(cmds?[1], ["send-keys", "-t", "%3", "Enter"])
    }

    func testLiteralTextNotInterpreted() {
        // Dangerous chars are just data in the argv array — no shell, no quoting bugs.
        let text = "rm -rf /; echo \"hi\"\nnewline $HOME"
        let cmds = Tmux.sendKeysCommands(pane: "%1", text: text)
        XCTAssertEqual(cmds?[0].last, text)
    }

    func testEmptyPaneReturnsNil() {
        XCTAssertNil(Tmux.sendKeysCommands(pane: "", text: "x"))
        XCTAssertNil(Tmux.sendKeysCommands(pane: "   ", text: "x"))
    }

    func testInjectSkipsWithoutPane() {
        XCTAssertFalse(Tmux.inject(pane: "", text: "x"))
    }
}
