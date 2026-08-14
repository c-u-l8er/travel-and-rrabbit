// The saucer over the greeter, and the beam under it.
//
// This is RAVIO's, ported rather than reinvented: the emblem is the exact path
// from the steering-wheel hub (`site/ravio/index.html`, and the same one the
// RRABBIT cockpit paints in the middle of its yoke), and the beam is the same
// four-point quad with the same pulse, the same gradient stops and the same
// landing glow. The road on the wallpaper is the RAVIO road; the thing flying
// over it should be the RAVIO saucer and not a second drawing of one.
//
// TWO THINGS ARE DIFFERENT FROM THE WEB PAGE, both because the screen is doing
// a different job:
//   * on the page the ship TRACKS the cursor horizontally; here it patrols the
//     top of the screen back and forth on its own and only the BEAM follows the
//     pointer. A greeter's cursor spends its life inside a 460px panel, so a
//     ship that tracked it would sit still.
//   * the beam is painted BELOW the login panel. The panel is the thing you have
//     to be able to read; the ship is outside the window.
//
// IT LIVES IN ITS OWN FILE ON PURPOSE. Main.qml's first rule is that a greeter
// which fails to load shows a blank screen on a machine nobody can get into, so
// the ornament is reached through a Loader. If Canvas is missing from a build,
// or anything in here throws, the Loader logs it and the login fields are
// still there. Nothing below this line is allowed to be load-bearing.
import QtQuick 2.15

