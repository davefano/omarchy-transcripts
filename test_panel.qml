import QtQuick
import QtTest
import Quickshell
import Quickshell.Io

ShellRoot {
    Process {
        id: pointerMove
        property int exitCode: -1
        onExited: function(code) { exitCode = code }
    }
    PanelWindow {
        anchors { top: true; left: true; right: true }
        implicitHeight: 32
        exclusionMode: ExclusionMode.Ignore
        Transcripts { id: plugin; anchors.centerIn: parent; manageIpc: false }
    }

    TestCase {
        name: "TranscriptPanel"
        when: true
        property var history
        property var search

        // Quickshell does not install QtTest's console logger.
        function check(condition) {
            try { verify(condition) }
            catch (error) { console.error(error.stack); throw error }
        }
        function equal(actual, expected) {
            try { compare(actual, expected) }
            catch (error) { console.error(actual + " != " + expected + "\n" + error.stack); throw error }
        }
        function eventually(item, property, expected) {
            try { tryCompare(item, property, expected) }
            catch (error) { console.error(property + ": " + item[property] + " != " + expected + "\n" + error.stack); throw error }
        }
        function movePointer(item, x, y) {
            // Wayland does not support QtTest's native cursor warping.
            var window = item.QsWindow.window
            var local = item.mapToItem(null, x, y)
            var point = Qt.point(window.screen.x + local.x, window.screen.y + local.y)
            pointerMove.exitCode = -1
            pointerMove.command = ["hyprctl", "eval", "hl.dispatch(hl.dsp.cursor.move({x="
                + Math.round(point.x) + ", y=" + Math.round(point.y) + "}))"]
            pointerMove.running = true
            eventually(pointerMove, "running", false)
            equal(pointerMove.exitCode, 0)
            wait(50)
            mouseMove(item, x + 1, y + 1)
            mouseMove(item, x, y)
        }

        function initTestCase() {
            history = findChild(plugin, "transcriptHistory")
            search = findChild(plugin, "transcriptSearch")
            check(history !== null && search !== null)
            parent = history
        }

        function init() {
            search.text = ""
            plugin.open()
            eventually(plugin, "requestQuery", "")
            search.forceActiveFocus()
            movePointer(search, 5, 5)
            eventually(history, "count", 50)
            eventually(plugin, "interacting", false)
            eventually(history.QsWindow.window, "backingWindowVisible", true)
            // KeyboardPanel primes Wayland focus for 75 ms after mapping.
            wait(200)
        }

        function cleanup() {
            console.log("Finished " + qtest_results.functionName + "; failures: " + qtest_results.failCount)
            plugin.close()
        }

        function incoming() {
            return { entries: [{ id: 999, source: "New tool", text: "New dictation",
                created_at: "2026-09-06T12:01:00+00:00" }].concat(plugin.entries),
                total: 51, has_more: false, offset: 0, paused: false }
        }

        function test_hover_defers_inflight_response_and_copies_original() {
            var row = history.itemAtIndex(0)
            check(row !== null)
            movePointer(row, 20, 20)
            eventually(plugin, "interacting", true)
            plugin.receiveResult(incoming())
            check(plugin.deferredResult !== null)
            equal(plugin.entries[0].id, 51)
            var copy = findChild(row, "copyTranscript")
            check(copy.visible)
            mouseClick(copy, copy.width / 2, copy.height / 2)
            var writer = findChild(plugin, "transcriptWriter")
            equal(writer.command[writer.command.length - 1], "51")
            eventually(plugin, "notice", "Copied — ready to paste.")
            equal(plugin.entries[0].id, 51)
            movePointer(search, 5, 5)
            search.forceActiveFocus()
            eventually(plugin, "interacting", false)
            eventually(plugin, "deferredResult", null)
        }

        function test_keyboard_defers_inflight_response() {
            search.forceActiveFocus()
            keyClick(Qt.Key_Down)
            eventually(history, "activeFocus", true)
            equal(history.currentItem.modelData.id, 51)
            keyClick(Qt.Key_Tab)
            var copy = findChild(history.currentItem, "copyTranscript")
            eventually(copy, "activeFocus", true)
            plugin.receiveResult(incoming())
            check(plugin.deferredResult !== null)
            equal(history.currentItem.modelData.id, 51)
            keyClick(Qt.Key_Return)
            eventually(plugin, "notice", "Copied — ready to paste.")
            equal(plugin.interacting, true)
            equal(history.currentItem.modelData.id, 51)
            // Supply the next poll result after the copy-triggered refresh.
            wait(200)
            plugin.receiveResult(incoming())
            search.forceActiveFocus()
            eventually(plugin, "interacting", false)
            eventually(plugin, "deferredResult", null)
            equal(plugin.entries[0].id, 999)
            equal(history.currentItem.modelData.id, 51)
        }

        function test_option_like_search() {
            search.text = "--help"
            eventually(plugin, "requestQuery", "--help")
            eventually(history, "count", 50)
            wait(300)
            equal(plugin.notice, "")
            equal(plugin.entries[0].id, 51)
        }

        function test_stale_deferred_search_is_discarded() {
            history.forceActiveFocus()
            plugin.receiveResult(incoming())
            check(plugin.deferredResult !== null)
            search.text = "missing"
            search.forceActiveFocus()
            eventually(history, "count", 0)
            equal(plugin.deferredResult, null)
            equal(plugin.total, 0)
        }

        function test_z_last_page_after_trash() {
            plugin.offset = 50
            plugin.refresh()
            eventually(history, "count", 1)
            equal(plugin.total, 51)
            equal(plugin.hasMore, false)
            plugin.selected = plugin.entries[0]
            plugin.action("trash", plugin.selected.id)
            eventually(plugin, "offset", 0)
            eventually(history, "count", 50)
            equal(plugin.total, 50)
            equal(plugin.hasMore, false)
            equal(plugin.selected, null)
        }

        function cleanupTestCase() {
            console.log(qtest_results.failCount === 0 ? "PANEL_TESTS_PASSED" : "PANEL_TESTS_FAILED")
            console.log("Qt checks: " + qtest_results.passCount + " passed; " + qtest_results.failCount + " failed")
        }
    }
}
