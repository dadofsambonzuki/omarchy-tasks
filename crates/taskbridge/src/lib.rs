//! The logic behind `taskbridge`: turning Taskwarrior's JSON export into the
//! snapshot the Omarchy shell plugin reads, and checking the arguments the
//! plugin sends back for mutations.
//!
//! Everything here is pure so it can be tested with a fixed clock. Running
//! `task` itself lives in `main.rs`.

use chrono::{DateTime, Days, NaiveDate, NaiveDateTime, TimeZone, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// One task as Taskwarrior exports it. Only the fields the plugin shows.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct RawTask {
    #[serde(default)]
    pub id: u64,
    #[serde(default)]
    pub uuid: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub project: Option<String>,
    #[serde(default)]
    pub priority: Option<String>,
    #[serde(default)]
    pub tags: Vec<String>,
    #[serde(default)]
    pub due: Option<String>,
    #[serde(default)]
    pub scheduled: Option<String>,
    #[serde(default)]
    pub wait: Option<String>,
    #[serde(default)]
    pub until: Option<String>,
    #[serde(default)]
    pub entry: Option<String>,
    #[serde(default)]
    pub modified: Option<String>,
    #[serde(default)]
    pub start: Option<String>,
    #[serde(default)]
    pub recur: Option<String>,
    #[serde(default)]
    pub urgency: f64,
    #[serde(default)]
    pub status: String,
    #[serde(default)]
    pub annotations: Vec<Value>,
    #[serde(default)]
    pub depends: Vec<String>,
    /// Derek's GitLab UDA (uda.gitlab_url in .taskrc); harmless when unset.
    #[serde(default)]
    pub gitlab_url: Option<String>,
}

/// Where a task falls relative to today, by calendar day in the local zone.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Bucket {
    Overdue,
    Today,
    Tomorrow,
    Week,
    Later,
    None,
}

/// One task as the plugin sees it. Times are epoch milliseconds so QML's
/// `new Date(ms)` takes them directly; `null` when the field is unset.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskOut {
    pub uuid: String,
    pub id: u64,
    pub description: String,
    pub project: String,
    pub priority: String,
    pub tags: Vec<String>,
    pub due_ms: Option<i64>,
    pub scheduled_ms: Option<i64>,
    pub wait_ms: Option<i64>,
    pub entry_ms: Option<i64>,
    pub urgency: f64,
    pub status: String,
    pub annotations: usize,
    /// Annotation texts, oldest first, for the expanded row.
    pub notes: Vec<String>,
    /// Every http(s) URL found in the description, annotations and the
    /// GitLab field, first one first, without duplicates.
    pub links: Vec<String>,
    pub recurring: bool,
    pub active: bool,
    pub blocked: bool,
    pub bucket: Bucket,
}

#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Counts {
    pub pending: usize,
    pub waiting: usize,
    pub overdue: usize,
    pub today: usize,
    pub tomorrow: usize,
    pub week: usize,
    /// Overdue plus due today: what the bar shows by default.
    pub due: usize,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectCount {
    pub name: String,
    pub pending: usize,
    pub overdue: usize,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub ok: bool,
    pub available: bool,
    pub task_version: String,
    pub generated_ms: i64,
    pub counts: Counts,
    pub projects: Vec<ProjectCount>,
    pub tasks: Vec<TaskOut>,
}

/// Taskwarrior writes timestamps as `20260331T040000Z`.
pub fn parse_ts(value: &str) -> Option<DateTime<Utc>> {
    NaiveDateTime::parse_from_str(value, "%Y%m%dT%H%M%SZ")
        .ok()
        .map(|naive| Utc.from_utc_datetime(&naive))
}

fn ms(value: &Option<String>) -> Option<i64> {
    value.as_deref().and_then(parse_ts).map(|t| t.timestamp_millis())
}

/// Bucket a due date by calendar day, seen from `today` in the local zone.
/// A task due today is "today" all day, not overdue at one minute past
/// midnight the way Taskwarrior's own `+OVERDUE` treats it.
pub fn bucket_for<Tz: TimeZone>(due: Option<DateTime<Utc>>, now: &DateTime<Tz>) -> Bucket {
    let Some(due) = due else { return Bucket::None };
    let today: NaiveDate = now.date_naive();
    let due_day: NaiveDate = due.with_timezone(&now.timezone()).date_naive();
    if due_day < today {
        Bucket::Overdue
    } else if due_day == today {
        Bucket::Today
    } else if Some(due_day) == today.checked_add_days(Days::new(1)) {
        Bucket::Tomorrow
    } else if due_day <= today.checked_add_days(Days::new(7)).unwrap_or(today) {
        Bucket::Week
    } else {
        Bucket::Later
    }
}

