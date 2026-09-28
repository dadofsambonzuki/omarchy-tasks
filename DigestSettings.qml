import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The gear view: when the daily digest notification goes out. Every change
// is written straight to shell.json through the panel's persistSettings.
Column {
  id: settings

  property bool enabled: true
  property string time: "09:00"
  property string days: Model.DEFAULT_DIGEST_DAYS
  property color foreground: Color.foreground
  property color dim: Qt.darker(foreground, 1.5)
  property string fontFamily: Style.font.family

  signal changed(var values)
  signal sendNow()
  signal closed()

  readonly property var parsedTime: Model.parseHHMM(time) || { hour: 9, minute: 0 }
  readonly property var dayFlags: Model.parseDigestDays(days)
  readonly property bool anyPopupOpen: hourBox.popupOpen || minuteBox.popupOpen

  spacing: Style.space(8)

  function hourOptions() {
    var out = []
    for (var h = 0; h < 24; h++) out.push({ value: String(h), label: Model.hourLabel(h) })
    return out
  }

  function toggleDay(index) {
    var flags = dayFlags.slice()
    flags[index] = !flags[index]
    settings.changed({ digestDays: Model.digestDaysText(flags) })
  }

  Item {
    width: parent.width
    implicitHeight: Math.max(settingsTitle.implicitHeight, closeButton.implicitHeight)

    Text {

      textFormat: Text.PlainText
      id: settingsTitle
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      text: "Daily digest"
      color: settings.foreground
      font.family: settings.fontFamily
      font.pixelSize: Style.font.subtitle
      font.bold: true
    }

    PanelActionButton {
      id: closeButton
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      iconText: "󰅙"
      tooltipText: "Back to the list"
      foreground: settings.foreground
      fontFamily: settings.fontFamily
      onClicked: settings.closed()
    }
  }

  Toggle {
    width: parent.width
    label: "Notify me once a day"
    description: settings.enabled
      ? "At " + Model.hourLabel(settings.parsedTime.hour).replace(" ", ":" + Model.pad2(settings.parsedTime.minute) + " ") + ", " + Model.digestDaysLabel(settings.dayFlags) + ", with what's overdue and due today."
      : "Off. Turn it on for a morning list of what's overdue and due today."
    checked: settings.enabled
    foreground: settings.foreground
    fontFamily: settings.fontFamily
    onClicked: settings.changed({ digestEnabled: !settings.enabled })
  }

  Row {
    spacing: Style.space(8)
    opacity: settings.enabled ? 1 : 0.5

    Dropdown {
      id: hourBox
      label: "Hour"
      width: Style.space(130)
      value: String(settings.parsedTime.hour)
      options: settings.hourOptions()
      foreground: settings.foreground
      fontFamily: settings.fontFamily
      onChanged: function(v) { settings.changed({ digestTime: Model.formatHHMM(parseInt(v, 10), settings.parsedTime.minute) }) }
    }

    Dropdown {
      id: minuteBox
      label: "Minute"
      width: Style.space(90)
      value: Model.pad2(settings.parsedTime.minute)
      options: ["00", "15", "30", "45"]
      foreground: settings.foreground
      fontFamily: settings.fontFamily
      onChanged: function(v) { settings.changed({ digestTime: Model.formatHHMM(settings.parsedTime.hour, parseInt(v, 10)) }) }
    }
  }

  Column {
    spacing: Style.space(4)
    opacity: settings.enabled ? 1 : 0.5

    Text {

      textFormat: Text.PlainText
      text: "Days"
      color: settings.dim
      font.family: settings.fontFamily
      font.pixelSize: Style.font.caption
    }

    Row {
      spacing: Style.space(4)

      Repeater {
        model: [1, 2, 3, 4, 5, 6, 0]

        Button {
          required property int modelData
          text: Model.DAY_LABELS[modelData]
          selected: settings.dayFlags[modelData]
          foreground: settings.foreground
          fontFamily: settings.fontFamily
          fontSize: Style.font.caption
          bordered: true
          horizontalPadding: Style.space(7)
          onClicked: settings.toggleDay(modelData)
        }
      }
    }
  }

  Row {
    spacing: Style.space(4)

    Button {
      text: "Send now"
      tooltipText: "Show the digest notification with today's list"
      foreground: settings.foreground
      fontFamily: settings.fontFamily
      fontSize: Style.font.caption
      bordered: true
      onClicked: settings.sendNow()
    }

    Button {
      text: "Weekdays"
      foreground: settings.foreground
      fontFamily: settings.fontFamily
      fontSize: Style.font.caption
      bordered: true
      onClicked: settings.changed({ digestDays: Model.DEFAULT_DIGEST_DAYS })
    }

    Button {
      text: "Every day"
      foreground: settings.foreground
      fontFamily: settings.fontFamily
      fontSize: Style.font.caption
      bordered: true
      onClicked: settings.changed({ digestDays: "mon,tue,wed,thu,fri,sat,sun" })
    }
  }

  Text {

    textFormat: Text.PlainText
    width: parent.width
    text: "Settings are saved to shell.json as you change them."
    color: settings.dim
    font.family: settings.fontFamily
    font.pixelSize: Style.font.caption
    wrapMode: Text.WordWrap
  }
}
