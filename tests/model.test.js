// Run with: node --test tests/
const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")

function loadModel() {
  const source = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8")
    .replace(/^\.pragma library\s*$/m, "")
  const ctx = {}
  vm.createContext(ctx)
  vm.runInContext(source, ctx)
  return ctx
}

const M = loadModel()
const same = (a, e, msg) => assert.deepEqual(JSON.parse(JSON.stringify(a)), e, msg)

// Monday 2026-09-28 14:00 local.
const NOW = new Date(2026, 8, 28, 14, 0, 0).getTime()
const day = (n, h) => new Date(2026, 8, 28 + n, h || 0, 0, 0).getTime()

const tasks = [
  { uuid: "a", description: "Send counter-reply", project: "nostr4", dueMs: day(2), urgency: 15, bucket: "week" },
  { uuid: "b", description: "Book flight", project: "amsterdam", dueMs: day(-10), urgency: 12, bucket: "overdue" },
  { uuid: "c", description: "Read", project: "", dueMs: null, urgency: 1, bucket: "none" },
  { uuid: "d", description: "Call", project: "nostr4", dueMs: day(0, 23), urgency: 9, bucket: "today" },
  { uuid: "e", description: "Plan", project: "nostr4", dueMs: day(1), urgency: 20, bucket: "tomorrow" },
]

test("pill count follows the mode", () => {
  const counts = { due: 3, overdue: 2, pending: 50 }
  assert.equal(M.countForMode(counts, "due"), 3)
  assert.equal(M.countForMode(counts, "overdue"), 2)
  assert.equal(M.countForMode(counts, "pending"), 50)
  assert.equal(M.countForMode(null, "due"), 0)
})

test("summary leaves out zeros and pluralises", () => {
  assert.equal(M.summary({ overdue: 2, today: 0, tomorrow: 1, pending: 1, waiting: 0 }), "2 overdue · 1 tomorrow · 1 pending task")
  assert.equal(M.summary({ pending: 50, waiting: 3 }), "50 pending tasks · 3 waiting")
})

test("due labels are relative and short", () => {
  assert.equal(M.dueLabel(day(-3), NOW), "3d late")
  assert.equal(M.dueLabel(day(0, 23), NOW), "today")
  assert.equal(M.dueLabel(day(1), NOW), "tomorrow")
  assert.equal(M.dueLabel(day(4), NOW), "Fri")
  assert.equal(M.dueLabel(day(9), NOW), "Oct 7")
  assert.equal(M.dueLabel(new Date(2027, 2, 5).getTime(), NOW), "Mar 2027")
  assert.equal(M.dueLabel(null, NOW), "")
})

test("views filter by bucket and project", () => {
  same(M.filterTasks(tasks, "due", "").map(t => t.uuid), ["b", "d"])
  same(M.filterTasks(tasks, "today", "").map(t => t.uuid), ["b", "d", "e"])
  same(M.filterTasks(tasks, "week", "").map(t => t.uuid), ["a", "b", "d", "e"])
  same(M.filterTasks(tasks, "all", "").map(t => t.uuid), ["a", "b", "c", "d", "e"])
  same(M.filterTasks(tasks, "all", "nostr4").map(t => t.uuid), ["a", "d", "e"])
  same(M.filterTasks(tasks, "bogus", "").map(t => t.uuid), ["b", "d"], "unknown view falls back to due")
})

test("due views sort by date, all by urgency", () => {
  same(M.sortTasks(M.filterTasks(tasks, "week", ""), "week").map(t => t.uuid), ["b", "d", "e", "a"])
  same(M.sortTasks(tasks, "all").map(t => t.uuid), ["e", "a", "b", "d", "c"])
})

test("groups keep first-seen project order", () => {
  const groups = M.groupByProject(M.sortTasks(tasks, "all"))
  same(groups.map(g => [g.project, g.tasks.length]), [["nostr4", 3], ["amsterdam", 1], ["", 1]])
})

test("add text splits like a shell", () => {
  same(M.splitAddText('Call Alex project:nostr4 due:friday +call'), ["Call", "Alex", "project:nostr4", "due:friday", "+call"])
  same(M.splitAddText('Fix "the thing" due:tomorrow'), ["Fix", "the thing", "due:tomorrow"])
  same(M.splitAddText("   "), [])
})

test("digest days parse and label", () => {
  same(M.parseDigestDays("mon,tue,wed,thu,fri"), [false, true, true, true, true, true, false])
  same(M.parseDigestDays("Sat sun"), [true, false, false, false, false, false, true])
  same(M.parseDigestDays(""), [false, false, false, false, false, false, false])
  assert.equal(M.digestDaysLabel(M.parseDigestDays("mon,tue,wed,thu,fri")), "weekdays")
  assert.equal(M.digestDaysLabel(M.parseDigestDays("sat,sun")), "weekends")
  assert.equal(M.digestDaysLabel(M.parseDigestDays("mon,tue,wed,thu,fri,sat,sun")), "every day")
  assert.equal(M.digestDaysLabel(M.parseDigestDays("mon,thu")), "Mon, Thu")
  assert.equal(M.digestDaysText(M.parseDigestDays("sun,mon")), "mon,sun")
})

test("times parse and format", () => {
  same(M.parseHHMM("9:05"), { hour: 9, minute: 5 })
  same(M.parseHHMM("23:59"), { hour: 23, minute: 59 })
  assert.equal(M.parseHHMM("24:00"), null)
  assert.equal(M.parseHHMM("nine"), null)
  assert.equal(M.formatHHMM(9, 0), "09:00")
  assert.equal(M.hourLabel(0), "12 AM")
  assert.equal(M.hourLabel(13), "1 PM")
})

test("edit changes are the difference between task and form", () => {
  const task = { description: "Call Alex", project: "nostr4", priority: "M", dueMs: new Date(2026, 9, 7).getTime(), tags: ["call", "urgent"] }
  same(M.editChanges(task, { description: "Call Alex", project: "nostr4", priority: "M", due: "2026-10-07", tags: "call urgent" }), [])
  same(M.editChanges(task, { description: "Call Alex about equity", project: "", priority: "", due: "friday", tags: "+call, phone" }),
    ["description:Call Alex about equity", "project:", "priority:", "due:friday", "+phone", "-urgent"])
  same(M.editChanges(task, { description: "   ", project: "nostr4", priority: "M", due: "2026-10-07", tags: "call urgent" }), [], "blank description is ignored")
  same(M.editChanges({ description: "x", project: "", priority: "", dueMs: null, tags: [] }, { description: "x", project: "", priority: "H", due: "", tags: "" }), ["priority:H"])
})

test("links are checked before opening", () => {
  assert.equal(M.isSafeLink("https://gitlab.com/soapbox-pub/agora/-/work_items/44"), true)
  assert.equal(M.isSafeLink("http://example.com/a?b=c#d"), true)
  assert.equal(M.isSafeLink("ftp://example.com"), false)
  assert.equal(M.isSafeLink("https://example.com/a b"), false)
  assert.equal(M.isSafeLink("https://example.com/\u202emoc"), false)
  assert.equal(M.isSafeLink("https://example.com/\u0007"), false)
  assert.equal(M.isSafeLink("https://" + "x".repeat(2100)), false)
  assert.equal(M.isSafeLink(""), false)
})

test("notification text is escaped", () => {
  assert.equal(M.escapeMarkup("a <b> & c"), "a &lt;b&gt; &amp; c")
})
