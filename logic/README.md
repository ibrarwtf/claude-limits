# logic/ — the Prolog core

Everything the macOS and Windows apps *decide* lives here, written once in
Prolog. Everything they *do* (draw, talk to the network, read files, set
timers) stays native.

```
                     logic/core.pl  ← the one source of truth
                    (facts + rules + type declarations)
                               │
          ┌────────────────────┼─────────────────────────┐
          ▼                    ▼                         ▼
   swipl logic/plc.pl   swipl logic/oracle.pl      (load it in swipl
   (the compiler)       (the spec, three ways)      and ask it things)
          │                    │
   ┌──────┴──────┐      ┌──────┴───────────────┐
   ▼             ▼      ▼                      ▼
 macos/core/  windows/  Prolog answers   macos/tests/main.swift
 Logic.swift  core/     spec/cases.json  windows/tests/Spec.cs
              Logic.cs  itself           (generated literal checks)
```

Generated files are committed (building the apps never needs Prolog). CI
regenerates them and fails if anything differs.

## Files

| File | What it is |
|---|---|
| `core.pl` | The logic: error copy, constants, settings table, API/JSON models, countdowns, burn rate, reset line, sparkline, animation frames and timing, rollover, polling/back-off/click policy, once-per-window alerts, the dropdown's rows, the tray glyph, Settings copy, update checks, token parsing and source order, command-line flags, Windows flyout placement. |
| `lang.pl` | Makes `core.pl` runnable as plain Prolog: the declaration operators and Prolog twins of every builtin (`parse_iso`, `clock`, `pad2`, `get`, …). |
| `plc.pl` | The compiler: reads `core.pl` as data, builds a typed IR, emits Swift and C#. |
| `oracle.pl` | Runs `spec/cases.json` against `core.pl`, then writes both apps' test suites. |

## Prolog in one screen

```prolog
status_error(401, _, _, auth_failed).           % a FACT: this is true
icon_level(U, L) :- ( U >= 95.0 -> L = 2 ; …).  % a RULE: true IF the body is
?- status_error(S, none, "", auth_failed).      % a QUERY, run backwards
S = 401.
```

Facts are tables, rules are "true if", and a query can run in any direction —
Prolog searches for every way to prove it (backtracking).

## The subset `core.pl` uses

Ordinary Prolog, restricted so every function compiles to straight-line code:

```prolog
:- fn countdown(opt(str), time) -> opt(str).    % signature: inputs -> output(s)
countdown(Iso, Now, Out) :-                     % inputs first, output last
    parse_iso(Iso, D),                          % builtin call      → let d = parseISO(iso)
    (   D == none -> Out = none                 % if-then-else      → if d == nil { return nil }
    ;   Total is truncate(secs(Now, D)),        % arithmetic        → let total = Int(d!.timeIntervalSince(now))
        ...
```

- **Clauses are tried in order and the first whose head matches wins**, so a
  table like `error_symbol/2` becomes an if-chain over the enum cases.
- **Bodies never fail** — they're bindings ending in an if-then-else tree.
- **Testing an optional narrows it**: after `D == none -> … ; …`, the else
  branch may use `D` as a plain value.
- Types: `int float str bool time`, `opt(T)`, `list(T)`, tuples (`-> (A, B)`),
  plus declared `enum`s, `choice`s, `record`s and `json` models.

### Declarations

| Declaration | Becomes |
|---|---|
| `:- fn name(Ts) -> T.` | a function in both apps |
| `:- enum error = [auth_failed, http_error(code: int, detail: str), …].` | Swift enum with associated values / C# class + `Kind` enum + factories |
| `:- choice menu_action = [refresh, quit, …].` | plain `enum` |
| `:- json usage_bucket = [utilization: float, resets_at: opt(str)].` | Codable struct / DataContract class |
| `:- setting show_wave: bool = hide(hide_wave).` | UserDefaults property / settings.json property |
| `:- const poll_interval = 180.0.` | a constant (also usable in Prolog arithmetic) |
| `:- record sample(t: time, u: float).` + `:- native …` | maps to an existing app type |

## Adding or changing behaviour

1. Edit `core.pl` (and `spec/cases.json` if it's covered there).
2. `swipl logic/plc.pl && swipl logic/oracle.pl` — regenerates `Logic.*` and
   the test suites, and checks the spec in Prolog.
3. Call the generated function from the app (`camelCase` in Swift,
   `PascalCase` in C# via `using static ClaudeLimits.Logic;`).
4. Build/test one app locally; push and CI covers the other.

If the compiler rejects something it says which goal, value or condition it
doesn't support — rewrite it in the subset rather than special-casing.

## Trying it

```
$ swipl logic/core.pl
?- countdown("2030-01-15T14:30:00Z", 1894708800.0, S).
S = "2:30".
?- status_error(S, none, "", rate_limited(none)).   % which status means "rate limited"?
S = 429.
?- error_symbol(E, "sign in").
E = token_not_found ;
E = auth_failed ;
ERROR: … not sufficiently instantiated   % the http_error rule only runs forwards
```

Facts run in any direction; a rule only runs in the directions its body
supports (`format` can't invent the number in "HTTP ~d"). The compiler's
signatures fix each function's direction, so the apps never hit this.
