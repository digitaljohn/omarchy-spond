// Delegates in here reach out to the ids of the file they sit in, which is
// only legal when they are bound at creation rather than resolved through a
// context at use.
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// Spond in the bar: what wants an answer, and what you have agreed to.
//
// Those are two different questions and the panel keeps them apart. An
// unanswered invitation is work -- somebody is waiting on you, it expires, and
// the answer is one click. A commitment is a fact: it is settled, and all you
// want from it is to see it coming. So requests come first and carry their
// buttons with them, the week's fixtures follow as a plain list, and the bar
// counts the requests rather than naming the next match, because a number that
// means "two people are waiting on you" is worth a glance and a fixture you
// already agreed to is not.
//
// Everything that talks to Spond is in bin/spond, which is where the password
// lives. This file never holds a credential and never makes a request of its
// own; it runs that script and draws what comes back.
//
// Glyphs are \u escapes rather than literal characters, so the source survives
// editors and patches that mangle private-use codepoints.
Panel {
  id: root

  moduleName: "digitaljohn.spond"
  ipcTarget: "digitaljohn.spond"

  // The script sits next to this file, so the plugin runs from wherever it was
  // installed without putting anything on $PATH.
  readonly property string script:
    Qt.resolvedUrl("bin/spond").toString().replace(/^file:\/\//, "")

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color muted: Color.muted
  readonly property color accent: Color.accent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool vertical: bar ? bar.vertical : false

  // ----------------------------------------------------------------- settings

  readonly property int scheduleDays: setting("scheduleDays", 7)
  readonly property int requestDays: setting("requestDays", 30)
  readonly property int historyDays: setting("historyDays", 7)
  readonly property int pollMinutes: setting("pollMinutes", 15)
  readonly property string groupId: setting("groupId", "")
  readonly property int panelWidth: setting("panelWidth", 360)
  readonly property string barStyle: setting("barStyle", "Requests, then next")
  readonly property string barIcon: setting("barIcon", "\uf1e3")
  readonly property bool showLocation: setting("showLocation", true)
  readonly property bool hideWhenIdle: setting("hideWhenIdle", false)
  readonly property string webUrl: setting("webUrl", "https://spond.com/client")

  // -------------------------------------------------------------------- state

  property var events: []
  // The people this account answers for: yourself, or the children you are
  // guardian of, or both. More than one and every row has to say whose answer
  // it is; exactly one and the name is the same on every line and says nothing.
  property var people: []
  // Distinct names, not member records: the same child in two of a club's
  // groups is two member ids and one person, and a name repeated down every
  // row is noise rather than information.
  readonly property bool showNames: {
    var seen = []
    for (var i = 0; i < root.people.length; i++)
      if (seen.indexOf(root.people[i]) === -1) seen.push(root.people[i])
    return seen.length > 1
  }
  property string account: ""
  property bool signedIn: false
  property string errorText: ""
  property string errorHint: ""
  // Whether the thing standing between us and the events is a sign-in, as
  // opposed to a network that is down or a Spond that is having a moment. The
  // script says which in a code, because matching on the wording of an error
  // works right up until somebody improves the wording.
  property bool needsSignIn: false
  // Something that went wrong doing rather than fetching -- an answer Spond
  // would not take. It sits under the header and leaves the lists alone.
  property string noticeText: ""
  property bool everAnswered: false
  // True while the script is answering out of a fixture file instead of the
  // account. Said out loud in the header: made-up fixtures that look exactly
  // like the real thing are how you end up trusting one.
  property bool fixture: false
  // The event whose buttons are waiting on Spond, so the pair that was clicked
  // can go quiet without freezing the rest of the list.
  property string busyEvent: ""

  // An answer that has been chosen but not yet sent. Answering is the one
  // thing in here that other people see -- a mis-click tells a coach you are
  // not coming -- so the click chooses and a second click sends, and the row
  // says which answer it is about to send while it waits.
  property string pendingEvent: ""
  property bool pendingGoing: false
  property bool pendingLogout: false

  function ask(event, going) {
    root.pendingEvent = root.answerKey(event)
    root.pendingGoing = going
    pendingTimer.restart()
  }

  function cancelAsk() {
    root.pendingEvent = ""
    root.pendingLogout = false
    pendingTimer.stop()
  }

  function askLogout() {
    root.pendingLogout = true
    pendingTimer.restart()
  }

  // A primed answer is not left sitting there: come back to the panel ten
  // seconds later and the buttons are the ordinary pair again, not one click
  // away from telling someone you are out.
  Timer {
    id: pendingTimer
    interval: 10000
    onTriggered: {
      root.pendingEvent = ""
      root.pendingLogout = false
    }
  }

  // Ticks so "in 20 min" ages on screen instead of freezing at whatever it
  // said when the panel opened. Only while it is open: nothing outside the
  // panel is written in relative time.
  property double now: Date.now()

  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.now = Date.now()
  }

  // Qt decides for itself whether a string is markup, and a Text in that mode
  // will fetch <img src="http://..."> for real, from inside the shell process.
  // Every heading, place and group name here was typed by somebody else into
  // Spond, so the panel's own Text elements are pinned to PlainText and
  // anything bound for the bar's tooltip -- which belongs to the shell and is
  // not ours to pin -- has its angle brackets taken off first.
  function plain(s) {
    return String(s === undefined || s === null ? "" : s).replace(/[<>]/g, "")
  }

  // ------------------------------------------------------------------ the ask

  function cmd(args) {
    return [root.script].concat(args)
  }

  // Every command answers with one JSON object, so every reader wants the same
  // two things: the object, or null and a sentence saying why not.
  function parsed(text) {
    try {
      return JSON.parse(text)
    } catch (e) {
      root.errorText = "bin/spond did not answer with JSON"
      root.errorHint = "Run it in a terminal to see what it says"
      return null
    }
  }

  // What a confirmation and a busy spinner are keyed on. An event that invited
  // two of your children is two rows and two answers, so the event id alone
  // would light both.
  function answerKey(event) {
    return event.id + "/" + (event.memberId || "")
  }

  function refresh() {
    if (eventsProc.running) return
    // One fetch covers both halves: the requests window is the wider of the
    // two, and the schedule is cut out of the same answer below.
    var days = Math.max(root.scheduleDays, root.requestDays)
    var args = ["events", "--days", String(days), "--max", "200"]
    if (root.historyDays > 0) args = args.concat(["--past", String(root.historyDays)])
    if (root.groupId !== "") args = args.concat(["--group", root.groupId])
    eventsProc.command = root.cmd(args)
    eventsProc.running = true
  }

  Process {
    id: eventsProc
    stdout: StdioCollector {
      onStreamFinished: {
        root.everAnswered = true
        var data = root.parsed(text)
        if (!data) return
        root.noticeText = ""
        root.errorText = data.ok === true ? "" : (data.error || "Something went wrong")
        root.errorHint = data.ok === true ? "" : (data.hint || "")
        root.signedIn = data.signedIn === true
        root.needsSignIn = data.code === "NOT_SIGNED_IN" || data.code === "BAD_CREDENTIALS"
          || data.code === "TWO_FACTOR"
        if (data.ok !== true) {
          root.events = []
          return
        }
        root.account = data.account || ""
        root.people = data.people || []
        root.fixture = data.fixture === true
        root.events = data.events || []
        root.now = Date.now()
      }
    }
  }

  Timer {
    interval: Math.max(1, root.pollMinutes) * 60000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Opening the panel is a person asking to see the current state, which is
  // the one moment a poll interval is certainly wrong.
  onOpenedChanged: {
    if (opened) refresh()
    else cancelAsk()
  }

  // The one call that changes something at Spond's end. It carries the member
  // id the event was addressed to, which the script put in the payload: Spond
  // files responses under a per-group member id and not under your profile,
  // and the widget should not have to work out which is which.
  Process {
    id: respondProc
    stdout: StdioCollector {
      onStreamFinished: {
        root.busyEvent = ""
        var data = root.parsed(text)
        if (!data) return
        if (data.ok !== true) {
          // A notice rather than the error block: a refused answer is one row
          // going wrong, and hiding the whole panel behind it loses the eight
          // other things you can still see and still do.
          root.noticeText = data.error || "Spond would not take that answer"
          return
        }
        root.noticeText = ""
        // Refetch rather than trust the local guess: an accepted event can
        // come back as waiting-list when the squad was already full, and that
        // is exactly the case you want to be told about.
        root.refresh()
      }
    }
  }

  function respond(event, going) {
    if (respondProc.running) return
    root.cancelAsk()
    root.busyEvent = root.answerKey(event)
    // Answer optimistically so the row settles on the click rather than a
    // round trip later; the refetch above corrects it if Spond disagrees.
    var next = []
    for (var i = 0; i < root.events.length; i++) {
      var e = root.events[i]
      if (e.id === event.id) {
        e = JSON.parse(JSON.stringify(e))
        var members = e.members || []
        for (var j = 0; j < members.length; j++) {
          if (members[j].id === event.memberId)
            members[j].response = going ? "accepted" : "declined"
        }
        e.members = members
        if (members.length === 0) e.response = going ? "accepted" : "declined"
      }
      next.push(e)
    }
    root.events = next

    var args = ["respond", event.id, going ? "yes" : "no"]
    if (event.memberId) args = args.concat(["--member", event.memberId])
    respondProc.command = root.cmd(args)
    respondProc.running = true
  }

  // Signing in, from the panel rather than from a terminal. The password goes
  // down the script's stdin: not through argv, where every process on the
  // machine can read it out of /proc, and not through a file. It is held in
  // this process only between the click and the write, and the field is
  // emptied in the same breath.
  Process {
    id: loginProc
    property string account: ""
    property string secret: ""
    stdinEnabled: true
    onStarted: {
      write(account + "\n" + secret + "\n")
      account = ""
      secret = ""
    }
    stdout: StdioCollector {
      onStreamFinished: {
        var data = root.parsed(text)
        if (!data) return
        if (data.ok !== true) {
          root.errorText = data.error || "Spond would not sign you in"
          root.errorHint = data.hint || ""
          root.needsSignIn = true
          return
        }
        root.errorText = ""
        root.errorHint = ""
        root.needsSignIn = false
        root.signedIn = true
        root.refresh()
      }
    }
  }

  // Bound to the fields so the button greys out rather than swallowing a
  // click that was never going to do anything.
  readonly property bool signInReady:
    emailField.text !== "" && passwordField.text !== ""

  function signIn() {
    if (loginProc.running || !root.signInReady) return
    loginProc.account = emailField.text
    loginProc.secret = passwordField.text
    passwordField.text = ""
    loginProc.command = root.cmd(["login", "--stdin"])
    loginProc.running = true
  }

  Process {
    id: logoutProc
    stdout: StdioCollector {
      onStreamFinished: {
        root.cancelAsk()
        root.events = []
        root.account = ""
        // Ask again rather than assume: the refetch is what puts the panel
        // into its signed-out shape, through the same path as every other
        // sign-in failure.
        root.refresh()
      }
    }
  }

  function signOut() {
    if (logoutProc.running) return
    root.cancelAsk()
    logoutProc.command = root.cmd(["logout"])
    logoutProc.running = true
  }

  Process { id: browserProc }

  function openSpond() {
    if (browserProc.running) return
    browserProc.command = ["xdg-open", root.webUrl]
    browserProc.running = true
  }

  // ------------------------------------------------------------------- lists

  function startOf(event) { return new Date(Date.parse(event.start)) }
  function endOf(event) { return new Date(Date.parse(event.end || event.start)) }

  // What counts as wanting an answer. Availability requests are in here on
  // their own account: Spond calls them a different type, but the thing being
  // asked of you is the same thing, and unanswered is unanswered.
  function isRequest(event) {
    return event.response === "unanswered" || event.response === "unconfirmed"
  }

  readonly property var entries: {
    var out = []
    for (var i = 0; i < root.events.length; i++) {
      var event = root.events[i]
      var members = event.members || []
      if (members.length === 0) {
        out.push(event)
        continue
      }
      for (var j = 0; j < members.length; j++) {
        var entry = JSON.parse(JSON.stringify(event))
        entry.memberId = members[j].id
        entry.memberName = members[j].name
        entry.response = members[j].response
        out.push(entry)
      }
    }
    return out
  }

  readonly property var requests: {
    var horizon = root.now + root.requestDays * 86400000
    return root.entries.filter(function(e) {
      // Past invitations are not requests any more, whatever they still say:
      // there is nothing left to answer.
      return root.isRequest(e) && Date.parse(e.start) <= horizon
        && Date.parse(e.end || e.start) >= root.now
    })
  }

  readonly property var commitments: {
    var horizon = root.now + root.scheduleDays * 86400000
    return root.entries.filter(function(e) {
      return e.response === "accepted" && Date.parse(e.start) <= horizon
        && Date.parse(e.end || e.start) >= root.now
    })
  }

  readonly property var nextCommitment: commitments.length > 0 ? commitments[0] : null

  // The schedule reads as days rather than as a list of times, because "two
  // things on Saturday" is the shape of the question being asked of it.
  function groupByDay(list) {
    var out = []
    var lastKey = ""
    for (var i = 0; i < list.length; i++) {
      var event = list[i]
      var day = root.startOf(event)
      var key = day.getFullYear() + "-" + day.getMonth() + "-" + day.getDate()
      if (key !== lastKey) {
        out.push({ label: root.dayLabel(day), items: [] })
        lastKey = key
      }
      out[out.length - 1].items.push(event)
    }
    return out
  }

  readonly property var scheduleDaysModel: root.groupByDay(root.commitments)

  // What is behind you, newest first: last week read backwards from today is
  // how you remember a week, and it puts the thing you are most likely asking
  // about -- last night -- at the top of the section.
  readonly property var history: {
    if (root.historyDays <= 0) return []
    var floor = root.now - root.historyDays * 86400000
    return root.entries.filter(function(e) {
      return Date.parse(e.end || e.start) < root.now && Date.parse(e.start) >= floor
    }).sort(function(a, b) { return Date.parse(b.start) - Date.parse(a.start) })
  }

  readonly property var historyDaysModel: root.groupByDay(root.history)

  // Spond knows what you answered. Whether you actually turned up is between
  // you and the coach, so these say what you said rather than claiming you
  // were there.
  function answerLabel(event) {
    if (event.response === "accepted") return "yes"
    if (event.response === "declined") return "no"
    if (event.response === "waitinglist") return "waiting list"
    if (event.response === "unanswered" || event.response === "unconfirmed") return "no answer"
    return ""
  }

  // ------------------------------------------------------------------ labels

  function sameDay(a, b) {
    return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth()
      && a.getDate() === b.getDate()
  }

  function dayLabel(date) {
    if (sameDay(date, new Date(root.now))) return "Today"
    if (sameDay(date, new Date(root.now + 86400000))) return "Tomorrow"
    if (sameDay(date, new Date(root.now - 86400000))) return "Yesterday"
    return Qt.formatDate(date, "ddd d MMM")
  }

  // Hours and minutes, in whichever of the two ways the locale writes them.
  // The locale's own short pattern is not usable as-is: on this machine it
  // carries seconds, and a schedule reading 20:10:10 is three characters of
  // noise on every line. So the locale is asked only the one question it is
  // needed for -- am/pm or not -- and the pattern is written out here.
  readonly property bool twelveHour:
    /a/i.test(String(Qt.locale().timeFormat(Locale.ShortFormat)))

  readonly property string timeFormat: twelveHour ? "h:mm AP" : "HH:mm"

  function timeLabel(date) { return Qt.formatTime(date, root.timeFormat) }

  // "9:27–10:57 PM", not "9:27 PM–10:57 PM": a span that stays inside one half
  // of the day says which half once. Written out, the second version is wide
  // enough to push the fixture's name off the end of the row, which is the
  // half you cannot guess.
  function spanLabel(event) {
    var start = root.startOf(event)
    var end = root.endOf(event)
    if (isNaN(end.getTime()) || end.getTime() <= start.getTime())
      return root.timeLabel(start)
    // Take the meridiem off the front half rather than asking Qt for an
    // hour without one: bare "h" is the 24-hour hour, so 9pm formats as 21.
    if (root.twelveHour && Qt.formatTime(start, "AP") === Qt.formatTime(end, "AP"))
      return root.timeLabel(start).replace(/\s*[AP]\.?M\.?$/i, "") + "–" + root.timeLabel(end)
    return root.timeLabel(start) + "–" + root.timeLabel(end)
  }

  // Relative for anything close enough that the distance is the point, and the
  // day's name past that: "in 40 min" is useful, "in 9 days" is arithmetic
  // nobody asked for.
  function whenLabel(event) {
    var start = root.startOf(event)
    var ms = start.getTime() - root.now
    if (ms < 0) return "now"
    var minutes = Math.round(ms / 60000)
    if (minutes < 60) return "in " + minutes + " min"
    if (minutes < 1440) {
      var hours = Math.round(minutes / 60)
      return "in " + hours + (hours === 1 ? " hour" : " hours")
    }
    return root.dayLabel(start) + " " + root.timeLabel(start)
  }

  // --------------------------------------------------------------------- bar

  readonly property string barText: {
    if (root.barIcon === "") return ""
    if (root.vertical || root.barStyle === "Icon only") return root.barIcon
    if (root.errorText !== "") return root.barIcon
    if (root.requests.length > 0 && root.barStyle !== "Next commitment")
      return root.barIcon + " " + root.requests.length
    if (root.nextCommitment) {
      var start = root.startOf(root.nextCommitment)
      if (root.barStyle === "Next commitment")
        return root.barIcon + " " + root.plain(root.nextCommitment.heading)
          + " " + root.timeLabel(start)
      // The default only names a time, and only today's: a time with no date
      // beside it is read as today whether or not that was meant, so a fixture
      // on Thursday stays in the panel where its day is written down.
      if (sameDay(start, new Date(root.now)))
        return root.barIcon + " " + root.timeLabel(start)
    }
    return root.barIcon
  }

  readonly property string barTooltip: {
    if (root.errorText !== "") return root.plain("Spond: " + root.errorText)
    if (!root.everAnswered) return "Spond"
    var parts = []
    if (root.requests.length > 0)
      parts.push(root.requests.length + (root.requests.length === 1
        ? " invitation waiting on you" : " invitations waiting on you"))
    if (root.nextCommitment)
      parts.push("Next: " + root.plain(root.nextCommitment.heading) + " "
        + root.whenLabel(root.nextCommitment))
    else
      parts.push("Nothing in the next " + root.scheduleDays + " days")
    return root.plain(parts.join(" · "))
  }

  // Hiding an idle widget is a setting rather than the default: a bar item
  // that comes and goes moves everything beside it, and most people would
  // rather have a quiet icon than a bar that reshuffles when a fixture lands.
  visible: !root.hideWhenIdle || root.requests.length > 0 || root.nextCommitment !== null
    || root.errorText !== ""

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    bar: root.bar
    text: root.barText
    labelVisible: !root.vertical
    fontSize: Style.bar.iconFont

    // Accent, not the urgent red WidgetButton reaches for by default. An
    // unanswered invitation is a nudge, not an alarm; red in this bar means
    // something is wrong, and being asked to play football is not.
    active: root.requests.length > 0
    activeColor: root.accent
    dimmed: root.errorText !== "" || (!root.signedIn && root.everAnswered)
    tooltipText: root.barTooltip

    onPressed: function(b) {
      if (b === Qt.MiddleButton) {
        root.refresh()
        return
      }
      if (b === Qt.RightButton) {
        root.openSpond()
        return
      }
      root.toggle()
    }
  }

  // ------------------------------------------------------------------- panel

  // A KeyboardPanel rather than a plain popup: the sign-in fields are typed
  // into, and only a panel that has asked for keyboard focus receives keys.
  // This is the same base the Wi-Fi panel uses to take a passphrase.
  KeyboardPanel {
    id: panel
    anchorItem: button
    bar: root.bar
    owner: root
    open: root.opened
    // Signed out, the thing you came here to do is type an email, so that is
    // what holds focus; signed in there is nothing to type into and the key
    // catcher takes it so Escape still closes.
    focusTarget: root.needsSignIn ? emailField : keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(root.panelWidth))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    // Whatever the focused field does not want. Escape closes the panel, and
    // a primed answer dies with it.
    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
    }

    Flickable {
      id: scroll
      anchors.fill: parent
      contentWidth: width
      contentHeight: content.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      // A season's worth of fixtures is taller than a screen, and a panel that
      // silently loses its last day is worse than one that scrolls.
      interactive: contentHeight > height

      Column {
        id: content
        width: scroll.width
        spacing: Style.space(12)

        // ------------------------------------------------------------ header

        Item {
          width: parent.width
          height: Math.max(title.implicitHeight, refreshButton.height)

          PanelSectionHeader {
            id: title
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.fixture ? "SPOND · FIXTURE"
              : (root.account !== "" ? root.plain(root.account.toUpperCase()) : "SPOND")
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          PanelActionButton {
            id: refreshButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: "󰑐"
            tooltipText: eventsProc.running ? "Asking Spond…" : "Refresh"
            foreground: root.foreground
            fontFamily: root.fontFamily
            enabled: !eventsProc.running
            onClicked: root.refresh()
          }
        }

        Text {
          width: parent.width
          visible: root.noticeText !== ""
          text: root.plain(root.noticeText)
          color: Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
        }

        // ------------------------------------------------------- not signed in

        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.errorText !== ""

          Text {
            width: parent.width
            text: root.plain(root.errorText)
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
          }

          Text {
            width: parent.width
            visible: root.errorHint !== "" && !root.needsSignIn
            text: root.plain(root.errorHint)
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
          }
        }

        // -------------------------------------------------------------- sign in

        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: root.needsSignIn

          Text {
            width: parent.width
            text: "Spond has no way to authorise an app, so this signs in the way the app does: your account's email and password, kept in your login keyring."
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
          }

          TextField {
            id: emailField
            width: parent.width
            placeholderText: "Email"
            foreground: root.foreground
            accent: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            enabled: !loginProc.running
            onAccepted: passwordField.forceActiveFocus()
          }

          TextField {
            id: passwordField
            width: parent.width
            password: true
            placeholderText: "Password"
            foreground: root.foreground
            accent: root.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            enabled: !loginProc.running
            onAccepted: root.signIn()
          }

          Button {
            text: loginProc.running ? "Signing in…" : "Sign in"
            enabled: !loginProc.running && root.signInReady
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            foreground: root.foreground
            accent: root.accent
            bordered: true
            onClicked: root.signIn()
          }
        }

        // ------------------------------------------------------------ requests

        Column {
          width: parent.width
          spacing: Style.space(12)
          visible: root.errorText === ""

          PanelSectionHeader {
            text: root.requests.length > 0
              ? "WANTS AN ANSWER (" + root.requests.length + ")"
              : "WANTS AN ANSWER"
            foreground: root.requests.length > 0 ? root.accent : root.muted
            fontFamily: root.fontFamily
          }

          Text {
            width: parent.width
            visible: root.requests.length === 0
            text: root.everAnswered ? "Nothing waiting on you." : "Asking Spond…"
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            textFormat: Text.PlainText
          }

          Repeater {
            model: root.requests

            Column {
              id: request
              required property var modelData
              width: content.width
              spacing: Style.space(4)

              Text {
                width: parent.width
                text: root.plain(request.modelData.heading)
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                textFormat: Text.PlainText
                elide: Text.ElideRight
              }

              Text {
                width: parent.width
                text: {
                  var event = request.modelData
                  var parts = []
                  // Availability requests are asking whether you could, not
                  // whether you will. That changes what the buttons mean, so it
                  // leads the line rather than trailing off the end of it.
                  if (event.type === "AVAILABILITY") parts.push("availability")
                  if (root.showNames && event.memberName) parts.push(root.plain(event.memberName))
                  parts.push(root.whenLabel(event))
                  if (event.group !== "") parts.push(root.plain(event.group))
                  if (root.showLocation && event.place !== "") parts.push(root.plain(event.place))
                  return parts.join(" · ")
                }
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                textFormat: Text.PlainText
                elide: Text.ElideRight
              }

              // Choose. Nothing has been sent at this point.
              Row {
                spacing: Style.space(6)
                topPadding: Style.space(2)
                visible: root.pendingEvent !== root.answerKey(request.modelData)

                Button {
                  text: root.busyEvent === root.answerKey(request.modelData) ? "Sending…" : "Going"
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  foreground: root.foreground
                  accent: root.accent
                  bordered: true
                  enabled: root.busyEvent !== root.answerKey(request.modelData)
                  onClicked: root.ask(request.modelData, true)
                }

                Button {
                  text: "Can't"
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  foreground: root.muted
                  accent: root.accent
                  bordered: true
                  visible: root.busyEvent !== root.answerKey(request.modelData)
                  onClicked: root.ask(request.modelData, false)
                }
              }

              // Send. The question names the answer rather than asking "are
              // you sure": what you are about to tell people is the thing
              // worth reading back before it goes.
              Column {
                width: parent.width
                spacing: Style.space(4)
                topPadding: Style.space(2)
                visible: root.pendingEvent === root.answerKey(request.modelData)

                Text {
                  width: parent.width
                  text: {
                    var who = root.showNames && request.modelData.memberName
                      ? root.plain(request.modelData.memberName) : ""
                    if (who !== "")
                      return root.pendingGoing
                        ? "Tell Spond " + who + " is going?"
                        : "Tell Spond " + who + " cannot make it?"
                    return root.pendingGoing
                      ? "Tell Spond you are going?"
                      : "Tell Spond you cannot make it?"
                  }
                  color: root.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                }

                Row {
                  spacing: Style.space(6)

                  Button {
                    text: root.pendingGoing ? "Yes, going" : "Yes, can't"
                    fontFamily: root.fontFamily
                    fontSize: Style.font.bodySmall
                    foreground: root.foreground
                    accent: root.accent
                    bordered: true
                    onClicked: root.respond(request.modelData, root.pendingGoing)
                  }

                  Button {
                    text: "Cancel"
                    fontFamily: root.fontFamily
                    fontSize: Style.font.bodySmall
                    foreground: root.muted
                    accent: root.accent
                    onClicked: root.cancelAsk()
                  }
                }
              }
            }
          }
        }

        PanelSeparator {
          width: parent.width
          foreground: root.foreground
          visible: root.errorText === ""
        }

        // ------------------------------------------------------------ schedule

        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.errorText === ""

          PanelSectionHeader {
            text: "NEXT " + root.scheduleDays + " DAYS"
            foreground: root.muted
            fontFamily: root.fontFamily
          }

          Text {
            width: parent.width
            visible: root.commitments.length === 0
            text: root.everAnswered ? "Nothing committed." : "Asking Spond…"
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            textFormat: Text.PlainText
          }

          Repeater {
            model: root.scheduleDaysModel

            Column {
              id: day
              required property var modelData
              width: content.width
              spacing: Style.space(4)
              topPadding: Style.space(2)

              Text {
                text: day.modelData.label
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                textFormat: Text.PlainText
              }

              Repeater {
                model: day.modelData.items

                Item {
                  id: entry
                  required property var modelData
                  width: content.width
                  height: line.implicitHeight

                  Row {
                    id: line
                    width: parent.width
                    spacing: Style.space(8)

                    // The time column is fixed so the headings line up down the
                    // day: a ragged left edge is what makes a list of fixtures
                    // read as a pile rather than a schedule.
                    Text {
                      width: Style.space(116)
                      text: root.spanLabel(entry.modelData)
                      color: root.muted
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      textFormat: Text.PlainText
                      elide: Text.ElideRight
                    }

                    Text {
                      width: parent.width - Style.space(116) - Style.space(8)
                      text: {
                        var event = entry.modelData
                        var label = root.plain(event.heading)
                        if (root.showNames && event.memberName)
                          label += " · " + root.plain(event.memberName)
                        if (root.showLocation && event.place !== "")
                          label += " · " + root.plain(event.place)
                        return label
                      }
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      textFormat: Text.PlainText
                      elide: Text.ElideRight
                    }
                  }
                }
              }
            }
          }
        }

        PanelSeparator {
          width: parent.width
          foreground: root.foreground
          visible: root.errorText === "" && root.historyDays > 0
        }

        // ------------------------------------------------------------- history

        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.errorText === "" && root.historyDays > 0

          PanelSectionHeader {
            text: "LAST " + root.historyDays + " DAYS"
            foreground: root.muted
            fontFamily: root.fontFamily
          }

          Text {
            width: parent.width
            visible: root.history.length === 0
            text: root.everAnswered ? "Nothing in the last " + root.historyDays + " days." : "Asking Spond…"
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            textFormat: Text.PlainText
          }

          Repeater {
            model: root.historyDaysModel

            Column {
              id: pastDay
              required property var modelData
              width: content.width
              spacing: Style.space(4)
              topPadding: Style.space(2)

              Text {
                text: pastDay.modelData.label
                color: root.muted
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                textFormat: Text.PlainText
              }

              Repeater {
                model: pastDay.modelData.items

                Item {
                  id: pastEntry
                  required property var modelData
                  width: content.width
                  height: pastLine.implicitHeight

                  Row {
                    id: pastLine
                    width: parent.width
                    spacing: Style.space(8)

                    Text {
                      width: Style.space(76)
                      text: root.timeLabel(root.startOf(pastEntry.modelData))
                      color: root.muted
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      textFormat: Text.PlainText
                      elide: Text.ElideRight
                    }

                    Text {
                      width: parent.width - Style.space(76) - Style.space(68) - Style.space(16)
                      text: root.showNames && pastEntry.modelData.memberName
                        ? root.plain(pastEntry.modelData.heading) + " · "
                          + root.plain(pastEntry.modelData.memberName)
                        : root.plain(pastEntry.modelData.heading)
                      // What you turned down is still worth seeing, but it is
                      // not what the eye should land on.
                      color: pastEntry.modelData.response === "accepted" ? root.foreground : root.muted
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      textFormat: Text.PlainText
                      elide: Text.ElideRight
                    }

                    Text {
                      width: Style.space(68)
                      horizontalAlignment: Text.AlignRight
                      text: root.answerLabel(pastEntry.modelData)
                      color: pastEntry.modelData.response === "accepted" ? root.accent : root.muted
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      textFormat: Text.PlainText
                      elide: Text.ElideRight
                    }
                  }
                }
              }
            }
          }
        }

        // -------------------------------------------------------------- footer

        Item {
          width: parent.width
          height: openButton.implicitHeight

          Button {
            id: openButton
            anchors.left: parent.left
            text: "Open Spond"
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            foreground: root.muted
            accent: root.accent
            onClicked: root.openSpond()
          }

          Text {
            anchors.centerIn: parent
            visible: eventsProc.running || logoutProc.running
            text: logoutProc.running ? "Signing out…" : "Asking…"
            color: root.muted
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            textFormat: Text.PlainText
          }

          Button {
            anchors.right: parent.right
            visible: root.signedIn && !root.needsSignIn && !root.pendingLogout
            text: "Sign out"
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            foreground: root.muted
            accent: root.accent
            onClicked: root.askLogout()
          }
        }

        // Signing out throws away the stored password, and getting back in
        // means typing it again. Same second click as an answer.
        Row {
          width: parent.width
          spacing: Style.space(6)
          visible: root.pendingLogout
          layoutDirection: Qt.RightToLeft

          Button {
            text: "Cancel"
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            foreground: root.muted
            accent: root.accent
            onClicked: root.cancelAsk()
          }

          Button {
            text: "Yes, sign out"
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            foreground: root.foreground
            accent: root.accent
            bordered: true
            onClicked: root.signOut()
          }
        }
      }
    }
  }
}
