import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
    id: root
    moduleName: "local.transcripts"
    ipcTarget: "local.transcripts"
    readonly property string helper: decodeURIComponent(Qt.resolvedUrl("transcripts.py").toString().replace(/^file:\/\//, ""))
    property var entries: []
    property var selected: null
    property int total: 0
    property int offset: 0
    property bool paused: false
    property bool showTrash: false
    property bool pendingRefresh: false
    property string notice: ""
    property string query: ""
    property string requestQuery: ""
    property int requestOffset: 0
    property bool requestTrash: false
    readonly property color fg: Color.foreground
    readonly property color muted: Qt.rgba(fg.r, fg.g, fg.b, 0.6)

    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    function refresh() {
        if (reader.running) { pendingRefresh = true; return }
        requestQuery = query
        requestOffset = offset
        requestTrash = showTrash
        reader.command = ["python3", helper, "list", "--query", query, "--offset", String(offset)]
            .concat(showTrash ? ["--trash"] : [])
        reader.running = true
    }

    function action(command, id) {
        if (writer.running) return
        notice = ""
        writer.actionName = command
        writer.command = ["python3", helper, command].concat(id === undefined ? [] : [String(id)])
        writer.running = true
    }

    function stamp(value) {
        return new Date(value).toLocaleString(Qt.locale(), "MMM d · h:mm AP")
    }

    onOpenedChanged: {
        if (opened) {
            notice = ""
            refresh()
        } else {
            selected = null
            entries = []
        }
    }
    onQueryChanged: { offset = 0; debounce.restart() }
    onShowTrashChanged: { offset = 0; selected = null; refresh() }
    onSelectedChanged: Qt.callLater(function() {
        if (!root.opened) return
        if (root.selected) backButton.forceActiveFocus()
        else search.forceActiveFocus()
    })

    Timer { id: debounce; interval: 180; onTriggered: root.refresh() }
    Timer { interval: 2000; repeat: true; running: root.opened; onTriggered: root.refresh() }

    Process {
        id: reader
        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                if (!root.opened || root.requestQuery !== root.query || root.requestOffset !== root.offset || root.requestTrash !== root.showTrash) return
                try {
                    var result = JSON.parse(text)
                    // Keep the list stable while reading or navigating it.
                    if (JSON.stringify(root.entries) !== JSON.stringify(result.entries)) root.entries = result.entries
                    root.total = result.total
                    root.paused = result.paused
                } catch (e) { root.notice = "Could not read history." }
            }
        }
        stderr: StdioCollector {}
        onExited: function(code) {
            if (code !== 0) root.notice = "Could not read history. Check storage access."
            if (root.pendingRefresh) { root.pendingRefresh = false; Qt.callLater(root.refresh) }
        }
    }

    Process {
        id: writer
        property string actionName: ""
        stdout: StdioCollector {}
        stderr: StdioCollector {}
        onExited: function(code) {
            if (code !== 0) root.notice = "Could not complete action. Check clipboard or storage access."
            else if (actionName === "copy") root.notice = "Copied — ready to paste."
            else if (actionName === "capture-clipboard") root.notice = "Clipboard text saved."
            else if (actionName === "trash" || actionName === "restore") {
                root.selected = null
                root.notice = actionName === "trash" ? "Moved to Trash. You can restore it there." : "Restored to history."
            }
            root.refresh()
        }
    }

    BarIconButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        text: "󰈙"
        tooltipText: "Transcripts"
        onPressed: root.toggle()
    }

    KeyboardPanel {
        id: panel
        anchorItem: button
        owner: root
        bar: root.bar
        open: root.opened
        focusTarget: search
        contentWidth: panel.fittedContentWidth(Style.space(460))
        contentHeight: panel.fittedContentHeight(Style.space(590), Style.space(590))

        ColumnLayout {
            anchors.fill: parent
            spacing: Style.space(10)
            Keys.onEscapePressed: {
                if (root.selected) { root.selected = null; search.forceActiveFocus() }
                else root.close()
            }

            RowLayout {
                Layout.fillWidth: true
                Text {
                    text: "Transcripts"
                    color: root.fg
                    font.family: Style.font.family
                    font.pixelSize: Style.font.heading
                    font.bold: true
                    Layout.fillWidth: true
                }
                PanelActionButton {
                    iconText: root.paused ? "▶" : "Ⅱ"
                    tooltipText: root.paused ? "Resume saving transcripts" : "Pause saving transcripts"
                    focusable: true
                    enabled: !writer.running
                    onClicked: root.action(root.paused ? "resume" : "pause")
                }
                PanelActionButton {
                    iconText: "×"
                    tooltipText: "Close"
                    focusable: true
                    onClicked: root.close()
                }
            }

            Text {
                Layout.fillWidth: true
                text: root.paused ? "Saving paused · your history stays here" : "Saved on this device · connected dictation tools"
                color: root.paused ? Color.accent : root.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                wrapMode: Text.Wrap
            }

            TextField {
                id: search
                Layout.fillWidth: true
                visible: !root.selected
                placeholderText: "Search transcripts or tools…"
                color: root.fg
                placeholderTextColor: root.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                selectByMouse: true
                onTextChanged: root.query = text
                background: Rectangle {
                    color: "transparent"
                    radius: Style.cornerRadius
                    border.color: search.activeFocus ? Color.accent : root.muted
                }
                Keys.onDownPressed: { history.forceActiveFocus(); history.currentIndex = 0 }
                onAccepted: if (root.entries.length) root.selected = root.entries[0]
            }

            RowLayout {
                visible: !root.selected
                Layout.fillWidth: true
                ActionButton {
                    label: root.showTrash ? "← History" : "Trash"
                    onChosen: root.showTrash = !root.showTrash
                }
                Item { Layout.fillWidth: true }
                ActionButton {
                    label: "Save clipboard"
                    enabled: !writer.running && !root.paused
                    onChosen: root.action("capture-clipboard")
                }
            }

            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true
                visible: !root.selected

                ListView {
                    id: history
                    anchors.fill: parent
                    clip: true
                    spacing: Style.space(7)
                    model: root.entries
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar {}
                    Keys.onReturnPressed: if (currentItem) root.selected = root.entries[currentIndex]
                    Keys.onEnterPressed: if (currentItem) root.selected = root.entries[currentIndex]
                    delegate: Rectangle {
                        required property var modelData
                        required property int index
                        width: history.width
                        height: entryColumn.implicitHeight + Style.space(24)
                        radius: Style.cornerRadius
                        color: rowMouse.containsMouse || (history.activeFocus && history.currentIndex === index)
                            ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.10)
                            : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.04)
                        Column {
                            id: entryColumn
                            anchors { left: parent.left; right: parent.right; top: parent.top; margins: Style.space(12) }
                            spacing: Style.space(6)
                            Text {
                                width: parent.width
                                text: modelData.source + " · " + root.stamp(modelData.created_at)
                                textFormat: Text.PlainText
                                color: root.muted
                                font.family: Style.font.family
                                font.pixelSize: Style.font.caption
                                elide: Text.ElideRight
                            }
                            Text {
                                width: parent.width
                                text: modelData.text
                                textFormat: Text.PlainText
                                color: root.fg
                                font.family: Style.font.family
                                font.pixelSize: Style.font.body
                                wrapMode: Text.Wrap
                                maximumLineCount: 3
                                elide: Text.ElideRight
                            }
                        }
                        MouseArea {
                            id: rowMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.selected = modelData
                        }
                    }
                }
                Text {
                    anchors.centerIn: parent
                    width: parent.width - Style.space(20)
                    visible: root.entries.length === 0
                    text: root.query ? "No matching transcripts."
                        : root.showTrash ? "Trash is empty."
                        : "Your words, kept here.\n\nDictate with a connected tool and the transcript will appear automatically."
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                    color: root.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                }
            }

            ColumnLayout {
                visible: !!root.selected
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: Style.space(10)
                RowLayout {
                    Layout.fillWidth: true
                    ActionButton { id: backButton; label: "← Back"; onChosen: { root.selected = null; search.forceActiveFocus() } }
                    Item { Layout.fillWidth: true }
                    ActionButton {
                        label: root.showTrash ? "Restore" : "Move to Trash"
                        enabled: !writer.running
                        onChosen: if (root.selected) root.action(root.showTrash ? "restore" : "trash", root.selected.id)
                    }
                    ActionButton {
                        label: "Copy"
                        enabled: !writer.running
                        onChosen: if (root.selected) root.action("copy", root.selected.id)
                    }
                }
                Text {
                    Layout.fillWidth: true
                    text: root.selected ? root.selected.source + " · " + root.stamp(root.selected.created_at) : ""
                    textFormat: Text.PlainText
                    color: root.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.Wrap
                }
                ScrollView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    contentWidth: availableWidth
                    TextArea {
                        text: root.selected ? root.selected.text : ""
                        textFormat: TextEdit.PlainText
                        readOnly: true
                        selectByMouse: true
                        wrapMode: TextEdit.Wrap
                        color: root.fg
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body
                        background: null
                    }
                }
            }

            RowLayout {
                visible: !root.selected
                Layout.fillWidth: true
                ActionButton {
                    label: "←"
                    enabled: root.offset > 0
                    onChosen: { root.offset = Math.max(0, root.offset - 50); root.refresh(); history.positionViewAtBeginning() }
                }
                Text {
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    text: root.total === 0 ? "0 transcripts" : (root.offset + 1) + "–" + Math.min(root.offset + 50, root.total) + " of " + root.total
                    color: root.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                }
                ActionButton {
                    label: "→"
                    enabled: root.offset + 50 < root.total
                    onChosen: { root.offset += 50; root.refresh(); history.positionViewAtBeginning() }
                }
            }
            Text {
                Layout.fillWidth: true
                visible: root.notice !== ""
                text: root.notice
                textFormat: Text.PlainText
                color: Color.accent
                wrapMode: Text.Wrap
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
            }
        }
    }

    component ActionButton: Rectangle {
        id: control
        property string label: ""
        signal chosen()
        implicitWidth: labelText.implicitWidth + Style.space(18)
        implicitHeight: Style.space(30)
        radius: Style.cornerRadius
        color: activeFocus || actionMouse.containsMouse ? Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12) : "transparent"
        opacity: enabled ? 1 : 0.4
        activeFocusOnTab: true
        Accessible.role: Accessible.Button
        Accessible.name: label
        Accessible.onPressAction: if (enabled) chosen()
        Keys.onReturnPressed: chosen()
        Keys.onSpacePressed: chosen()
        Text {
            id: labelText
            anchors.centerIn: parent
            text: control.label
            color: root.fg
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
        }
        MouseArea {
            id: actionMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: control.chosen()
        }
    }
}
