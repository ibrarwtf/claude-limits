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

% A new window started: the API's resets_at moved to a new future instant, or
% (when we were down and missed it) utilization fell a lot.
:- fn rollover(opt(float), float, opt(str), opt(str), time) -> bool.
rollover(LastU, U, LastR, R, Now, Out) :-
    parse_iso(R, D),
    (   LastU == none -> Out = false
    ;   LastU < 0.0 -> Out = false
    ;   D == none -> Out = false
    ;   D =< Now -> Out = false
    ;   LastR \== none, LastR \== R -> Out = true
    ;   LastU > U + big_drop -> Out = true
    ;   Out = false ).

% ── Polling policy ───────────────────────────────────────────────────────────
:- fn should_poll(opt(time), opt(time), time) -> bool.   % next allowed, last success, now
should_poll(Until, Last, Now, Out) :-
    (   Until \== none, Until > Now -> Out = false
    ;   Last \== none, secs(Last, Now) < poll_interval / 2 -> Out = false   % don't burst on relaunch
    ;   Out = true ).

:- fn cooling_down(opt(time), time) -> bool.   % click-storm guard
cooling_down(Last, Now, Out) :-
    ( Last \== none, secs(Last, Now) < click_cooldown -> Out = true ; Out = false ).

:- fn backoff_secs(int, opt(float)) -> float.   % nth consecutive 429; honours a longer Retry-After
backoff_secs(Count, Retry, S) :-
    E is min(backoff_base * 2.0 ** (Count - 1), backoff_cap),
    ( Retry == none -> S = E ; S is max(Retry, E) ).

% ── Alerts ───────────────────────────────────────────────────────────────────
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

:- fn raw_token(str) -> opt(str).   % a bare "sk-…" token pasted instead of credentials JSON
raw_token(Text, Out) :-
    trim(Text, T),
    ( T \== "", \+ contains(T, " "), \+ contains(T, "\n"), starts_with(T, "sk-") -> Out = T ; Out = none ).

% ── Windows tray ─────────────────────────────────────────────────────────────
:- fn icon_level(float) -> int.   % 0 normal, 1 amber, 2 red
icon_level(U, L) :- ( U >= 95.0 -> L = 2 ; U >= 80.0 -> L = 1 ; L = 0 ).

:- fn tooltip(opt(float), opt(str), opt(error), time) -> str.   % hover text, ≤ 63 chars
tooltip(U, Iso, E, Now, S) :-
    (   U \== none ->
        P is round(U), format(string(S0), "claude-limits · ~d%", [P]),
        countdown(Iso, Now, R), ( R == none -> S1 = S0 ; format(string(S1), "~w · resets in ~w", [S0, R]) ),
        ( E == none -> S2 = S1 ; error_symbol(E, Sym), format(string(S2), "~w · ~w", [S1, Sym]) )
    ;   E \== none -> error_symbol(E, Sym), format(string(S2), "claude-limits · ~w", [Sym])
    ;   S2 = "claude-limits" ),
    string_length(S2, N), ( N > 63 -> prefix(S2, 62, H), string_concat(H, "…", S) ; S = S2 ).
