// PARKBSD greeter -- the cockpit, as the first thing the machine shows you.
//
// Deliberately QtQuick ONLY: no QtQuick.Controls, no SddmComponents. A greeter
// that fails to load its imports shows a blank screen with no way in, and the
// only place the error appears is a log inside a machine you cannot log into.
// Plain Rectangle + TextInput has nothing to fail.
//
// Palette is RAVIO's, same as the window manager:
//   #F2C14E amber  the lit instrument / the action
//   #2DE2E6 cyan   live readouts
//   #C8862A bronze rims
//   #FF5A3C orange failure
//   #03040a space, #f3ead4 warm cream text
import QtQuick 2.15

Rectangle {
    id: root
    width: 1280
    height: 800
    color: "#03040a"

    property color amber:  "#F2C14E"
    property color cyan:   "#2DE2E6"
    property color bronze: "#C8862A"
    property color warn:   "#FF5A3C"
    property color cream:  "#f3ead4"

    // The road, behind everything -- the same file the desktop uses, so the
    // login screen and the session you land in are one picture.
    Image {
        anchors.fill: parent
        source: "file:///usr/local/share/parkbsd/wallpaper.jpg"
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
    }
    // Darkened, or white text on a bright road is unreadable.
    Rectangle { anchors.fill: parent; color: "#03040a"; opacity: 0.62 }

    //-------------------------------------------------------------- the panel
    Rectangle {
        id: panel
        anchors.centerIn: parent
        width: 460
        height: 250
        radius: 6
        color: "#070a14"
        opacity: 0.96
        border.width: 1
        border.color: bronze

        // A thin amber rule across the top: the lit edge of an instrument.
        Rectangle {
            anchors { left: parent.left; right: parent.right; top: parent.top
                      leftMargin: 1; rightMargin: 1; topMargin: 1 }
            height: 2
            color: amber
        }

        Text {
            id: title
            anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: 22 }
            text: "PARKBSD"
            color: amber
            font { family: "DejaVu Sans"; pixelSize: 17; bold: true; letterSpacing: 5 }
        }
        Text {
            anchors { horizontalCenter: parent.horizontalCenter; top: title.bottom; topMargin: 4 }
            // sddm exposes the hostname; a fleet of identical greeters that
            // cannot tell you WHICH machine you are logging into is a trap.
            text: sddm.hostName
            color: "#6f7a92"
            font { family: "DejaVu Sans Mono"; pixelSize: 11; letterSpacing: 2 }
        }

        //---------------------------------------------------------- the fields
        Column {
            anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: 86 }
            spacing: 10

            Rectangle {
                width: 380; height: 34; radius: 4
                color: "#03040a"
                border.width: 1
                border.color: userIn.activeFocus ? cyan : "#1b2436"
                Text {
                    anchors { left: parent.left; leftMargin: 11; verticalCenter: parent.verticalCenter }
                    text: "USER"; color: "#43506b"
                    font { family: "DejaVu Sans"; pixelSize: 10; bold: true; letterSpacing: 2 }
                }
                TextInput {
                    id: userIn
                    anchors { left: parent.left; right: parent.right; leftMargin: 62; rightMargin: 11
                              verticalCenter: parent.verticalCenter }
                    color: cream
                    font { family: "DejaVu Sans Mono"; pixelSize: 13 }
                    focus: true
                    selectionColor: "#12304a"
                    selectedTextColor: cyan
                    onAccepted: passIn.forceActiveFocus()
                    KeyNavigation.tab: passIn
                }
            }

            Rectangle {
                width: 380; height: 34; radius: 4
                color: "#03040a"
                border.width: 1
                border.color: passIn.activeFocus ? cyan : "#1b2436"
                Text {
                    anchors { left: parent.left; leftMargin: 11; verticalCenter: parent.verticalCenter }
                    text: "KEY"; color: "#43506b"
                    font { family: "DejaVu Sans"; pixelSize: 10; bold: true; letterSpacing: 2 }
                }
                TextInput {
                    id: passIn
                    anchors { left: parent.left; right: parent.right; leftMargin: 62; rightMargin: 11
                              verticalCenter: parent.verticalCenter }
                    color: cream
                    font { family: "DejaVu Sans Mono"; pixelSize: 13 }
                    echoMode: TextInput.Password
                    passwordCharacter: "*"
                    selectionColor: "#12304a"
                    selectedTextColor: cyan
                    onAccepted: root.go()
                    KeyNavigation.tab: userIn
                }
            }

            //------------------------------------------------------- ignition
            Rectangle {
                id: btn
                width: 380; height: 36; radius: 4
                color: press.pressed ? "#241d0a" : (press.containsMouse ? "#141018" : "#0b1020")
                border.width: 1
                border.color: amber
                Text {
                    anchors.centerIn: parent
                    text: "IGNITION"
                    color: amber
                    font { family: "DejaVu Sans"; pixelSize: 12; bold: true; letterSpacing: 4 }
                }
                MouseArea {
                    id: press
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: root.go()
                }
            }
        }

        //------------------------------------------------------------- status
        Text {
            id: status
            anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 12 }
            text: ""
            color: warn
            font { family: "DejaVu Sans"; pixelSize: 11 }
        }
    }

    //--------------------------------------------------------------- readouts
    Text {
        anchors { left: parent.left; bottom: parent.bottom; leftMargin: 22; bottomMargin: 18 }
        color: cyan
        font { family: "DejaVu Sans Mono"; pixelSize: 12 }
        text: Qt.formatDateTime(clock.now, "HH:mm")  + "   " +
              Qt.formatDateTime(clock.now, "ddd dd MMM")
    }
    Item {
        id: clock
        property var now: new Date()
        Timer { interval: 1000; running: true; repeat: true
                onTriggered: clock.now = new Date() }
    }

    Text {
        anchors { right: parent.right; bottom: parent.bottom; rightMargin: 22; bottomMargin: 18 }
        // Which session will start. There is only one in this image, but saying
        // so beats a greeter that silently picks something.
        text: sessionModel.count > 0
              ? sessionModel.data(sessionModel.index(root.sessionIndex, 0), Qt.DisplayRole) : ""
        color: "#43506b"
        font { family: "DejaVu Sans"; pixelSize: 11; letterSpacing: 2 }
    }

    //------------------------------------------------------------------ logic
    property int sessionIndex: sessionModel.lastIndex

    function go() {
        status.text = ""
        sddm.login(userIn.text, passIn.text, sessionIndex)
    }

    Connections {
        target: sddm
        // Qt6/SDDM 0.21 signal handlers are named functions on Connections.
        function onLoginFailed() {
            status.text = "REFUSED"
            passIn.text = ""
            passIn.forceActiveFocus()
        }
        function onLoginSucceeded() {
            status.color = root.cyan
            status.text = "CLEARED"
        }
    }

    Component.onCompleted: userIn.forceActiveFocus()
}
