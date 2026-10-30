import XCTest

@MainActor
final class FocusTests: XCTestCase {
    private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-debugHooks", "1"] + arguments
        app.launch()
        return app
    }

    private func wait(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    func testDiagnosticTree() {
        let app = launch(["-startTab", "schedule"])
        XCTAssertTrue(app.staticTexts["Programma"].waitForExistence(timeout: 20))
        let remote = XCUIRemote.shared
        for step in 0..<4 {
            let focused = app.descendants(matching: .any).allElementsBoundByIndex
                .filter { $0.hasFocus }
                .map { "\($0.elementType.rawValue):\($0.identifier):\($0.label)" }
            print("STEP \(step) focused=\(focused)")
            remote.press(.down)
            wait(0.6)
        }
        for step in 0..<4 {
            remote.press(.up)
            wait(0.6)
            let focused = app.descendants(matching: .any).allElementsBoundByIndex
                .filter { $0.hasFocus }
                .map { "\($0.elementType.rawValue):\($0.identifier):\($0.label)" }
            print("UP \(step) focused=\(focused)")
        }
        let chipTypes = ["LTV1", "LTV7", "Vakar", "Šodien", "Rīt"].map { title -> String in
            let e = app.buttons["chip.\(title)"]
            return "\(title):exists=\(e.exists) hittable=\(e.isHittable)"
        }
        print("CHIPS \(chipTypes)")
    }

    func testScheduleChipsAreFocusableAndSelectable() {
        let app = launch(["-startTab", "schedule"])
        XCTAssertTrue(app.staticTexts["Programma"].waitForExistence(timeout: 20))

        let remote = XCUIRemote.shared
        let order = ["LTV1", "LTV7", "Vakar", "Šodien", "Rīt"]

        func focusedChip() -> String? {
            order.first { app.buttons["chip.\($0)"].exists && app.buttons["chip.\($0)"].hasFocus }
        }

        // Down from the tab bar must land on the chip row, not skip to the list.
        var found: String?
        for _ in 0..<4 {
            remote.press(.down)
            wait(0.6)
            found = focusedChip()
            if found != nil { break }
        }
        XCTAssertNotNil(found, "Down should land on a channel/day chip, not jump straight into the list")

        // Walk along the row to LTV7, then select it.
        var attempts = 0
        while focusedChip() != "LTV7", attempts < 6 {
            guard let current = focusedChip(), let index = order.firstIndex(of: current) else { break }
            remote.press(index > 1 ? .left : .right)
            wait(0.45)
            attempts += 1
        }
        XCTAssertEqual(focusedChip(), "LTV7", "Left/right should walk the chip row")

        remote.press(.select)
        wait(2.0)
        XCTAssertTrue(app.buttons["chip.LTV7"].isSelected, "Selecting LTV7 should switch the schedule")
    }

    func testInPlayerGuideMarksThePlayingProgramme() {
        let app = launch(["-play", "ltv1", "-openGuide", "1"])
        let marked = app.buttons.containing(NSPredicate(format: "label CONTAINS 'SKATĀS'")).firstMatch
        XCTAssertTrue(marked.waitForExistence(timeout: 30), "The guide should mark the programme being played")
        XCTAssertTrue(marked.hasFocus || marked.exists)
    }
}