pub fn to_out<Tz: TimeZone>(raw: &RawTask, now: &DateTime<Tz>) -> TaskOut {
    let due = raw.due.as_deref().and_then(parse_ts);
    let notes: Vec<String> = raw
        .annotations
        .iter()
        .filter_map(|a| a.get("description").and_then(Value::as_str).map(str::to_string))
        .collect();
    TaskOut {
        uuid: raw.uuid.clone(),
        id: raw.id,
        description: raw.description.clone(),
        project: raw.project.clone().unwrap_or_default(),
        priority: raw.priority.clone().unwrap_or_default(),
        tags: raw.tags.clone(),
        due_ms: due.map(|t| t.timestamp_millis()),
        scheduled_ms: ms(&raw.scheduled),
        wait_ms: ms(&raw.wait),
        entry_ms: ms(&raw.entry),
        urgency: raw.urgency,
        status: raw.status.clone(),
        annotations: raw.annotations.len(),
        notes: notes.clone(),
        links: extract_links(&raw.description, &notes, raw.gitlab_url.as_deref()),
        recurring: raw.recur.is_some(),
        active: raw.start.is_some(),
        blocked: !raw.depends.is_empty(),
        bucket: bucket_for(due, now),
    }
}

/// Build the snapshot from an export. Pending tasks are listed; waiting ones
/// only when `include_waiting` is set (they are always counted).
pub fn build_snapshot<Tz: TimeZone>(
    raw: &[RawTask],
    now: &DateTime<Tz>,
    include_waiting: bool,
    task_version: &str,
) -> Snapshot {
    let mut counts = Counts::default();
    let mut tasks: Vec<TaskOut> = Vec::new();
    let mut projects: std::collections::BTreeMap<String, ProjectCount> = Default::default();

    for raw in raw {
        match raw.status.as_str() {
            "pending" => counts.pending += 1,
            "waiting" => {
                counts.waiting += 1;
                if !include_waiting {
                    continue;
                }
            }
            _ => continue,
        }
        let out = to_out(raw, now);
        match out.bucket {
            Bucket::Overdue => counts.overdue += 1,
            Bucket::Today => counts.today += 1,
            Bucket::Tomorrow => counts.tomorrow += 1,
            Bucket::Week => counts.week += 1,
            _ => {}
        }
        if raw.status == "pending" {
            let entry = projects.entry(out.project.clone()).or_insert_with(|| ProjectCount {
                name: out.project.clone(),
                pending: 0,
                overdue: 0,
            });
            entry.pending += 1;
            if out.bucket == Bucket::Overdue {
                entry.overdue += 1;
            }
        }
        tasks.push(out);
    }
    counts.due = counts.overdue + counts.today;

    // Most urgent first; ties by due date, then description, so the order
    // is stable between refreshes.
    tasks.sort_by(|a, b| {
        b.urgency
            .partial_cmp(&a.urgency)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.due_ms.unwrap_or(i64::MAX).cmp(&b.due_ms.unwrap_or(i64::MAX)))
            .then_with(|| a.description.cmp(&b.description))
    });

    Snapshot {
        ok: true,
        available: true,
        task_version: task_version.to_string(),
        generated_ms: now.timestamp_millis(),
        counts,
        projects: projects.into_values().collect(),
        tasks,
    }
}

/// The longest link the plugin will offer to open.
pub const MAX_LINK_LEN: usize = 2048;

/// A link the panel may show and open: http(s), no whitespace, no control
/// characters, and none of the Unicode bidi or joiner characters that let
/// one URL be displayed as another.
pub fn is_safe_link(url: &str) -> bool {
    if url.len() > MAX_LINK_LEN || !(url.starts_with("http://") || url.starts_with("https://")) {
        return false;
    }
    let scheme_end = url.find("://").map(|i| i + 3).unwrap_or(0);
    if url.len() <= scheme_end {
        return false;
    }
    !url.chars().any(|c| {
        c.is_whitespace()
            || c.is_control()
            || matches!(c,
                '\u{200b}'..='\u{200f}' | '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}' | '\u{feff}')
    })
}

