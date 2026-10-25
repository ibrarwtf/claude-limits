:- encoding(utf8).
% Behaviour shared by the macOS and Windows apps — the single source of truth.
% Run it as Prolog (logic/oracle.pl checks it against spec/cases.json) or
% compile it (logic/plc.pl → macos/core/Logic.swift, windows/core/Logic.cs).
%
% Conventions: `:- fn name(In…) -> Out.` declares a compiled function; the
% Prolog predicate takes the inputs then the output(s). Clauses are tried in
% order and the first whose head matches wins, so bodies never fail.
:- ensure_loaded(lang).

% ── Types ────────────────────────────────────────────────────────────────────
:- enum error = [
    token_not_found, parse_failed(detail: str), command_failed(detail: str),
    rate_limited(retry_after: opt(float)), auth_failed, forbidden,
    network_unavailable, request_timeout, http_error(code: int, detail: str)
].
:- native error = 'AppError'.
:- record sample(t: time, u: float).
:- native sample = 'HistorySample'(swift(timestamp, utilization), csharp('Timestamp', 'Utilization')).

% ── API response (GET /api/oauth/usage) ─────────────────────────────────────
% Field names are the JSON keys; each app gets them camelCased (Codable /
% DataContract). Since late 2026 the seven_day* buckets come back null and
% weekly usage arrives in `limits`.
:- json usage_bucket = [utilization: float, resets_at: opt(str)].
:- json extra_usage = [is_enabled: opt(bool), monthly_limit: opt(float), used_credits: opt(float),
                       utilization: opt(float), currency: opt(str)].
:- json limit_model = [display_name: opt(str)].
:- json limit_scope = [model: opt(limit_model)].
:- json usage_limit = [kind: opt(str), group: opt(str), percent: opt(float), resets_at: opt(str), scope: opt(limit_scope)].
:- json usage_response = [five_hour: opt(usage_bucket), seven_day: opt(usage_bucket),
                          seven_day_oauth_apps: opt(usage_bucket), seven_day_opus: opt(usage_bucket),
                          seven_day_sonnet: opt(usage_bucket), seven_day_cowork: opt(usage_bucket),
                          seven_day_omelette: opt(usage_bucket), extra_usage: opt(extra_usage),
                          limits: opt(list(usage_limit))].

% GET /repos/…/releases. digest is "sha256:<hex>" on assets uploaded since mid-2025.
:- json github_asset = [name: opt(str), browser_download_url: opt(str), digest: opt(str)].
:- json github_release = [tag_name: opt(str), draft: opt(bool), prerelease: opt(bool), assets: opt(list(github_asset))].
:- native github_asset = 'GitHubAsset'.
:- native github_release = 'GitHubRelease'.

% Claude Code's credentials file (or a shell command printing it).
:- json credentials_oauth = [accessToken: opt(str)].
:- json credentials = [claudeAiOauth: opt(credentials_oauth), accessToken: opt(str)].

