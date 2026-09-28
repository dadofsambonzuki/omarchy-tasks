.pragma library

// Pure helpers for the Tasks plugin: what the bar shows, how the panel
// filters, sorts and labels. No Qt calls so tests/model.test.js can run
// them under node.

var DAY_MS = 24 * 60 * 60 * 1000
var WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
var VIEWS = ["due", "today", "week", "all"]

function clampInt(value, fallback, min, max) {
  var n = parseInt(value, 10)
  if (isNaN(n)) n = fallback
  return Math.max(min, Math.min(max, n))
}

function normalizeView(view) {
  return VIEWS.indexOf(view) === -1 ? "due" : view
}

// The number on the bar pill.
function countForMode(counts, mode) {
  counts = counts || {}
  if (mode === "pending") return counts.pending || 0
  if (mode === "overdue") return counts.overdue || 0
  return counts.due || 0
}

function plural(n, word) {
  return n + " " + word + (n === 1 ? "" : "s")
}

// "3 overdue · 2 due today · 50 pending" for the bar tooltip and the
// panel header. Parts that are zero are left out.
function summary(counts) {
  counts = counts || {}
  var parts = []
  if (counts.overdue > 0) parts.push(counts.overdue + " overdue")
  if (counts.today > 0) parts.push(counts.today + " due today")
  if (counts.tomorrow > 0) parts.push(counts.tomorrow + " tomorrow")
  parts.push(plural(counts.pending || 0, "pending task"))
  if (counts.waiting > 0) parts.push(counts.waiting + " waiting")
  return parts.join(" · ")
}

function startOfDay(ms) {
  var d = new Date(ms)
  d.setHours(0, 0, 0, 0)
  return d.getTime()
}

// Whole calendar days from today to the given time, negative for the past.
function dayDelta(ms, nowMs) {
  return Math.round((startOfDay(ms) - startOfDay(nowMs)) / DAY_MS)
}

// Short due label for a row: "3d late", "today", "tomorrow", "Fri",
// "Oct 7", "Mar 2027".
function dueLabel(dueMs, nowMs) {
  if (dueMs === null || dueMs === undefined) return ""
  var delta = dayDelta(dueMs, nowMs)
  if (delta < 0) return (-delta) + "d late"
  if (delta === 0) return "today"
  if (delta === 1) return "tomorrow"
  var d = new Date(dueMs)
  if (delta < 7) return WEEKDAYS[d.getDay()]
  var now = new Date(nowMs)
  if (d.getFullYear() === now.getFullYear()) return MONTHS[d.getMonth()] + " " + d.getDate()
  return MONTHS[d.getMonth()] + " " + d.getFullYear()
}

// Full date for the expanded row.
function dueLong(dueMs) {
  if (dueMs === null || dueMs === undefined) return ""
  var d = new Date(dueMs)
  return WEEKDAYS[d.getDay()] + " " + MONTHS[d.getMonth()] + " " + d.getDate() + ", " + d.getFullYear()
}

function ageLabel(entryMs, nowMs) {
  if (!entryMs) return ""
  var days = Math.max(0, Math.floor((nowMs - entryMs) / DAY_MS))
  if (days === 0) return "added today"
  if (days < 30) return "added " + plural(days, "day") + " ago"
  if (days < 365) return "added " + plural(Math.floor(days / 30), "month") + " ago"
  return "added " + plural(Math.floor(days / 365), "year") + " ago"
}

function inView(task, view) {
  var b = task.bucket
  if (view === "due") return b === "overdue" || b === "today"
  if (view === "today") return b === "overdue" || b === "today" || b === "tomorrow"
  if (view === "week") return b === "overdue" || b === "today" || b === "tomorrow" || b === "week"
  return true
}

function filterTasks(tasks, view, project) {
  view = normalizeView(view)
  var out = []
  for (var i = 0; i < (tasks || []).length; i++) {
    var t = tasks[i]
    if (project !== "" && project !== null && project !== undefined && t.project !== project) continue
    if (!inView(t, view)) continue
    out.push(t)
  }
  return out
}

// Due-based views read best in date order; "all" keeps Taskwarrior's
// urgency order, which is what `task next` shows.
function sortTasks(list, view) {
  var copy = list.slice()
  if (normalizeView(view) === "all") {
    copy.sort(function(a, b) { return (b.urgency - a.urgency) || cmpDue(a, b) || cmpText(a, b) })
  } else {
    copy.sort(function(a, b) { return cmpDue(a, b) || (b.urgency - a.urgency) || cmpText(a, b) })
  }
  return copy
}

function cmpDue(a, b) {
  var da = a.dueMs === null || a.dueMs === undefined ? Infinity : a.dueMs
  var db = b.dueMs === null || b.dueMs === undefined ? Infinity : b.dueMs
  return da < db ? -1 : da > db ? 1 : 0
}

function cmpText(a, b) {
  return a.description < b.description ? -1 : a.description > b.description ? 1 : 0
}

// [{ project, tasks }], projects in first-seen order of the sorted list
// so the most pressing project comes first.
function groupByProject(list) {
  var groups = []
  var index = {}
  for (var i = 0; i < list.length; i++) {
    var p = list[i].project || ""
    if (!(p in index)) {
      index[p] = groups.length
      groups.push({ project: p, tasks: [] })
    }
    groups[index[p]].tasks.push(list[i])
  }
  return groups
}

