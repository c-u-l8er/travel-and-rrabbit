// T&R greeter -- the cockpit, as the first thing the machine shows you.
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
// Still QtQuick only. `QtQuick.Window` was imported here for a while to reach
// `Screen`; it turned out to answer 0x0 on this image (see the size binding
// below), so the import went back out with it.
import QtQuick 2.15

Rectangle {
    id: root
    // THE SCREEN, NOT A NUMBER. This was `1280 x 800`, which was the guest's
    // framebuffer at the time and therefore looked exactly like "fills the
    // screen" for as long as nothing changed. Raise the framebuffer to 4K and
    // the greeter draws in the top-left eighth of it with black around --
    // measured, 1280x800+0+0 painted on 3840x2160. A hard-coded size that
    // happens to match is indistinguishable from a correct one until it does
    // not match.
    //
    // AND IT CANNOT COME FROM Qt. `Screen.width` is 0 here and SDDM's own
    // `screenModel.geometry(primary)` is `{width:0,height:0}` -- both measured,
    // by printing them on the greeter and reading a screenshot, because scfb
    // publishes no RandR outputs for Qt to read. `Xsetup` asks X directly with
    // `xrdb -symbols` and writes the answer into theme.conf, which SDDM loads
    // immediately afterwards and hands to a theme as `config`.
    //
    // The fallback is the old pair. If Xsetup did not run, this is exactly the
    // greeter that shipped before -- small on a big screen, but present, and a
    // greeter you can log into beats a correct size you cannot.
    width:  config.screenWidth  > 0 ? config.screenWidth  : 1280
    height: config.screenHeight > 0 ? config.screenHeight : 800
    color: "#03040a"

    // ...and the design still has one size it was drawn at. The panel below is
    // 460x250 with 11-17px type, which is a third of the width at 1280 and a
    // postage stamp at 3840. Everything anchored to the SCREEN (wallpaper,
    // saucer, corner readouts) follows the screen; the instrument panel is
    // scaled, so the cockpit keeps its proportions on any framebuffer.
    property real ui: Math.max(1, height / 900)


    property color amber:  "#F2C14E"
    property color cyan:   "#2DE2E6"
    property color bronze: "#C8862A"
    property color warn:   "#FF5A3C"
    property color cream:  "#f3ead4"

    // The road, behind everything -- the same file the desktop uses, so the
    // login screen and the session you land in are one picture.
    Image {
        anchors.fill: parent
        source: "file:///usr/local/share/tandr/wallpaper.jpg"
        fillMode: Image.PreserveAspectCrop
        asynchronous: true
    }
    // Darkened, or white text on a bright road is unreadable.
    Rectangle { anchors.fill: parent; color: "#03040a"; opacity: 0.62 }

    // The saucer patrolling the top of the screen, with RAVIO's tractor beam
    // under it aimed at the pointer. Same emblem as the steering-wheel hub in
    // the cockpit you are about to log into, over the same road.
    //
    // THROUGH A LOADER, WHICH IS THE WHOLE REASON IT IS A SEPARATE FILE. The
    // rule at the top of this file is that a greeter which fails to load leaves
    // a machine nobody can get into -- so an ornament must not be able to take
    // the login fields with it. Inline, a missing Canvas type or a typo in the
    // beam would be a compile error in Main.qml and a blank screen; here it is a
    // line in the log and a login screen without a spaceship.
    Loader {
        anchors.fill: parent
        source: "Saucer.qml"
        // Not asynchronous: it is one file with no I/O in it, and a Loader that
        // instantiates late would pop the ship in after the fields have already
        // been drawn.
        onStatusChanged: if (status === Loader.Error)
                             console.warn("tandr: no saucer -- the greeter is otherwise fine")
    }

    //-------------------------------------------------------------- the panel
    Rectangle {
        id: panel
        anchors.centerIn: parent
        width: 460
        height: 250
        scale: root.ui
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
            text: "T&R"
            color: amber
            font { family: "DejaVu Sans"; pixelSize: 17; bold: true; letterSpacing: 5 }
        }
        Text {
            anchors { horizontalCenter: parent.horizontalCenter; top: title.bottom; topMargin: 4 }
            // What the initials stand for. This is the first screen the machine
            // shows a stranger, and "T&R" alone names nothing.
            //
            // PlainText, not AutoText: the ampersand is the point of the name
            // and a rich-text guess would eat it as an entity.
            text: "Travel & RRABBIT"
            textFormat: Text.PlainText
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
        anchors { left: parent.left; bottom: parent.bottom
                  leftMargin: 22 * root.ui; bottomMargin: 18 * root.ui }
        color: cyan
        font { family: "DejaVu Sans Mono"; pixelSize: 12 * root.ui }
        text: Qt.formatDateTime(clock.now, "HH:mm")  + "   " +
              Qt.formatDateTime(clock.now, "ddd dd MMM")
    }
    Item {
        id: clock
        property var now: new Date()
        Timer { interval: 1000; running: true; repeat: true
                onTriggered: clock.now = new Date() }
    }

    // The hostname, moved off the panel and down here. It used to be the
    // subtitle under "T&R", which spent the most legible line on the screen
    // saying `tr4`. The reason it is still SOMEWHERE is unchanged: a fleet of
    // identical greeters that cannot tell you which machine you are logging
    // into is a trap. Which machine is a footnote; what the machine is, is not.
    Text {
        anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom
                  bottomMargin: 18 * root.ui }
        text: sddm.hostName
        color: "#43506b"
        font { family: "DejaVu Sans Mono"; pixelSize: 11 * root.ui; letterSpacing: 2 }
    }

    Text {
        anchors { right: parent.right; bottom: parent.bottom
                  rightMargin: 22 * root.ui; bottomMargin: 18 * root.ui }
        // Which session will start, and how to change it. This image ships TWO
        // sessions -- the cockpit and RRABBIT -- and this label was written when
        // it shipped one. Reading it back on a real boot it was BLANK, because
        // `sessionModel.lastIndex` is -1 until somebody has logged in once, and
        // a greeter that shows nothing while silently preselecting whichever
        // .desktop sorts first is exactly what the old comment said it was
        // there to prevent.
        // NOT Qt.DisplayRole. SDDM's SessionModel does not publish one, so
        // asking for it rendered the literal string "undefined" in the corner
        // of the login screen. Its roles start at Qt.UserRole: directory,
        // file, type, name, exec, comment -- so the name is UserRole + 4,
        // read off the running greeter rather than off a header.
        text: root.sessionIndex >= 0 && sessionModel.count > 0
              ? sessionModel.data(sessionModel.index(root.sessionIndex, 0), Qt.UserRole + 4)
                + (sessionModel.count > 1 ? "   ·   F2 TO CHANGE" : "")
              : ""
        color: "#43506b"
        font { family: "DejaVu Sans"; pixelSize: 11 * root.ui; letterSpacing: 2 }
    }

    //------------------------------------------------------------------ logic
    // Never -1: an unseeded state file must not mean "no session named".
    property int sessionIndex: sessionModel.lastIndex >= 0 ? sessionModel.lastIndex : 0

    // The session is choosable, or "beside, never instead" is not true of the
    // only screen where the choice can be made. Tab is taken by the field
    // chain, so F2 -- and the label above says so rather than hiding it.
    Shortcut {
        sequences: ["F2"]
        onActivated: if (sessionModel.count > 1)
                         root.sessionIndex = (root.sessionIndex + 1) % sessionModel.count
    }

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