% spec/fixtures/*.json — a canned response + history for snapshots (ago = seconds before now).
:- json fixture_point = [ago: float, u: float].
:- json fixture = [now: str, response: usage_response, history: list(fixture_point)].

% ── Persisted settings ───────────────────────────────────────────────────────
% UserDefaults on macOS, settings.json on Windows; the key is the camelCase
% name unless given. hide(Key) stores the inverse, so an unset key reads as
% "show" on a fresh install.
:- choice token_source = [auto, file, shell].
:- setting token_source: token_source = key(token_source_mode).
:- setting custom_file_path: str.
:- setting custom_shell_command: str.
:- setting last_successful_poll: opt(time).    % survives relaunch: no burst on restart
:- setting next_allowed_poll: opt(time).       % survives relaunch: honours Retry-After
:- setting last_response_JSON: json.           % shown on launch before the first poll
:- setting consecutive_rate_limits: int.       % back-off exponent
:- setting notified_thresholds: set(int).      % 80/95 already alerted this window…
:- setting last_notified_resets_at: opt(str).  % …keyed to this resets_at
:- setting show_percentage: bool = hide(hide_percentage).
:- setting show_wave: bool = hide(hide_wave).
:- setting show_reset_time: bool = hide(hide_reset_time).
:- setting show_pill: bool = hide(hide_pill).
:- setting pill_x: opt(int).
:- setting pill_y: opt(int).
:- setting did_first_launch: bool.

% ── Tuning ───────────────────────────────────────────────────────────────────
% Anthropic recomputes usage every ~5 min, so polling faster buys nothing.
:- const poll_interval = 180.0.
:- const click_cooldown = 5.0.      % manual refreshes closer than this just animate
:- const min_animation = 1.5.       % one full bounce of the refresh wave
:- const backoff_base = 300.0.      % 429 back-off: 5, 10, 20 min…
:- const backoff_cap = 1800.0.      % …capped at 30
:- const max_samples = 60.
:- const spark_width = 10.
:- const burn_window = 30.          % samples considered for the burn rate
:- const pace_buffer = 1.05.        % hysteresis so "over pace" doesn't flap
:- const gap_factor = 2.5.          % a gap this many polls long breaks continuity
:- const capped_at = 99.5.
:- const idle_below = 0.5.          % %/h
:- const big_drop = 5.0.            % a fall this large means the window rolled over
:- const reset_jitter = 300.0.      % resets_at drift (s) still counted as the same window
:- const marquee_frames = 60.
:- const marquee_speed = 1.17.      % chars per frame at 12 fps
:- const error_cycles = 3.

% ── Error copy ───────────────────────────────────────────────────────────────
:- fn error_symbol(error) -> str.        % compact, for the menu bar
error_symbol(token_not_found, "sign in").
error_symbol(parse_failed(_), "parse").
error_symbol(command_failed(_), "shell").
error_symbol(rate_limited(_), "rate limit").
error_symbol(auth_failed, "sign in").
error_symbol(forbidden, "403").
error_symbol(network_unavailable, "offline").
error_symbol(request_timeout, "timeout").
error_symbol(http_error(Code, _), S) :- format(string(S), "HTTP ~d", [Code]).

:- fn friendly_message(error) -> str.
friendly_message(token_not_found, "Couldn't find your Claude token. Open Settings and pick a token source.").
friendly_message(parse_failed(M), S) :- format(string(S), "Couldn't parse the response: ~w", [M]).
friendly_message(command_failed(M), S) :- format(string(S), "Shell command failed: ~w", [M]).
friendly_message(rate_limited(R), S) :-
    (   R == none -> S = "Rate limited by Anthropic. Will retry shortly."
    ;   N is truncate(R), format(string(S), "Rate limited by Anthropic — retrying in ~d seconds.", [N]) ).
friendly_message(auth_failed, "Your Claude token is invalid or expired. Run `claude` in a terminal to sign back in.").
friendly_message(forbidden, "Access forbidden. Your account may not have access to the usage API.").
friendly_message(network_unavailable, "Couldn't reach api.anthropic.com — check your internet connection.").
friendly_message(request_timeout, "Request to Anthropic timed out. Will try again on the next poll.").
friendly_message(http_error(C, B), S) :- prefix(B, 120, P), format(string(S), "Anthropic returned HTTP ~d. ~w", [C, P]).

:- fn marquee_text(error, opt(time), time) -> str.   % scrolls in the menu bar on cold-start errors
marquee_text(rate_limited(_), Until, Now, S) :-
    (   Until == none -> S = "rate limit reached"
    ;   Secs is max(0, truncate(secs(Now, Until))), M is Secs // 60, R is Secs rem 60,
        (   M > 0 -> format(string(S), "rate limit reached, retry in ~dm ~ds", [M, R])
        ;   format(string(S), "rate limit reached, retry in ~ds", [R]) ) ).
marquee_text(auth_failed, _, _, "sign in: run `claude` in terminal").
marquee_text(token_not_found, _, _, "token not configured · open settings").
marquee_text(forbidden, _, _, "access forbidden · check account access").
marquee_text(network_unavailable, _, _, "cannot reach api.anthropic.com").
marquee_text(request_timeout, _, _, "request timed out · trying again soon").
marquee_text(command_failed(M), _, _, S) :- prefix(M, 50, P), format(string(S), "shell command failed: ~w", [P]).
marquee_text(parse_failed(M), _, _, S) :- prefix(M, 50, P), format(string(S), "parse error: ~w", [P]).
marquee_text(http_error(C, _), _, _, S) :- format(string(S), "HTTP ~d from anthropic", [C]).

% HTTP status → error (none for 200). Each app parses Retry-After itself.
:- fn status_error(int, opt(float), str) -> opt(error).   % status, Retry-After, body
status_error(200, _, _, none).
status_error(401, _, _, auth_failed).
status_error(403, _, _, forbidden).
status_error(429, R, _, rate_limited(R)).
status_error(C, _, Body, http_error(C, P)) :- prefix(Body, 200, P).

% ── Durations ────────────────────────────────────────────────────────────────
% Countdown to resets_at: "4:32" / "18m"; none once it has passed, rather than
% a dishonest "0m".
:- fn countdown(opt(str), time) -> opt(str).
countdown(Iso, Now, Out) :-
    parse_iso(Iso, D),
    (   D == none -> Out = none
    ;   Total is truncate(secs(Now, D)),
        (   Total =< 0 -> Out = none
        ;   H is Total // 3600, M is Total rem 3600 // 60,
            (   H > 0 -> pad2(M, MM), format(string(Out), "~d:~w", [H, MM])
            ;   format(string(Out), "~dm", [M]) ) ) ).

:- fn next_attempt(int) -> str.
next_attempt(Secs, S) :-
    (   Secs =< 0 -> S = "trying now…"
    ;   Secs < 60 -> format(string(S), "~ds", [Secs])
    ;   Secs < 3600 -> M is Secs // 60, R is Secs rem 60, format(string(S), "~dm ~ds", [M, R])
    ;   H is Secs // 3600, M is Secs rem 3600 // 60, format(string(S), "~dh ~dm", [H, M]) ).

:- fn relative_time(time, time) -> str.  % ticks every second while the dropdown is open
relative_time(T, Now, S) :-
    Secs is max(0, truncate(secs(T, Now))),
    (   Secs < 60 -> format(string(S), "~ds ago", [Secs])
    ;   Secs < 3600 -> M is Secs // 60, R is Secs rem 60, format(string(S), "~dm ~ds ago", [M, R])
    ;   H is Secs // 3600, M is Secs rem 3600 // 60, format(string(S), "~dh ~dm ago", [H, M]) ).

:- fn hours_minutes(int) -> str.
hours_minutes(Mins, S) :-
    H is Mins // 60, M is Mins rem 60,
    ( H > 0 -> format(string(S), "~dh ~dm", [H, M]) ; format(string(S), "~dm", [M]) ).

% ── Burn rate & reset line ───────────────────────────────────────────────────
:- fn valid(list(sample)) -> list(sample).      % drop failed-poll sentinels (u < 0)
valid([], []).
valid([X|Xs], Out) :- valid(Xs, V), X = sample(_, U), ( U >= 0.0 -> Out = [X|V] ; Out = V ).

% Time-weighted burn over the latest continuous stretch: Σ Δpp / Σ Δsec, NOT a
% mean of per-pair rates, so Anthropic's lumpy updates can't inflate it. A
% rollover (big drop) or a sleep gap restarts the accumulation.
:- fn burn(list(sample), int, float, float) -> (float, float).
burn(S, I, Pp, Sec, PpOut, SecOut) :-
    length(S, N),
    (   I >= N -> PpOut = Pp, SecOut = Sec
    ;   nth0(I, S, sample(T1, U1)), J is I - 1, nth0(J, S, sample(T0, U0)),
        D is U1 - U0, Dt is secs(T0, T1), I1 is I + 1,
        (   Dt =< 0.0 -> burn(S, I1, Pp, Sec, PpOut, SecOut)
        ;   ( D < -big_drop ; Dt > poll_interval * gap_factor ) -> burn(S, I1, 0.0, 0.0, PpOut, SecOut)
        ;   Pp1 is Pp + max(0.0, D), Sec1 is Sec + Dt, burn(S, I1, Pp1, Sec1, PpOut, SecOut) ) ).

% "Resets @ 3:10 PM · 24%/h · safe ≤ 23%/h" and its seven siblings.
:- fn reset_line(float, opt(str), list(sample), time) -> str.
reset_line(U, Iso, Samples, Now, S) :-
    parse_iso(Iso, R),
    (   R == none -> S = "No active 5-hour window — starts on your next Claude request"
    ;   R =< Now -> S = "Window just reset — refreshing soon"
    ;   clock(R, C), Mins is max(0.0, secs(Now, R) / 60.0),
        (   U >= capped_at -> M is truncate(Mins), hours_minutes(M, W), format(string(S), "Capped — resets in ~w (@ ~w)", [W, C])
        ;   valid(Samples, V), K is burn_window, last_n(V, K, Recent), length(Recent, N),
            (   N < 3 -> format(string(S), "Resets @ ~w · click to refresh", [C])
            ;   burn(Recent, 1, 0.0, 0.0, Pp, Sec),
                ( Sec > 0.0 -> Rate is Pp / Sec * 3600.0 ; Rate = 0.0 ),
                (   Rate < idle_below ->
                    ( Sec < poll_interval * 2 -> format(string(S), "Resets @ ~w · measuring…", [C])
                    ; format(string(S), "Resets @ ~w · idle", [C]) )
                ;   Left is max(0.0, 100.0 - U),
                    ( Mins > 0.0 -> Safe is Left / Mins * 60.0 ; Safe = 0.0 ),
                    B is round(Rate), Sf is max(0, round(Safe)),
                    (   Rate > Safe * pace_buffer ->
                        To100 is truncate(Left / Rate * 60.0), hours_minutes(To100, W),
                        format(string(S), "Resets @ ~w · ~d%/h over safe ~d%/h · 100% in ~w", [C, B, Sf, W])
                    ;   format(string(S), "Resets @ ~w · ~d%/h · safe ≤ ~d%/h", [C, B, Sf]) ) ) ) ) ).

% Menu-bar sparkline: one bar per poll interval, height = burn rate normalised
% to pp-per-interval (0..3 → ▁..█), so a sleep gap reads low, not as a spike.
:- fn sparkline(list(sample), int) -> str.
sparkline(Samples, Width, S) :-
    valid(Samples, V), W1 is Width + 1, last_n(V, W1, R), length(R, N),
    Pad is max(0, Width - max(0, N - 1)),
    repeat_str("▁", Pad, P), bars(R, 1, B), string_concat(P, B, S).

:- fn bars(list(sample), int) -> str.
bars(R, I, S) :-
    length(R, N),
    (   I >= N -> S = ""
    ;   nth0(I, R, sample(T1, U1)), J is I - 1, nth0(J, R, sample(T0, U0)),
        D is U1 - U0, Dt is secs(T0, T1),
        ( D > 0.0, Dt > 0.0 -> Per is D / Dt * poll_interval ; Per = 0.0 ),
        L is min(7, max(0, round(max(0.0, min(Per, 3.0)) / 3.0 * 7))),
        bar(L, C), I1 is I + 1, bars(R, I1, Rest), string_concat(C, Rest, S) ).

:- fn bar(int) -> str.
bar(L, C) :- char_at("▁▂▃▄▅▆▇█", L, C).

% Settings header graph: history with errors as 0, smoothed by a centred
% 3-point moving average and tiled 3× so the rolling-window cadence reads even
% from one session. Fewer than 2 samples → nothing to draw.
:- fn wave_values(list(sample)) -> list(float).
wave_values(S, Out) :-
    zeroed(S, Z), length(Z, N),
    ( N < 2 -> Out = [] ; smooth(Z, 0, N, M), append(M, M, MM), append(MM, M, Out) ).
:- fn zeroed(list(sample)) -> list(float).
zeroed([], []).
zeroed([X|Xs], [V|Vs]) :- X = sample(_, U), ( U < 0.0 -> V = 0.0 ; V = U ), zeroed(Xs, Vs).
:- fn smooth(list(float), int, int) -> list(float).
smooth(Z, I, N, Out) :-
    (   I >= N -> Out = []
    ;   Lo is max(0, I - 1), Hi is min(N - 1, I + 1), sum_from(Z, Lo, Hi, 0.0, Sum),
        A is Sum / float(Hi - Lo + 1), I1 is I + 1, smooth(Z, I1, N, Rest), Out = [A|Rest] ).
:- fn sum_from(list(float), int, int, float) -> float.   % left fold, same rounding as the apps had
sum_from(Z, I, Hi, Acc, S) :- ( I > Hi -> S = Acc ; nth0(I, Z, V), Acc1 is Acc + V, I1 is I + 1, sum_from(Z, I1, Hi, Acc1, S) ).

% Refresh / error animation: a single peak bouncing across ten cells.
:- fn wave_frame(int) -> str.
wave_frame(Step, S) :- P is Step rem 18, ( P < 10 -> I = P ; I is 18 - P ), wave_cells(I, 0, S).
:- fn wave_cells(int, int) -> str.
wave_cells(I, J, S) :-
    (   J >= 10 -> S = ""
    ;   L is max(0, 7 - abs(I - J)), bar(L, C), J1 is J + 1, wave_cells(I, J1, R), string_concat(C, R, S) ).

% Cold-start error animation, frame by frame: ~1.5 s of bouncing wave, then
% the message scrolls through a Width-char window; none once it's played
% error_cycles times (the static error symbol shows from then on).
:- fn error_frame(int, str, int) -> opt(str).
error_frame(F, Msg, Width, Out) :-
    Cycle is 18 + marquee_frames,
    (   F >= error_cycles * Cycle -> Out = none
    ;   P is F rem Cycle,
        (   P < 18 -> wave_frame(P, Out)
        ;   repeat_str(" ", Width, Pad), string_concat(Pad, Msg, A), string_concat(A, "    ", All),
            string_length(All, Len), Start is truncate(float(P - 18) * marquee_speed) rem Len,
            window(All, Start, Width, Len, Out) ) ).
:- fn window(str, int, int, int) -> str.
window(S, Start, N, Len, Out) :-
    (   N =< 0 -> Out = ""
    ;   I is Start rem Len, char_at(S, I, C), Next is Start + 1, N1 is N - 1,
        window(S, Next, N1, Len, Rest), string_concat(C, Rest, Out) ).

% One tick of that animation for the current error; none once it's over or
% the error cleared (incl. a 429 whose back-off has run out).
:- fn error_tick(opt(error), opt(time), time, int, int) -> opt(str).   % error, next allowed, now, frame, width
error_tick(E, Until, Now, F, Width, Out) :-
    (   E == none -> Out = none
    ;   E = rate_limited(_), Until \== none, Until =< Now -> Out = none
    ;   marquee_text(E, Until, Now, M), error_frame(F, M, Width, Out) ).

% A new window started: the API's resets_at moved to a new future instant, or
% (when we were down and missed it) utilization fell a lot.
:- fn rollover(opt(float), float, opt(str), opt(str), time) -> bool.
rollover(LastU, U, LastR, R, Now, Out) :-
    parse_iso(R, D), reset_moved(LastR, R, Moved),
    (   LastU == none -> Out = false
    ;   LastU < 0.0 -> Out = false
    ;   D == none -> Out = false
    ;   D =< Now -> Out = false
    ;   LastR \== none, Moved == true -> Out = true
    ;   LastU > U + big_drop -> Out = true
    ;   Out = false ).

% ── Polling policy ─────────────────────────────────────────────────────────
:- fn animation_left(opt(time), time) -> float.   % the refresh animation runs at least min_animation: seconds still to go
animation_left(Start, Now, S) :- ( Start == none -> S = 0.0 ; S is max(0.0, min_animation - secs(Start, Now)) ).

:- fn backoff_error(opt(time), time) -> opt(error).   % a 429 back-off still running (e.g. from the last launch) as an error
backoff_error(Until, Now, E) :- ( Until \== none, Until > Now -> S is secs(Now, Until), E = rate_limited(S) ; E = none ).

:- fn should_poll(opt(time), opt(time), time) -> bool.   % next allowed, last success, now
should_poll(Until, Last, Now, Out) :-
    (   Until \== none, Until > Now -> Out = false
    ;   Last \== none, secs(Last, Now) < poll_interval / 2 -> Out = false   % don't burst on relaunch
    ;   Out = true ).

:- fn cooling_down(opt(time), time) -> bool.   % click-storm guard
cooling_down(Last, Now, Out) :-
    ( Last \== none, secs(Last, Now) < click_cooldown -> Out = true ; Out = false ).

:- choice click = [blocked, cooling, fetch].
% A manual refresh (click / "Refresh now"): wait out a 429 back-off, absorb a
% click storm with the acknowledgement wave, otherwise fetch.
:- fn click_effect(opt(time), opt(time), time) -> click.   % next allowed, last manual click, now
click_effect(Until, Last, Now, C) :-
    cooling_down(Last, Now, Cool),
    ( Until \== none, Until > Now -> C = blocked ; Cool == true -> C = cooling ; C = fetch ).

:- fn backoff_secs(int, opt(float)) -> float.   % nth consecutive 429; honours a longer Retry-After
backoff_secs(Count, Retry, S) :-
    E is min(backoff_base * 2.0 ** (Count - 1), backoff_cap),
    ( Retry == none -> S = E ; S is max(Retry, E) ).

% ── Alerts ───────────────────────────────────────────────────────────────────
% Each threshold alerts once per window. The fired set resets only on a real
% resets_at change — the API sometimes drops it mid-window. Gives the window
% key and fired set to store, and the thresholds to announce now.
:- fn alerts(float, opt(str), opt(str), list(int)) -> (opt(str), list(int), list(int)).   % utilization, resets_at, stored key, stored fired
alerts(U, R, Key0, Fired0, Key, Fired, Due) :-
    new_window(R, Key0, New), ( New == true -> Key = R, F0 = [] ; Key = Key0, F0 = Fired0 ),
    crossed(U, F0, Due), append(F0, Due, Fired).
:- fn new_window(opt(str), opt(str)) -> bool.
new_window(R, Key, B) :- reset_moved(Key, R, B).

% resets_at is recomputed from the server's clock on every response, so the
% same window comes back a second or so apart ("…22:09:59.63" then
% "…22:10:00.38"). Only a jump past reset_jitter is a different window.
:- fn reset_moved(opt(str), opt(str)) -> bool.   % stored, current
reset_moved(Old, New, B) :-
    parse_iso(Old, O), parse_iso(New, N),
    (   N == none -> B = false
    ;   O == none -> B = true
    ;   abs(secs(O, N)) > reset_jitter -> B = true
    ;   B = false ).

:- fn crossed(float, list(int)) -> list(int).   % thresholds to notify now
crossed(U, Fired, Out) :- crossed_from([80, 95], U, Fired, Out).
:- fn crossed_from(list(int), float, list(int)) -> list(int).
crossed_from([], _, _, []).
crossed_from([T|Ts], U, Fired, Out) :-
    crossed_from(Ts, U, Fired, Rest),
    ( U >= float(T), \+ member(T, Fired) -> Out = [T|Rest] ; Out = Rest ).

:- fn alert_title(int) -> str.
alert_title(T, S) :- format(string(S), "Claude usage at ~d%", [T]).
:- fn alert_body(int) -> str.
alert_body(80, "Slow down or risk capping before the window resets.").
alert_body(_, "About to cap — finish the current task and pause.").

% ── Dropdown text ────────────────────────────────────────────────────────────
% "[error · ]Last updated: X · next in Y"
:- fn status_line(opt(error), opt(time), opt(time), opt(time), time) -> str.
status_line(E, Last, Until, Next, Now, S) :-
    (   E == none -> Prefix = ""
    ;   E = rate_limited(_) -> Prefix = "rate-limited · "
    ;   error_symbol(E, Sym), format(string(Prefix), "~w · ", [Sym]) ),
    ( Last == none -> Seen = "never" ; relative_time(Last, Now, Seen) ),
    (   E \== none, E = rate_limited(_), Until \== none ->
        W is max(0, truncate(secs(Now, Until))), next_attempt(W, A), format(string(Tail), "next in ~w", [A])
    ;   Last == none -> Tail = "click to refresh"
    ;   Next \== none -> W is max(0, truncate(secs(Now, Next))),
        ( W =< 0 -> Tail = "next now…" ; W < 60 -> format(string(Tail), "next in ~ds", [W])
        ; M is W // 60, R is W rem 60, format(string(Tail), "next in ~dm ~ds", [M, R]) )
    ;   Tail = "—" ),
    format(string(S), "~wLast updated: ~w · ~w", [Prefix, Seen, Tail]).

:- fn credits_text(float, float, str) -> str.   % API sends cents
credits_text(Used, Limit, Cur, S) :- U is Used / 100.0, L is Limit / 100.0, format(string(S), "~2f / ~2f ~w", [U, L, Cur]).

:- fn percent(float) -> int.
percent(U, P) :- P is round(U).

% ── Releases ─────────────────────────────────────────────────────────────────
% The Windows app scans the release list (v0.3.0 shipped Windows-only and isn't
% "latest") for the newest published release that carries a Windows zip.
:- fn newest_windows(list(github_release)) -> opt(github_release).
newest_windows([], none).
newest_windows([R|Rs], Out) :-
    newest_windows(Rs, Best), usable(R, Ok),
    (   Ok == false -> Out = Best
    ;   Best == none -> Out = R
    ;   get(R, tag_name, T0), get(Best, tag_name, B0), or_else(T0, "", T), or_else(B0, "", B),
        is_newer_version(T, B, Newer), ( Newer == true -> Out = R ; Out = Best ) ).
:- fn usable(github_release) -> bool.
usable(R, Ok) :-
    get(R, draft, D), get(R, prerelease, P), get(R, tag_name, T), windows_asset(R, A),
    ( D \== true, P \== true, T \== none, A \== none -> Ok = true ; Ok = false ).
:- fn windows_asset(github_release) -> opt(github_asset).
windows_asset(R, A) :- get(R, assets, As0), or_else(As0, [], As), first_zip(As, A).
:- fn first_zip(list(github_asset)) -> opt(github_asset).
first_zip([], none).
first_zip([A|As], Out) :-
    get(A, name, N0), or_else(N0, "", N1), lowercase(N1, N),
    ( starts_with(N, "claude-limits-windows-"), ends_with(N, ".zip") -> Out = A ; first_zip(As, Out) ).

% ── Small parsers ────────────────────────────────────────────────────────────
:- fn is_newer_version(str, str) -> bool.   % "v0.3.1" vs "0.3.0"; missing parts count as 0
is_newer_version(Latest, Current, Out) :- version(Latest, L), version(Current, C), newer(L, C, Out).
:- fn version(str) -> list(int).
version(S, Parts) :- drop_prefix(S, "v", T), split(T, ".", Ss), ints(Ss, Parts).
:- fn ints(list(str)) -> list(int).
ints([], []).
ints([S|Ss], Out) :- ints(Ss, Rest), to_int(S, N), ( N == none -> Out = Rest ; Out = [N|Rest] ).
:- fn newer(list(int), list(int)) -> bool.
newer([], [], false).
newer(L, C, Out) :- head0(L, A, Lt), head0(C, B, Ct), ( A > B -> Out = true ; A < B -> Out = false ; newer(Lt, Ct, Out) ).
:- fn head0(list(int)) -> (int, list(int)).
head0([], 0, []).
head0([X|Xs], X, Xs).

:- fn token_from(opt(credentials), str) -> opt(str).   % parsed JSON (none if it wasn't), raw text
token_from(C, Text, T) :-
    (   C == none -> raw_token(Text, T)
    ;   get(C, claudeAiOauth, O), ( O \== none -> get(O, accessToken, A) ; A = none ), get(C, accessToken, B),
        ( A \== none, A \== "" -> T = A ; B \== none, B \== "" -> T = B ; raw_token(Text, T) ) ).

:- fn raw_token(str) -> opt(str).   % a bare "sk-…" token pasted instead of credentials JSON
raw_token(Text, Out) :-
    trim(Text, T),
    ( T \== "", \+ contains(T, " "), \+ contains(T, "\n"), starts_with(T, "sk-") -> Out = T ; Out = none ).

% Where to look, in order: the custom file/command, or (auto) the Keychain if
% the platform has one, then the known paths. Auto misses fall through; a custom
% step's error is shown. Nothing to try (or all missed) → token_not_found.
:- enum token_step = [keychain, file(path: str), shell(cmd: str)].
:- fn token_steps(token_source, str, str, list(str), bool) -> list(token_step).   % source, file, command, known paths, has Keychain
token_steps(Src, Path, Cmd, Known, Keychain, Steps) :-
    trim(Path, P), trim(Cmd, C), file_steps(Known, Fs),
    (   Src == file -> ( P == "" -> Steps = [] ; Steps = [file(Path)] )
    ;   Src == shell -> ( C == "" -> Steps = [] ; Steps = [shell(Cmd)] )
    ;   Keychain == true -> Steps = [keychain|Fs]
    ;   Steps = Fs ).

:- fn file_steps(list(str)) -> list(token_step).
file_steps([], []).
file_steps([P|Ps], [file(P)|Fs]) :- file_steps(Ps, Fs).

:- fn token_label(token_step, bool) -> str.   % for the log; bool = auto
token_label(keychain, _, "keychain (auto)").
token_label(file(P), Auto, S) :- ( Auto == true -> M = "auto" ; M = "custom" ), format(string(S), "file ~w (~w)", [P, M]).
token_label(shell(_), _, "shell command (custom)").

% Settings' hint under the token source. Win = the Windows app (no Keychain,
% PowerShell); P = the default credentials path to mention.
:- fn source_hint(token_source, bool, str) -> str.
source_hint(Src, Win, P, S) :-
    (   Src == file -> S = "Path to a Claude credentials JSON or a file containing just the access token."
    ;   Src == shell, Win == true ->
        S = "A PowerShell command that prints credentials JSON or a token to stdout. Useful when Claude runs in WSL (wsl cat ~/.claude/.credentials.json), Docker, or on a remote machine over SSH."
    ;   Src == shell -> S = "A shell command that prints credentials JSON or a token to stdout. Useful when Claude runs in Docker, on a remote machine over SSH, etc."
    ;   Win == true -> format(string(S), "Reads the credentials file Claude Code writes when you sign in (~w, or under CLAUDE_CONFIG_DIR when that's set).", [P])
    ;   format(string(S), "We check the macOS Keychain (where Claude Code stores credentials by default), then fall back to common file paths like ~w.", [P]) ).

% ── Menu-bar title ───────────────────────────────────────────────────────────
% The pieces in order, each only if its toggle is on (the countdown also needs
% an active window). No pieces at all → the apps show a lone "·".
:- enum part = [pct(value: str), spark(value: str), reset(value: str)].
:- fn title_parts(bool, bool, bool, str, str, opt(str)) -> list(part).
title_parts(ShowP, ShowW, ShowR, P, W, R, Parts) :-
    ( ShowP == true -> A = [pct(P)] ; A = [] ),
    ( ShowW == true -> B = [spark(W)] ; B = [] ),
    ( ShowR == true, R \== none -> C = [reset(R)] ; C = [] ),
    append(A, B, AB), append(AB, C, Parts).

% ── The dropdown ─────────────────────────────────────────────────────────────
% Both apps draw exactly these rows, in order. status/reset rows show live
% text the apps tick every second (status_line / reset_line).
:- choice menu_action = [open_settings, refresh, open_usage, quit].
:- enum row = [status, reset, separator, header(text: str), bar(label: str, utilization: float, value: str),
               pair(label: str, value: str), action(label: str, does: menu_action)].

:- fn menu_rows(opt(error), opt(usage_response)) -> list(row).
menu_rows(E, R, Rows) :-
    (   E \== none, E = token_not_found -> Top = [status, action("→ Open Settings", open_settings), separator]
    ;   Top = [status, separator] ),
    (   R == none -> Body = []
    ;   get(R, five_hour, F), ( F == none -> Reset = [] ; Reset = [reset] ),
        weekly_rows(R, W), ( W == [] -> Weekly = [] ; append([separator, header("Weekly limits")], W, Weekly) ),
        get(R, extra_usage, X), credits_rows(X, Credits),
        append(Reset, Weekly, B1), append(B1, Credits, Body) ),
    append(Top, Body, T1),
    append(T1, [separator, action("Refresh now", refresh), action("Open claude.ai/settings/usage", open_usage),
                action("Settings…", open_settings), separator, action("Quit claude-limits", quit)], Rows).

:- fn credits_rows(opt(extra_usage)) -> list(row).
credits_rows(X, Rows) :-
    (   X == none -> Rows = []
    ;   get(X, is_enabled, On),
        (   On == true ->
            get(X, used_credits, U0), get(X, monthly_limit, L0), get(X, currency, C0),
            or_else(U0, 0.0, U), or_else(L0, 0.0, L), or_else(C0, "USD", C), credits_text(U, L, C, T),
            Rows = [separator, pair("Pay-as-you-go credits", T)]
        ;   Rows = [] ) ).

% Weekly bars: the legacy seven_day* buckets, or the newer `limits` list when
% they're all null.
:- fn weekly_rows(usage_response) -> list(row).
weekly_rows(R, Rows) :-
    get(R, seven_day, A), get(R, seven_day_opus, B), get(R, seven_day_sonnet, C),
    get(R, seven_day_oauth_apps, D), get(R, seven_day_cowork, E), get(R, seven_day_omelette, F),
    bucket_rows(["Overall", "Opus", "Sonnet", "OAuth apps", "Cowork", "Claude Design"], [A, B, C, D, E, F], Legacy),
    (   Legacy \== [] -> Rows = Legacy
    ;   get(R, limits, Ls), or_else(Ls, [], L), limit_rows(L, Rows) ).

:- fn bucket_rows(list(str), list(opt(usage_bucket))) -> list(row).
bucket_rows([], [], []).
bucket_rows([L|Ls], [B|Bs], Rows) :-
    bucket_rows(Ls, Bs, Rest),
    ( B == none -> Rows = Rest ; get(B, utilization, U), bar_row(L, U, Row), Rows = [Row|Rest] ).

:- fn limit_rows(list(usage_limit)) -> list(row).
limit_rows([], []).
limit_rows([L|Ls], Rows) :-
    limit_rows(Ls, Rest), get(L, group, G), get(L, percent, P),
    (   G == "weekly", P \== none -> get(L, scope, S), scope_name(S, N), bar_row(N, P, Row), Rows = [Row|Rest]
    ;   Rows = Rest ).

:- fn scope_name(opt(limit_scope)) -> str.
scope_name(S, N) :-
    (   S == none -> N = "Overall"
    ;   get(S, model, M), ( M == none -> N = "Overall" ; get(M, display_name, D), or_else(D, "Overall", N) ) ).

:- fn filled_blocks(float, int) -> int.   % of a weekly bar's N blocks; nonzero usage lights at least one
filled_blocks(U, N, F) :- F0 is round(float(N) * max(0.0, min(1.0, U / 100.0))), ( U > 0.0, F0 =:= 0 -> F = 1 ; F = F0 ).

:- fn bar_row(str, float) -> row.
bar_row(Label, U, bar(Label, U, V)) :- percent(U, P), format(string(V), "~d%", [P]).

% ── Windows tray ─────────────────────────────────────────────────────────────
:- fn icon_level(float) -> int.   % 0 normal, 1 amber, 2 red
icon_level(U, L) :- ( U >= 95.0 -> L = 2 ; U >= 80.0 -> L = 1 ; L = 0 ).

:- fn tray_text(opt(int), bool, opt(str)) -> opt(str).   % number, error state, plain title; none → app icon
tray_text(N, Err, Plain, T) :- ( N \== none -> format(string(T), "~d", [N]) ; Err == true -> T = "!" ; Plain == "—" -> T = "–" ; T = none ).
:- fn tray_level(opt(int), float, bool) -> int.   % icon_level, or 3 (grey) for an error
tray_level(N, U, Err, L) :- ( N \== none -> icon_level(U, L) ; Err == true -> L = 3 ; L = 0 ).

:- fn tooltip(opt(float), opt(str), opt(error), time) -> str.   % hover text, ≤ 63 chars
tooltip(U, Iso, E, Now, S) :-
    (   U \== none ->
        P is round(U), format(string(S0), "claude-limits · ~d%", [P]),
        countdown(Iso, Now, R), ( R == none -> S1 = S0 ; format(string(S1), "~w · resets in ~w", [S0, R]) ),
        ( E == none -> S2 = S1 ; error_symbol(E, Sym), format(string(S2), "~w · ~w", [S1, Sym]) )
    ;   E \== none -> error_symbol(E, Sym), format(string(S2), "claude-limits · ~w", [Sym])
    ;   S2 = "claude-limits" ),
    string_length(S2, N), ( N > 63 -> prefix(S2, 62, H), string_concat(H, "…", S) ; S = S2 ).

% ── Settings ─────────────────────────────────────────────────────────────────
% The credentials dot when Settings opens: reuse recent state rather than spend
% a usage call, and never probe during a back-off, a refresh or a click storm.
:- choice dot = [connected, unverified, probe].
:- fn dot_on_open(bool, opt(time), bool, opt(time), opt(time), time) -> dot.   % have data, last success, refreshing, next allowed, last click, now
dot_on_open(Have, Last, Busy, Until, Click, Now, D) :-
    cooling_down(Click, Now, Cool),
    (   Have == true -> D = connected
    ;   Last \== none, secs(Last, Now) < poll_interval -> D = connected
    ;   Busy == true -> D = unverified
    ;   Until \== none, Until > Now -> D = unverified
    ;   Cool == true -> D = unverified
    ;   D = probe ).

% ── Settings copy ────────────────────────────────────────────────────────────
:- fn update_status(opt(str), opt(str), str) -> str.   % newer tag, GitHub error, our version
update_status(Latest, Err, Ver, S) :-
    (   Err \== none -> format(string(S), "Couldn't reach GitHub: ~w", [Err])
    ;   Latest \== none -> format(string(S), "Update ~w available — click “Update to ~w”.", [Latest, Latest])
    ;   format(string(S), "You're on the latest version (v~w).", [Ver]) ).
:- fn update_button(opt(str)) -> str.
update_button(L, S) :- ( L == none -> S = "Check for updates" ; format(string(S), "Update to ~w", [L]) ).
:- fn updating_status(str) -> str.
updating_status(V, S) :- format(string(S), "Updating to ~w… the app will relaunch when done.", [V]).
:- fn updating_notice(str, str) -> str.   % version, what vanishes meanwhile
updating_notice(V, W, S) :- format(string(S), "Installing ~w — the ~w will return in a few seconds.", [V, W]).
:- fn test_status(opt(float)) -> str.   % five_hour utilization from a test fetch
test_status(U, S) :- ( U == none -> S = "Connected, but no five_hour data." ; P is round(U), format(string(S), "OK — current session at ~d%", [P]) ).
:- fn wait_status(opt(time), time) -> opt(str).   % Test fetch during a 429 back-off (next allowed, now)
wait_status(Until, Now, S) :-
    (   Until \== none, Until > Now -> N is max(0, truncate(secs(Now, Until))), format(string(S), "Rate limited — wait ~ds before testing again.", [N])
    ;   S = none ).

% ── Command line ────────────────────────────────────────────────────────────
:- fn flag_value(list(str), str) -> opt(str).   % the argument after Flag (--fixture <file>), if any
flag_value([], _, none).
flag_value([A|As], F, V) :- ( A == F -> first(As, V) ; flag_value(As, F, V) ).
:- fn first(list(str)) -> opt(str).
first([], none).
first([X|_], X).

% ── Windows flyout placement (screen pixels) ─────────────────────────────────
% Above the pill (below it if there's no room), or centred on a tray click and
% lifted off the taskbar edge; then clamped to the work area. The window's
% shadow margin M may hang outside; G is the gap to the anchor.
:- fn flyout_origin(bool, int, int, int, int, int, int, int, int, int, int, int, int) -> (int, int).   % from pill, anchor LTRB, work area LTRB, W, H, M, G
flyout_origin(Pill, AL, AT, AR, AB, WL, WT, WR, WB, W, H, M, G, X, Y) :-
    CX is (AL + AR) // 2, CY is (AT + AB) // 2,
    (   Pill == true -> X0 is AR - W + M, Y1 is AT - H + M - G, ( Y1 + M < WT -> Y0 is AB - M + G ; Y0 = Y1 )
    ;   X0 is CX - W // 2, ( CY >= WB -> Y0 is WB - H + M - G ; CY =< WT -> Y0 is WT - M + G ; Y0 is CY - H + M ) ),
    X is max(WL - M + G, min(X0, WR - W + M - G)),
    Y is max(WT - M, min(Y0, WB - H + M)).