// Words for `task add`, keeping "quoted phrases" together the way a shell
// would, since the helper passes them as separate arguments.
function splitAddText(text) {
  var words = []
  var re = /"([^"]*)"|'([^']*)'|(\S+)/g
  var m
  while ((m = re.exec(text || "")) !== null) {
    var w = m[1] !== undefined ? m[1] : m[2] !== undefined ? m[2] : m[3]
    if (w !== "") words.push(w)
  }
  return words
}

function priorityMark(priority) {
  return priority === "H" ? "!!!" : priority === "M" ? "!!" : priority === "L" ? "!" : ""
}

function projectLabel(project) {
  return project === "" ? "No project" : project
}

// ---- Daily digest settings.

var DAY_KEYS = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
var DAY_LABELS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
var DEFAULT_DIGEST_DAYS = "mon,tue,wed,thu,fri"

// "mon,tue,fri" -> [false, true, true, false, false, true, false], indexed
// like Date.getDay(). Unknown words are ignored; an empty string means no day.
function parseDigestDays(text) {
  var out = [false, false, false, false, false, false, false]
  var words = String(text === undefined || text === null ? "" : text).toLowerCase().split(/[\s,]+/)
  for (var i = 0; i < words.length; i++) {
    var at = DAY_KEYS.indexOf(words[i].slice(0, 3))
    if (at !== -1) out[at] = true
  }
  return out
}

function digestDaysText(days) {
  var keys = []
  for (var i = 1; i <= 7; i++) if (days[i % 7]) keys.push(DAY_KEYS[i % 7])
  return keys.join(",")
}

function digestDaysLabel(days) {
  var count = 0
  for (var i = 0; i < 7; i++) if (days[i]) count++
  if (count === 7) return "every day"
  if (count === 0) return "no days"
  if (count === 5 && days[1] && days[2] && days[3] && days[4] && days[5]) return "weekdays"
  if (count === 2 && days[0] && days[6]) return "weekends"
  var names = []
  for (var j = 1; j <= 7; j++) if (days[j % 7]) names.push(DAY_LABELS[j % 7])
  return names.join(", ")
}

// "9:00" or "09:00" -> { hour: 9, minute: 0 }; null when it isn't a time.
function parseHHMM(text) {
  var m = /^\s*(\d{1,2}):(\d{2})\s*$/.exec(String(text || ""))
  if (!m) return null
  var h = parseInt(m[1], 10), mi = parseInt(m[2], 10)
  if (h > 23 || mi > 59) return null
  return { hour: h, minute: mi }
}

function pad2(n) { return (n < 10 ? "0" : "") + n }

function formatHHMM(hour, minute) { return pad2(hour) + ":" + pad2(minute) }

function hourLabel(hour) {
  var h12 = hour % 12 === 0 ? 12 : hour % 12
  return h12 + (hour < 12 ? " AM" : " PM")
}

// ---- Editing a task in place.

function splitTags(text) {
  var out = []
  var words = String(text || "").split(/[\s,]+/)
  for (var i = 0; i < words.length; i++) {
    var w = words[i].replace(/^\+/, "")
    if (w !== "" && out.indexOf(w) === -1) out.push(w)
  }
  return out
}

// The due date as the editor shows it: an ISO day, which Taskwarrior reads back.
function dueEditText(dueMs) {
  if (dueMs === null || dueMs === undefined) return ""
  var d = new Date(dueMs)
  return d.getFullYear() + "-" + pad2(d.getMonth() + 1) + "-" + pad2(d.getDate())
}

// What `task modify` needs to turn `task` into `form`. Empty when nothing
// changed. Each entry is one argument; the helper checks them again.
function editChanges(task, form) {
  var changes = []
  var description = String(form.description || "").trim()
  if (description !== "" && description !== task.description) changes.push("description:" + description)
  var project = String(form.project || "").trim()
  if (project !== (task.project || "")) changes.push("project:" + project)
  var priority = String(form.priority || "")
  if (priority !== (task.priority || "")) changes.push("priority:" + priority)
  var due = String(form.due || "").trim()
  if (due !== dueEditText(task.dueMs)) changes.push("due:" + due)
  var before = task.tags || []
  var after = splitTags(form.tags)
  for (var i = 0; i < after.length; i++) if (before.indexOf(after[i]) === -1) changes.push("+" + after[i])
  for (var j = 0; j < before.length; j++) if (after.indexOf(before[j]) === -1) changes.push("-" + before[j])
  return changes
}

// ---- Links and notifications.

// A link the panel will open: http(s) only, no whitespace, no control or
// bidi characters, and not absurdly long. The helper applies the same rule;
// this is the second check before Qt.openUrlExternally.
function isSafeLink(url) {
  url = String(url || "")
  if (url.length === 0 || url.length > 2048) return false
  if (!/^https?:\/\/[^\s]+$/.test(url)) return false
  return !/[\u0000-\u001f\u007f\u200b-\u200f\u202a-\u202e\u2066-\u2069\ufeff]/.test(url)
}

// Notification daemons read the body as markup.
function escapeMarkup(text) {
  return String(text || "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
}