/// URLs worth a button: http(s) links in the text, plus the GitLab field.
/// Trailing punctuation that usually ends a sentence is dropped, and only
/// links that pass `is_safe_link` are kept.
pub fn extract_links(description: &str, notes: &[String], gitlab_url: Option<&str>) -> Vec<String> {
    let mut links: Vec<String> = Vec::new();
    let mut push = |url: &str| {
        let url = url.trim_end_matches(|c| matches!(c, '.' | ',' | ';' | ':' | ')' | ']' | '>' | '"' | '\''));
        if is_safe_link(url) && !links.iter().any(|l| l == url) {
            links.push(url.to_string());
        }
    };
    if let Some(g) = gitlab_url {
        push(g.trim());
    }
    for text in std::iter::once(description).chain(notes.iter().map(String::as_str)) {
        for word in text.split_whitespace() {
            // The earliest scheme in the word wins, so "https://a/?r=http://b"
            // yields the https link, not the one inside its query.
            let start = [word.find("http://"), word.find("https://")]
                .into_iter()
                .flatten()
                .min();
            if let Some(i) = start {
                push(&word[i..]);
            }
        }
    }
    links
}

/// A full Taskwarrior UUID. Short forms are refused: the plugin always has
/// the full one, and a short prefix could match a different task later.
pub fn is_uuid(value: &str) -> bool {
    let b = value.as_bytes();
    if b.len() != 36 {
        return false;
    }
    b.iter().enumerate().all(|(i, c)| match i {
        8 | 13 | 18 | 23 => *c == b'-',
        _ => c.is_ascii_hexdigit() && !c.is_ascii_uppercase(),
    })
}

/// What `modify` may change. Anything else (a filter, `rc.` overrides,
/// a bare word that would rewrite the description) is refused.
pub fn is_allowed_modification(arg: &str) -> bool {
    const ATTRS: [&str; 7] = ["due:", "wait:", "scheduled:", "until:", "priority:", "project:", "description:"];
    if arg.starts_with('+') || arg.starts_with('-') {
        let body = &arg[1..];
        // "--" would turn the rest of the command line into description text.
        return !body.is_empty()
            && !body.starts_with('+')
            && !body.starts_with('-')
            && !body.chars().any(|c| c.is_whitespace() || c.is_control() || matches!(c, ':' | '='));
    }
    ATTRS.iter().any(|a| arg.starts_with(a))
}

/// Words for `task add`. Taskwarrior parses `project:` and `due:` itself;
/// the bridge only refuses configuration overrides.
pub fn is_allowed_add_word(arg: &str) -> bool {
    !(arg.starts_with("rc.") || arg.starts_with("rc:") || arg.is_empty())
}