Item {
    id: sky
    anchors.fill: parent

    // RAVIO's greens, unchanged -- the saucer's own palette rather than the
    // greeter's amber/cyan, because this is a quotation and not a restyle.
    readonly property color hull:  "#6bf2c8"
    readonly property color brass: "#e8b75a"

    // ---- the clock ---------------------------------------------------------
    //
    // ONE CLOCK FOR BOTH. The ship's position and the beam's origin are the same
    // number, and reading them off two timers is how a beam ends up hanging off
    // the back of a ship that has already moved.
    //
    // 30Hz, NOT 60. The machine this ships to draws through scfb -- a plain
    // framebuffer with no acceleration -- and the greeter is a screen you look
    // at for four seconds. Half the frames for half the cost is the right trade
    // here in a way it would not be inside the session.
    //
    // AND IT PARKS. A greeter is not a page you close -- a VM left at the login
    // screen sits there for days, and 30 repaints a second of a full-screen
    // gradient on a machine with no GPU is a core spent on nobody. So the clock
    // runs for a while after the last time a hand moved the mouse, and then
    // stops with the ship where it is; the next movement starts it again.
    //
    // THE THRESHOLD IS A JUDGEMENT, NOT A MEASUREMENT. It has not been timed on
    // scfb -- that needs the image booted, and this was written on the
    // workstation. Two minutes is long enough that nobody who is looking at the
    // screen sees it stop, which is the property that matters; what it actually
    // saves on the target is unmeasured and is not claimed.
    property real t: 0
    property real idleFor: 0
    // Not readonly: the parking behaviour is the one thing here worth testing and
    // a test that has to wait two minutes to see it is a test nobody runs.
    property int parkAfter: 120000
    Timer {
        id: clock
        interval: 33; running: true; repeat: true
        onTriggered: {
            sky.t += 33
            sky.idleFor += 33
            if (sky.idleFor > sky.parkAfter) { running = false; return }
            beamCv.requestPaint()
        }
    }
    // The one place the clock is restarted. Called from the hover handler below,
    // which is the only evidence this screen has that anybody is in front of it.
    function stir() {
        idleFor = 0
        if (!clock.running) clock.running = true
    }

    // ---- where the pointer is ---------------------------------------------
    //
    // A HoverHandler and not a MouseArea. A full-screen MouseArea with
    // hoverEnabled sits over the panel and takes the hover the IGNITION button
    // needs for its own lit state; a hover handler is passive and leaves every
    // item under it receiving exactly what it received before.
    property real px: 0
    property real py: 0
    property bool havePointer: false
    HoverHandler {
        id: hover
        // IT TAKES A MOVE, NOT A POSITION, AND THAT WAS MEASURED. The handler
        // reports `hovered` true with a point already in hand the moment the
        // screen comes up -- the harness read `hovered=true p=8,8` before any
        // mouse existed -- so a beam armed by the first point it sees is a beam
        // aimed into the corner of the screen at a cursor nobody has touched.
        // Two DIFFERENT samples is the cheapest thing that means "a hand moved
        // this", and the second one arrives on the first real twitch.
        property real lastX: -1
        property real lastY: -1
        onPointChanged: if (hovered) {
            if (lastX >= 0 && (point.position.x !== lastX || point.position.y !== lastY)) {
                sky.havePointer = true
                sky.stir()
            }
            lastX = point.position.x
            lastY = point.position.y
            if (sky.havePointer) {
                sky.px = point.position.x
                sky.py = point.position.y
            }
        }
        onHoveredChanged: if (!hovered) sky.havePointer = false
    }

    // ---- the ship ----------------------------------------------------------
    //
    // A SINE AND NOT A SAWTOOTH. Back and forth either way, but a triangle wave
    // turns the ship around at full speed against the edge of the screen, which
    // reads as a bounce off a wall. A sine spends its slowest moments at the two
    // ends, which is what a thing that is looking rather than commuting does.
    readonly property real span: Math.max(80, width * 0.5 - 150)
    readonly property real shipX: width * 0.5 + Math.sin(t * 0.00035) * span
    readonly property real shipY: Math.max(70, height * 0.13) + Math.sin(t * 0.0013) * 9
    // Banking is read off the SAME sine, differentiated, rather than off the
    // difference between two frames -- a velocity measured from positions is a
    // frame late and jitters at the turnaround, exactly where the bank is most
    // visible.
    readonly property real bank: -Math.cos(t * 0.00035) * span * 0.00035 * 58

    // Same design-box scale Main.qml applies to the instrument panel: `sky`
    // fills the greeter, so its own height IS the screen's.
    readonly property real ui: Math.max(1, height / 900)

    Canvas {
        id: saucerCv
        width: 240; height: 170
        x: sky.shipX - width / 2
        y: sky.shipY - height / 2
        z: 2                       // over the panel: it never crosses it anyway
        rotation: sky.bank
        // SCALED, not repainted larger. The emblem is drawn once into an image
        // at fixed coordinates, so growing the canvas would need the paint code
        // to grow with it; an upscaled glow is a glow. It is an ornament.
        scale: sky.ui
        antialiasing: true
        renderTarget: Canvas.Image
        // PAINTED ONCE. The emblem does not change -- only where it is and which
        // way it is leaning, and both of those are the item's own transform. A
        // canvas that repainted the ship every frame would be doing the whole
        // drawing 30 times a second to produce an identical picture.
        onPaint: {
            var c = getContext("2d")
            c.clearRect(0, 0, width, height)
            c.save()
            c.translate(120, 85)
            c.scale(1.1, 1.1)
            c.translate(-100, -64)
            c.lineWidth = 2

            // the underside
            c.beginPath()
            c.moveTo(30, 58)
            c.quadraticCurveTo(100, 110, 170, 58)
            c.closePath()
            c.fillStyle = "#16182a"; c.fill()
            c.strokeStyle = sky.hull; c.stroke()

            // the rim
            c.beginPath()
            c.ellipse(5, 40, 190, 36)
            c.fillStyle = "#101220"; c.fill()
            c.strokeStyle = sky.hull; c.stroke()

            // the dome -- the TOP HALF of an ellipse, and it has to be built out
            // of a scaled arc. QtQuick's `ellipse(x, y, w, h)` is a bounding-box
            // call with no angles: it is not the browser's seven-argument
            // `ellipse`, and the page's dome is a half of one.
            c.save()
            c.translate(100, 56); c.scale(36 / 30, 1)
            c.beginPath()
            c.arc(0, 0, 30, Math.PI, 2 * Math.PI, false)
            c.closePath()
            c.fillStyle = "#1a1d2e"; c.fill()
            c.strokeStyle = sky.brass; c.stroke()
            c.restore()

            // the glint on it
            c.globalAlpha = 0.3
            c.beginPath(); c.ellipse(79, 31, 28, 18)
            c.fillStyle = sky.hull; c.fill()
            c.globalAlpha = 1

            // the five lamps
            var L = [[52, 62, sky.brass], [76, 66, sky.hull], [100, 67, sky.brass],
                     [124, 66, sky.hull], [148, 62, sky.brass]]
            for (var i = 0; i < L.length; i++) {
                c.beginPath()
                c.arc(L[i][0], L[i][1], 3.5, 0, Math.PI * 2)
                c.fillStyle = L[i][2]; c.fill()
            }
            c.restore()
        }
        Component.onCompleted: requestPaint()
    }

    // ---- the beam ----------------------------------------------------------
    //
    // AT HALF RESOLUTION AND SCALED BACK UP, which is the one liberty taken with
    // the port. This canvas is the whole screen and it is the only thing here
    // that is redrawn every frame; at 1280x800 on a software rasteriser that is
    // the entire cost of the ornament. A beam is a soft gradient with no edge to
    // lose, so a quarter of the pixels is invisible in the result and is not
    // invisible in the load. Every coordinate below is therefore in half-units.
    readonly property real k: 0.5
    Canvas {
        id: beamCv
        width: Math.max(1, sky.width * sky.k)
        height: Math.max(1, sky.height * sky.k)
        scale: 1 / sky.k
        transformOrigin: Item.TopLeft
        z: 0                       // under the panel -- see the header
        renderTarget: Canvas.Image
        onPaint: {
            var c = getContext("2d")
            c.clearRect(0, 0, width, height)
            if (sky.width <= 0) return

            var k = sky.k
            var ax = sky.shipX * k, ay = sky.shipY * k
            // Where it lands: the pointer, or -- until the mouse has ever moved --
            // straight down with a slow sway, which is RAVIO's idle behaviour and
            // is what keeps the ship from looking switched off.
            var bx = sky.havePointer ? sky.px * k
                                     : ax + Math.sin(sky.t * 0.0011) * sky.width * 0.05 * k
            var by = sky.havePointer ? sky.py * k : sky.height * 0.98 * k
            var span = 150 * k

            var ang = Math.atan2(by - ay, bx - ax)
            var len = Math.sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay))
            if (len < 1) return
            var pulse = 0.72 + 0.18 * Math.sin(sky.t * 0.002)
            var w0 = span * 0.16, w1 = span * 0.62
            var px = Math.cos(ang + Math.PI / 2), py = Math.sin(ang + Math.PI / 2)
            var fx = ax + Math.cos(ang) * len, fy = ay + Math.sin(ang) * len

            // ADDITIVE, which is what `mix-blend-mode: screen` was doing on the
            // page. Without it the beam is a grey wedge laid over the road rather
            // than light falling on it.
            c.globalCompositeOperation = "lighter"

            var grad = c.createLinearGradient(ax, ay, fx, fy)
            grad.addColorStop(0, Qt.rgba(0.42, 0.95, 0.78, 0.6 * pulse))
            grad.addColorStop(0.55, Qt.rgba(0.42, 0.95, 0.78, 0.22 * pulse))
            grad.addColorStop(1, Qt.rgba(0.42, 0.95, 0.78, 0))
            c.beginPath()
            c.moveTo(ax + px * w0, ay + py * w0)
            c.lineTo(fx + px * w1, fy + py * w1)
            c.lineTo(fx - px * w1, fy - py * w1)
            c.lineTo(ax - px * w0, ay - py * w0)
            c.closePath()
            c.fillStyle = grad; c.fill()

            // the bright core
            c.beginPath()
            c.moveTo(ax + px * w0 * 0.4, ay + py * w0 * 0.4)
            c.lineTo(fx + px * w1 * 0.32, fy + py * w1 * 0.32)
            c.lineTo(fx - px * w1 * 0.32, fy - py * w1 * 0.32)
            c.lineTo(ax - px * w0 * 0.4, ay - py * w0 * 0.4)
            c.closePath()
            c.fillStyle = Qt.rgba(0.59, 0.98, 0.86, 0.28 * pulse); c.fill()

            // and the glow where it lands
            var lg = c.createRadialGradient(fx, fy, 0, fx, fy, w1 * 1.1)
            lg.addColorStop(0, Qt.rgba(0.47, 0.96, 0.82, 0.4 * pulse))
            lg.addColorStop(1, Qt.rgba(0.42, 0.95, 0.78, 0))
            c.save()
            // The page drew this as a rotated ellipse 1.1:0.5; the same shape
            // here is a circle of the long radius squashed to the ratio.
            c.translate(fx, fy); c.rotate(ang); c.scale(1, 0.5 / 1.1)
            c.beginPath(); c.arc(0, 0, w1 * 1.1, 0, Math.PI * 2)
            c.fillStyle = lg; c.fill()
            c.restore()
        }
    }
}
