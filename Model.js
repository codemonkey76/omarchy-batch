// Pure presentation logic for the Batch panel. Nothing here touches the
// filesystem or spawns anything — the helper owns every decision, this only
// decides how the answer reads.

// A reply is one line of compact JSON. Anything implausibly long is a
// malfunction, not a message, and is dropped rather than parsed.
var MAX_LINE = 65536

// Nerd Font glyphs, written as escapes so this file stays plain ASCII.
var ICON_IDLE = "\uf085"   // cogs
var ICON_WARN = "\uf071"   // warning triangle

function parseLine(line) {
  var text = String(line === undefined || line === null ? "" : line)
  if (text.length === 0 || text.length > MAX_LINE) return null
  try {
    var value = JSON.parse(text)
    return (value && typeof value === "object") ? value : null
  } catch (error) {
    return null
  }
}

function isRunning(job) {
  return !!job && job.state === "running"
}

function isFinished(job) {
  if (!job) return false
  return job.state === "finished" || job.state === "finished_with_errors"
      || job.state === "cancelled" || job.state === "interrupted"
}

// Processed counts only the files this run actually handed to the script;
// skipped ones cost nothing and would flatter the rate they are averaged into.
function processed(job) {
  if (!job) return 0
  return (job.done || 0) + (job.failed || 0)
}

function accountedFor(job) {
  return processed(job) + ((job && job.skipped) || 0)
}

function progress(job) {
  if (!job || !job.total) return 0
  var value = accountedFor(job) / job.total
  return value < 0 ? 0 : (value > 1 ? 1 : value)
}

function percent(job) {
  return Math.round(progress(job) * 100)
}

function elapsedSeconds(job, nowSec) {
  if (!job || !job.started) return 0
  var end = job.finished || nowSec
  var value = end - job.started
  return value > 0 ? value : 0
}

// Averaged over whole files, which is the only signal available — the helper
// cannot see inside a render. Returns -1 when there is nothing to average yet.
function etaSeconds(job, nowSec) {
  if (!isRunning(job)) return -1
  var did = processed(job)
  if (did < 1) return -1
  var remaining = (job.total || 0) - accountedFor(job)
  if (remaining <= 0) return 0
  return Math.round((elapsedSeconds(job, nowSec) / did) * remaining)
}

function fmtDuration(seconds) {
  var total = Math.max(0, Math.round(seconds))
  var hours = Math.floor(total / 3600)
  var minutes = Math.floor((total % 3600) / 60)
  var secs = total % 60
  if (hours > 0) return hours + "h " + (minutes < 10 ? "0" : "") + minutes + "m"
  if (minutes > 0) return minutes + "m " + (secs < 10 ? "0" : "") + secs + "s"
  return secs + "s"
}

function fmtBytes(bytes) {
  var value = Number(bytes) || 0
  var units = ["B", "KB", "MB", "GB", "TB"]
  var index = 0
  while (value >= 1024 && index < units.length - 1) {
    value = value / 1024
    index++
  }
  var digits = (index === 0 || value >= 100) ? 0 : 1
  return value.toFixed(digits) + " " + units[index]
}

function homePath(path, home) {
  var text = String(path || "")
  if (home && text.indexOf(home) === 0) return "~" + text.substring(home.length)
  return text
}

// Middle-elided from the left: the tail of a path says which folder this is,
// the head almost never does.
function shortPath(path, home, budget) {
  var text = homePath(path, home)
  var cap = budget || 38
  if (text.length <= cap) return text
  var tail = text.substring(text.length - (cap - 1))
  var slash = tail.indexOf("/")
  if (slash > 0 && slash < 12) tail = tail.substring(slash)
  return "…" + tail
}

function scriptLabel(entry) {
  if (!entry) return ""
  return entry.executable ? entry.name : entry.name + "  (not executable)"
}

function icon(job) {
  if (!job) return ICON_IDLE
  if (job.state === "finished_with_errors" || job.state === "interrupted") return ICON_WARN
  return ICON_IDLE
}

// The bar stays quiet unless there is something to say: a percentage while a
// batch runs, a marker if the last one ended badly, otherwise just the glyph.
function barText(job) {
  if (isRunning(job)) return ICON_IDLE + " " + percent(job) + "%"
  if (job && job.state === "finished_with_errors") return ICON_WARN
  if (job && job.state === "interrupted") return ICON_WARN
  return ICON_IDLE
}

function stateWord(job) {
  if (!job) return "Idle"
  switch (job.state) {
    case "running": return "Running"
    case "finished": return "Finished"
    case "finished_with_errors": return "Finished with errors"
    case "cancelled": return "Cancelled"
    case "interrupted": return "Interrupted"
    default: return "Idle"
  }
}

// One line under the title: what is happening, and the counts that matter.
function summary(job, scan, nowSec) {
  if (isRunning(job)) {
    var parts = [accountedFor(job) + " of " + (job.total || 0)]
    if (job.failed) parts.push(job.failed + " failed")
    var eta = etaSeconds(job, nowSec)
    if (eta >= 0) parts.push("~" + fmtDuration(eta) + " left")
    else parts.push(fmtDuration(elapsedSeconds(job, nowSec)) + " elapsed")
    return parts.join("  ·  ")
  }

  if (isFinished(job)) {
    var done = []
    if (job.done) done.push(job.done + " done")
    if (job.failed) done.push(job.failed + " failed")
    if (job.skipped) done.push(job.skipped + " skipped")
    if (!done.length) done.push("nothing to do")
    return stateWord(job) + "  ·  " + done.join("  ·  ")
  }

  if (scan && scan.total > 0) {
    var pending = scan.pending + (scan.pending === 1 ? " file" : " files")
    if (scan.skipped > 0) return pending + " to process  ·  " + scan.skipped + " already done"
    return pending + "  ·  " + fmtBytes(scan.bytes)
  }
  if (scan && scan.total === 0) return "No files in the input folder"
  return "Idle"
}

function tooltip(job, scan, nowSec) {
  if (isRunning(job)) {
    return "Batch: " + accountedFor(job) + " of " + (job.total || 0)
      + (job.current ? "\n" + job.current : "")
  }
  if (isFinished(job)) return "Batch: " + summary(job, scan, nowSec)
  return "Batch"
}