pub fn unavailable(error: &str) -> Value {
    serde_json::json!({ "ok": false, "available": false, "error": error })
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::FixedOffset;

    fn now() -> DateTime<FixedOffset> {
        // 2026-09-28 14:00 in New York (UTC-4).
        FixedOffset::west_opt(4 * 3600)
            .unwrap()
            .with_ymd_and_hms(2026, 9, 28, 14, 0, 0)
            .unwrap()
    }

    fn task(uuid: &str, due: Option<&str>, status: &str, project: Option<&str>, urgency: f64) -> RawTask {
        RawTask {
            id: 1,
            uuid: uuid.into(),
            description: format!("task {uuid}"),
            due: due.map(String::from),
            status: status.into(),
            project: project.map(String::from),
            urgency,
            ..Default::default()
        }
    }

    #[test]
    fn parses_taskwarrior_timestamps() {
        let t = parse_ts("20260331T040000Z").unwrap();
        assert_eq!(t.to_rfc3339(), "2026-03-31T04:00:00+00:00");
        assert!(parse_ts("2026-03-31").is_none());
    }

    #[test]
    fn buckets_by_local_calendar_day() {
        let n = now();
        // Due "today" in Taskwarrior terms is local midnight: 04:00Z.
        assert_eq!(bucket_for(parse_ts("20260928T040000Z"), &n), Bucket::Today);
        // 23:59 local today is still today, not tomorrow (03:59Z next day).
        assert_eq!(bucket_for(parse_ts("20260929T035900Z"), &n), Bucket::Today);
        assert_eq!(bucket_for(parse_ts("20260929T040000Z"), &n), Bucket::Tomorrow);
        assert_eq!(bucket_for(parse_ts("20260927T040000Z"), &n), Bucket::Overdue);
        assert_eq!(bucket_for(parse_ts("20261005T040000Z"), &n), Bucket::Week);
        assert_eq!(bucket_for(parse_ts("20261006T040000Z"), &n), Bucket::Later);
        assert_eq!(bucket_for(None, &n), Bucket::None);
    }

    #[test]
    fn snapshot_counts_and_sorts() {
        let raw = vec![
            task("a", Some("20260927T040000Z"), "pending", Some("nostr4"), 12.0),
            task("b", Some("20260928T040000Z"), "pending", Some("nostr4"), 15.0),
            task("c", None, "pending", None, 1.0),
            task("d", Some("20261101T040000Z"), "waiting", Some("soapbox"), 3.0),
            task("e", None, "completed", None, 0.0),
        ];
        let snap = build_snapshot(&raw, &now(), false, "3.5.0");
        assert_eq!(snap.counts.pending, 3);
        assert_eq!(snap.counts.waiting, 1);
        assert_eq!(snap.counts.overdue, 1);
        assert_eq!(snap.counts.today, 1);
        assert_eq!(snap.counts.due, 2);
        assert_eq!(snap.tasks.len(), 3, "waiting tasks are left out unless asked for");
        assert_eq!(snap.tasks[0].uuid, "b", "highest urgency first");
        assert_eq!(snap.projects.len(), 2);
        assert_eq!(snap.projects[0].name, "", "no-project group sorts first");
        assert_eq!(snap.projects[1].name, "nostr4");
        assert_eq!(snap.projects[1].pending, 2);
        assert_eq!(snap.projects[1].overdue, 1);

        let with_waiting = build_snapshot(&raw, &now(), true, "3.5.0");
        assert_eq!(with_waiting.tasks.len(), 4);
        assert!(!with_waiting.projects.iter().any(|p| p.name == "soapbox"), "waiting tasks don't make project chips");
    }

    #[test]
    fn finds_links() {
        let notes = vec!["see https://gitlab.com/x/y/-/issues/1.".to_string()];
        let links = extract_links(
            "Review (https://example.com/a) and https://example.com/a",
            &notes,
            Some("https://gitlab.com/x/y/-/issues/1"),
        );
        assert_eq!(links, vec!["https://gitlab.com/x/y/-/issues/1", "https://example.com/a"]);
        assert!(extract_links("no links here", &[], None).is_empty());
        assert!(extract_links("x", &[], Some("not a url")).is_empty());
        // The outer scheme wins over one inside the query.
        assert_eq!(extract_links("https://evil.example/?r=http://good.example", &[], None), vec!["https://evil.example/?r=http://good.example"]);
        // Control, bidi and whitespace characters are refused, in text and in the UDA.
        assert!(extract_links("x", &[], Some("https://a.example/\u{202e}moc.elgoog")).is_empty());
        assert!(extract_links("x", &[], Some("https://a.example/one two")).is_empty());
        assert!(extract_links("https://a.example/\u{7}bell", &[], None).is_empty());
        let long = format!("https://a.example/{}", "x".repeat(MAX_LINK_LEN));
        assert!(extract_links(&long, &[], None).is_empty());
        assert!(!is_safe_link("https://"));
    }

    #[test]
    fn validates_uuids() {
        assert!(is_uuid("0063ee03-d4a0-4c90-bb39-4c8f0898754e"));
        assert!(!is_uuid("0063ee03"));
        assert!(!is_uuid("0063EE03-D4A0-4C90-BB39-4C8F0898754E"));
        assert!(!is_uuid("0063ee03-d4a0-4c90-bb39-4c8f0898754e; rm -rf /"));
    }

    #[test]
    fn restricts_modifications() {
        assert!(is_allowed_modification("due:tomorrow"));
        assert!(is_allowed_modification("wait:1w"));
        assert!(is_allowed_modification("+next"));
        assert!(is_allowed_modification("-next"));
        assert!(!is_allowed_modification("rc.data.location=/tmp"));
        assert!(!is_allowed_modification("status:pending"));
        assert!(!is_allowed_modification("new description"));
        assert!(!is_allowed_modification("+"));
        assert!(!is_allowed_modification("--"));
        assert!(!is_allowed_modification("-"));
        assert!(!is_allowed_modification("+due:tomorrow"));
        assert!(!is_allowed_modification("+a=b"));
        assert!(!is_allowed_modification("++x"));
        assert!(is_allowed_add_word("project:nostr4"));
        assert!(!is_allowed_add_word("rc.confirmation=on"));
    }
}
