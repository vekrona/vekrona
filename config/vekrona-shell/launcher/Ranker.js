.pragma library

// Pure ranking and frecency functions for the launcher. Nothing here touches the clock, the
// disk or QML objects: callers pass `now` and the stored frecency entries.

var HALF_LIFE_MS = 7 * 24 * 60 * 60 * 1000;
var BOOST_CAP = 0.2;
var PRUNE_BELOW = 0.05;

var EXACT_ALIAS = 1.0;
var ALIAS_PREFIX = 0.95;
var TITLE_PREFIX = 0.85;
var FUZZY_FLOOR = 0.4;
var FUZZY_CEILING = 0.7;
var SUBSTRING = 0.3;

function lower(value) {
    return value === undefined || value === null ? "" : String(value).toLowerCase();
}

function decayed(entry, now) {
    return entry.score * Math.pow(0.5, Math.max(0, now - entry.at) / HALF_LIFE_MS);
}

// The entries after one more use of `id` at `now`, with the entries that decayed to nothing dropped.
function bumped(entries, id, now) {
    var next = {};
    for (var key in entries) {
        if (decayed(entries[key], now) >= PRUNE_BELOW)
            next[key] = entries[key];
    }
    next[id] = { score: (entries[id] ? decayed(entries[id], now) : 0) + 1, at: now };
    return next;
}

// Throws on text that is not a frecency document, so the caller reports it instead of ranking on junk.
function parseEntries(text) {
    if (text.trim() === "")
        return {};
    var doc = JSON.parse(text);
    if (doc === null || typeof doc !== "object" || Array.isArray(doc))
        throw new Error("expected an object of {score, at} entries");
    for (var key in doc) {
        if (doc[key] === null || typeof doc[key].score !== "number" || typeof doc[key].at !== "number")
            throw new Error("entry '" + key + "' lacks a numeric score and at");
    }
    return doc;
}

function boost(entries, id, now) {
    if (!entries[id])
        return 0;
    return BOOST_CAP * (1 - Math.pow(0.5, decayed(entries[id], now)));
}

// The most frecent ids that `eligible(id)` accepts, best first.
function recentIds(entries, now, limit, eligible) {
    return Object.keys(entries)
        .filter(eligible)
        .map(function (id) { return { id: id, score: decayed(entries[id], now) }; })
        .sort(function (a, b) { return b.score - a.score || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0); })
        .slice(0, limit)
        .map(function (item) { return item.id; });
}

// The shortest window of `haystack` that holds `needle` as a subsequence, or null.
function subsequenceSpan(needle, haystack) {
    var best = null;
    for (var start = haystack.indexOf(needle[0]); start !== -1; start = haystack.indexOf(needle[0], start + 1)) {
        var matched = 1;
        var end = start;
        for (var at = start + 1; at < haystack.length && matched < needle.length; at++) {
            if (haystack[at] === needle[matched]) {
                matched++;
                end = at;
            }
        }
        if (matched < needle.length)
            break;
        if (best === null || end - start < best.end - best.start)
            best = { start: start, end: end };
    }
    return best;
}

function startsWord(text, index) {
    return index === 0 || /[^a-z0-9]/.test(text[index - 1]);
}

function fuzzyScore(needle, title) {
    var span = subsequenceSpan(needle, title);
    if (span === null)
        return 0;
    var compactness = needle.length / (span.end - span.start + 1);
    var wordStart = startsWord(title, span.start) ? 0.1 : 0;
    return Math.min(FUZZY_CEILING, FUZZY_FLOOR + 0.2 * compactness + wordStart);
}

// 0 when `query` (already lower case and trimmed) does not match the result, else a score in (0, 1].
function matchScore(result, query) {
    var title = lower(result.title);
    var aliases = (result.aliases || []).map(lower);
    if (aliases.indexOf(query) !== -1)
        return EXACT_ALIAS;
    if (aliases.some(function (alias) { return alias.indexOf(query) === 0; }))
        return ALIAS_PREFIX;
    if (title.indexOf(query) === 0)
        return TITLE_PREFIX + 0.05 * query.length / title.length;
    var fuzzy = fuzzyScore(query, title);
    if (fuzzy > 0)
        return fuzzy;
    var keywords = (result.keywords || []).map(lower);
    if (keywords.concat([lower(result.subtitle)]).some(function (field) { return field.indexOf(query) !== -1; }))
        return SUBSTRING;
    return 0;
}

// Results that match `text`, best first, as {result, score}. A result carrying its own `score` is trusted
// as is (no matching, no frecency). An empty `text` keeps the results in the order given.
function rank(results, text, weight, entries, now) {
    var query = lower(text).trim();
    var scored = [];
    for (var i = 0; i < results.length; i++) {
        var result = results[i];
        var score;
        if (typeof result.score === "number") {
            score = result.score * weight;
        } else if (query === "") {
            score = 0;
        } else {
            var match = matchScore(result, query);
            if (match === 0)
                continue;
            score = match * weight + boost(entries, result.id, now);
        }
        scored.push({ result: result, score: score, order: i });
    }
    if (query === "")
        return scored;
    return scored.sort(function (a, b) {
        if (a.score !== b.score)
            return b.score - a.score;
        var left = lower(a.result.title);
        var right = lower(b.result.title);
        if (left !== right)
            return left < right ? -1 : 1;
        return a.order - b.order;
    });
}

// groups: [{owner, title, items: [{result, score}]}], each already ranked. Drops empty groups, caps each
// at `limit` items and orders the groups by their best score (stable).
function sections(groups, limit) {
    return groups
        .map(function (group, order) { return { group: group, order: order }; })
        .filter(function (entry) { return entry.group.items.length > 0; })
        .sort(function (a, b) { return b.group.items[0].score - a.group.items[0].score || a.order - b.order; })
        .map(function (entry) {
            return { owner: entry.group.owner, title: entry.group.title, items: entry.group.items.slice(0, limit) };
        });
}
