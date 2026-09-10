// Firefox prefs managed by sidorenko_dotfiles (firefox/user.js).
// install.sh copies this into every profile it finds; edits here are lost.
//
// user.js is read at every startup and its values are written through into
// prefs.js, so DELETING a line here does not restore the default -- the old
// value stays in prefs.js until it is reset in about:config.
//
// Firefox reads user.js from inside each profile directory, so there is no
// single place to point it at; the file has to exist once per profile.

// ---------------------------------------------------------------------------
// Survive low memory instead of being OOM-killed
// ---------------------------------------------------------------------------
//
// Firefox has had a low-memory tab unloader since 93, and the Linux detector
// that drives it landed in 96 (bug 1532955). The pref that arms it still ships
// `false` on Linux while Windows and macOS get `true`, so on Linux the whole
// mechanism is present and idle.
//
// Idle is expensive here. With nothing watching, the first thing that notices
// memory running out is the kernel OOM killer, and what it takes is the
// biggest process -- the Firefox parent, i.e. the entire browser, with no
// crash report and no "tab crashed" page, just a session restored from
// scratch. Unloading one idle tab is a strictly better outcome than that.
user_pref("browser.tabs.unloadOnLowMemory", true);

// How little available memory counts as "low". The watcher polls
// /proc/meminfo every 5s (1s once it has tripped) and unloads ONE tab per
// tick, so the threshold has to be big enough to cover several seconds of
// allocation, not just the last moment before the wall.
//
// The stock trigger is MemAvailable below 200 MB or below 5% of RAM. On a
// 16 GiB machine that is ~780 MB: about two seconds of runway against a
// browser that can allocate hundreds of MB/s, which loses the race it exists
// to win. 25% gives roughly ten seconds, and by then the 1s poll is running
// and can shed several tabs.
//
// A percentage rather than the MB knob so this scales with whatever machine
// the repo lands on. The two are OR'd -- whichever trips first -- so the
// 200 MB default stays underneath as a harmless backstop and needs no
// override.
user_pref("browser.low_commit_space_threshold_percent", 25);

// Deliberately left alone: browser.tabs.min_inactive_duration_before_unload
// (default 600000, 10 min). It is the "how stale before a tab is a candidate"
// knob, not a pressure knob, and lowering it mostly buys the chance to unload
// something that was in use a few minutes ago.
