:- encoding(utf8).
% The spec, run three ways. `swipl logic/oracle.pl` from the repo root:
%   1. evaluates every case in spec/cases.json with core.pl itself (Prolog is
%      the reference implementation) and fails on any mismatch;
%   2. writes macos/tests/main.swift and windows/tests/Spec.cs — the same
%      cases as literal checks against each app's generated Logic code.
:- use_module(library(http/json)).  % library(json) in SWI 10+; this path works on both
:- ensure_loaded(core).
:- initialization(main, main).

main :-
    set_stream(user_output, encoding(utf8)),
    open('spec/cases.json', read, In, [encoding(utf8)]), json_read_dict(In, D), close(In),
    parse_iso(D.now, Now),
    findall(c(L, E, Got, Want), case(D, Now, L, E, Got, Want), Cs),
    include([c(_, _, G, W)]>>same(G, W), Cs, Ok),
    forall(( member(c(L, E, G, W), Cs), \+ same(G, W) ),
           format("FAIL ~w ~q~n  got:  ~q~n  want: ~q~n", [L, E, G, W])),
    length(Cs, N), length(Ok, P), F is N - P,
    format("prolog spec: ~d passed, ~d failed~n", [P, F]),
    emit(swift, 'macos/tests/main.swift', Now, Cs), emit(csharp, 'windows/tests/Spec.cs', Now, Cs),
    ( F =:= 0 -> halt(0) ; halt(1) ).

%% case(+Spec, +Now, -Label, -Expr, -Got, -Want): Expr is the call the app
%% runners make; Got is what core.pl answers.

case(D, Now, countdown, call(countdown, [Iso, at(0)]), Got, W) :-
    member(C, D.timeRemaining), iso_in(C.resetsIn, Now, Iso), W = C.expect, once(countdown(Iso, Now, Got)).
case(D, _, status_error, msg(call(status_error, [St, R, B])), Got, W) :-
    member(C, D.statusError), St = C.status, B = C.body, W = C.expect,
    ( C.retryAfter == null -> R = none ; R is float(C.retryAfter) ),
    once(status_error(St, R, B, E)), ( E == none -> Got = none ; once(friendly_message(E, Got)) ).
case(D, _, newest_windows, newest(J), Got, W) :-
    member(C, D.newestWindows), Rs = C.releases, W = C.expect, with_output_to(string(J), jw(Rs)),
    once(newest_windows(Rs, R)), ( R == none -> Got = none ; Got = R.tag_name ).
case(D, _, extract_token, token(T), Got, W) :-
    member(C, D.extractToken), T = C.text, W = C.expect,
    ( catch(atom_json_dict(T, J, []), _, fail), is_dict(J) -> true ; J = none ), once(token_from(J, T, Got)).
case(D, Now, sparkline, call(sparkline, [samples(Ps), Wd]), Got, W) :-
    member(C, D.sparkline), Ps = C.samples, Wd = C.width, W = C.expect, samples(Ps, Now, S), once(sparkline(S, Wd, Got)).
case(D, Now, reset_line, call(reset_line, [U, Iso, samples(Ps), at(0)]), Got, W) :-
    member(C, D.resetLine), U is float(C.utilization), iso_in(C.resetsIn, Now, Iso), Ps = C.samples, W = C.expect,
    samples(Ps, Now, S), once(reset_line(U, Iso, S, Now, Got)).
case(D, _, weekly_rows, bars(J), Got, W) :-
    member(C, D.weeklyRows), R = C.response, W = C.expect, with_output_to(string(J), jw(R)),
    once(weekly_rows(R, Rows)),
    findall(S, ( member(bar(L, U, _), Rows), P is round(U), format(string(S), "~w=~d", [L, P]) ), Ss),
    atomic_list_concat(Ss, ', ', A), atom_string(A, Got).
case(D, Now, rollover, replay(Steps), Got, W) :-
    member(C, D.rollover), W = C.expectCount,
    findall(s(T, U, R), ( member(St, C.steps), T is float(St.t), U is float(St.u), iso_in(St.r, Now, R) ), Steps),
    replay(Steps, Now, none, none, 0, Got).

% `calls`: any fn, its JSON args typed by its signature (time = seconds from now).
case(D, Now, F, out(Out, call(F, Ls)), Got, W) :-
    member(C, D.calls), atom_string(F, C.fn), sig(F, Ins, Out), W = C.expect,
    maplist(arg_in(Now), Ins, C.args, Vs, Ls), length(Out, NO), length(Os, NO),
    append(Vs, Os, As), G =.. [F|As], once(G), got(Out, Os, Got).

arg_in(Now, time, Off, T, at(Off)) :- !, T is Now + Off.
arg_in(_, opt(_), null, none, none) :- !.
arg_in(Now, opt(T), V, P, L) :- !, arg_in(Now, T, V, P, L).
arg_in(Now, list(T), Vs, Ps, list(Ls)) :- !, maplist(arg_in(Now, T), Vs, Ps, Ls).
arg_in(_, float, V, F, F) :- !, F is float(V).
arg_in(_, T, V, A, choice(T, A)) :- string(V), T \== str, !, atom_string(A, V).
arg_in(_, _, V, V, V).

got([opt(error)], [E], G) :- !, ( E == none -> G = none ; once(friendly_message(E, G)) ).
got([C], [V], G) :- choice(C, _), !, cname(swift, V, N), atom_string(N, G).
got([_, _], [A, B], G) :- !, format(string(G), "(~w, ~w)", [A, B]).
got([_], [V], V).

iso_in(null, _, none) :- !.
iso_in(Secs, Now, Iso) :- T is Now + Secs, stamp_date_time(T, DT, 'UTC'), format_time(string(Iso), '%FT%TZ', DT).

samples(Pairs, Now, S) :- findall(sample(T, U), ( member([Ago, U0], Pairs), T is Now - Ago, U is float(U0) ), S).

% UsageHistory.append: a rollover clears the history before the new sample.
replay([], _, _, _, N, N).
replay([s(T0, U, R)|Rest], Now, LastU, LastR, N0, N) :-
    T is Now + T0, once(rollover(LastU, U, LastR, R, T, Roll)),
    ( Roll == true -> N1 = 1 ; N1 is min(60, N0 + 1) ),
    replay(Rest, Now, U, R, N1, N).

same(A, B) :- norm(A, X), norm(B, X).

norm(none, null) :- !.
norm(X, S) :- atom(X), \+ memberchk(X, [null, true, false]), !, atom_string(X, S).
norm(N, S) :- integer(N), !, number_string(N, S).
norm(X, X).

% Compact JSON, byte-identical across SWI-Prolog versions (json_write varies).
jw(D) :- is_dict(D), !, dict_pairs(D, _, Ps), write("{"), foldl([K-V, Sep, ","]>>(write(Sep), jw(K), write(":"), jw(V)), Ps, "", _), write("}").
jw(L) :- is_list(L), !, write("["), foldl([V, Sep, ","]>>(write(Sep), jw(V)), L, "", _), write("]").
jw(X) :- ( number(X) ; memberchk(X, [null, true, false]) ), !, write(X).
jw(X) :- format("\"~w\"", [X]).

%% Emitting the app runners

emit(Lang, File, Now, Cs) :-
    with_output_to(string(Text), ( prelude(Lang, Now), forall(member(c(L, E, _, W), Cs), check_line(Lang, L, E, W)), postlude(Lang) )),
    setup_call_cleanup(open(File, write, Out, [encoding(utf8)]), write(Out, Text), close(Out)).

check_line(swift, L, E, W) :- format("check(\"~w\", ", [L]), x(swift, E), write(", "), want(swift, W), format(")~n").
check_line(csharp, L, E, W) :- format("            Check(\"~w\", ", [L]), x(csharp, E), write(", "), want(csharp, W), format(");~n").

want(T, W) :- norm(W, N), ( N == null -> x(T, none) ; N == true -> x(T, "true") ; N == false -> x(T, "false") ; x(T, N) ).

x(T, call(F, As)) :- !, atomic_list_concat(Ps, '_', F), maplist(cap, Ps, Cs0), atomic_list_concat(Cs0, P),
    ( T == swift -> sub_atom(P, 0, 1, _, H), downcase_atom(H, Lo), sub_atom(P, 1, _, 0, R), atom_concat(Lo, R, N) ; N = P ),
    format("~w(", [N]), xs(T, As), write(")").
x(swift, bool(E)) :- !, write("String("), x(swift, E), write(")").
x(csharp, bool(E)) :- !, x(csharp, E), write(".ToString().ToLowerInvariant()").
x(swift, msg(E)) :- !, x(swift, E), write(".map(friendlyMessage)").
x(csharp, msg(E)) :- !, write("Msg("), x(csharp, E), write(")").
x(swift, token(S)) :- !, write("extractTokenFromText("), x(swift, S), write(")").
x(csharp, token(S)) :- !, write("Token.ExtractTokenFromText("), x(csharp, S), write(")").
x(T, newest(J)) :- !, ( T == swift -> write("newestTag(") ; write("NewestTag(") ), x(T, J), write(")").
x(T, bars(J)) :- !, ( T == swift -> write("bars(") ; write("Bars(") ), x(T, J), write(")").
x(swift, replay(Ss)) :- !, write("replay(["), xs3(swift, Ss), write("])").
x(csharp, replay(Ss)) :- !, write("Replay(new[] { "), xs3(csharp, Ss), write(" })").
x(T, out([bool], E)) :- !, x(T, bool(E)).
x(T, out([opt(error)], E)) :- !, x(T, msg(E)).
x(swift, out([O], E)) :- O \= str, O \= opt(str), !, write("String(describing: "), x(swift, E), write(")").
x(swift, out([_, _], E)) :- !, write("String(describing: "), x(swift, E), write(")").
x(csharp, out([C], E)) :- choice(C, _), !, write("Case("), x(csharp, E), write(")").
x(csharp, out(Os, E)) :- Os \= [str], Os \= [opt(str)], !, x(csharp, E), write(".ToString()").
x(T, out(_, E)) :- !, x(T, E).
x(swift, list(Ls)) :- !, write("["), xs(swift, Ls), write("]").
x(csharp, list(Ls)) :- !, write("new[] { "), xs(csharp, Ls), write(" }").
x(T, choice(C, A)) :- !, cname(csharp, C, CN), cname(T, A, AN), format("~w.~w", [CN, AN]).
x(_, B) :- memberchk(B, [true, false]), !, write(B).
x(swift, at(Off)) :- !, format("now.addingTimeInterval(~w)", [Off]).
x(csharp, at(Off)) :- !, format("now.AddSeconds(~w)", [Off]).
x(swift, samples(Ps)) :- !, write("["), xsamples(swift, Ps), write("]").
x(csharp, samples(Ps)) :- !, write("new List<HistorySample> { "), xsamples(csharp, Ps), write(" }").
x(swift, none) :- !, write(nil).
x(csharp, none) :- !, write(null).
x(_, S) :- string(S), !, string_codes(S, Cs), write("\""), forall(member(C, Cs), esc(C)), write("\"").
x(_, N) :- number(N), !, write(N).

xs(_, []).
xs(T, [A]) :- !, x(T, A).
xs(T, [A|As]) :- x(T, A), write(", "), xs(T, As).
xsamples(T, Ps) :- foldl([[Ago, U], Sep, ", "]>>(write(Sep), ( T == swift -> write("s(") ; write("S(") ), format("~w, ~w)", [Ago, U])), Ps, "", _).
xs3(T, Ss) :- foldl([s(Ti, U, R), Sep, ", "]>>(write(Sep), format("(~w, ~w, ", [Ti, U]), x(T, R), write(")")), Ss, "", _).

esc(0'\\) :- !, write("\\\\").
esc(0'") :- !, write("\\\"").
esc(0'\n) :- !, write("\\n").
esc(C) :- put_char(C).

cap(A, B) :- atom_chars(A, [C|Cs]), upcase_atom(C, U), atom_chars(U, [UC]), atom_chars(B, [UC|Cs]).
cname(T, A, N) :- atomic_list_concat([P|Ps], '_', A), maplist(cap, Ps, Cs), atomic_list_concat([P|Cs], N0), ( T == swift -> N = N0 ; cap(N0, N) ).

prelude(swift, Now) :- format("// Generated by logic/oracle.pl from spec/cases.json — do not edit.
//   swiftc -o build/spec-macos macos/core/*.swift macos/tests/main.swift && build/spec-macos
import Foundation

let now = Date(timeIntervalSince1970: ~w)
Clock.pinned = now
UsageHistory.persist = false
var passed = 0, failed = 0
func check(_ name: String, _ got: String?, _ want: String?) {
    if got == want { passed += 1; return }
    failed += 1
    print(\"FAIL \\(name)\\n  got:  \\(got ?? \"nil\")\\n  want: \\(want ?? \"nil\")\")
}
func s(_ ago: Double, _ u: Double) -> HistorySample { HistorySample(timestamp: now.addingTimeInterval(-ago), utilization: u) }
func bars(_ json: String) -> String {
    let r = try! JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))
    return weeklyRows(r).compactMap { row -> String? in
        if case .bar(let l, let u, _) = row { return \"\\(l)=\\(percent(u))\" }
        return nil
    }.joined(separator: \", \")
}
func newestTag(_ json: String) -> String? {
    newestWindows(try! JSONDecoder().decode([GitHubRelease].self, from: Data(json.utf8)))?.tagName
}
func replay(_ steps: [(Double, Double, String?)]) -> String {
    UsageHistory.shared.replaceSamples([])
    for (t, u, r) in steps {
        Clock.pinned = now.addingTimeInterval(t)
        UsageHistory.shared.append(utilization: u, resetsAt: r)
    }
    Clock.pinned = now
    return String(UsageHistory.shared.samples.count)
}

", [Now]).
prelude(csharp, Now) :- format("// Generated by logic/oracle.pl from spec/cases.json — do not edit.
using System;
using System.Collections.Generic;
using System.Linq;
using static ClaudeLimits.Logic;

namespace ClaudeLimits.Spec
{
    static class Program
    {
        static int passed, failed;
        static readonly DateTime now = Format.FromUnix(~w);
        static void Check(string name, string got, string want)
        {
            if (got == want) { passed++; return; }
            failed++;
            Console.WriteLine($\"FAIL {name}\\n  got:  {got ?? \"null\"}\\n  want: {want ?? \"null\"}\");
        }
        static string Msg(AppError e) => e == null ? null : FriendlyMessage(e);
        static string Case(Enum c) { var s = c.ToString(); return char.ToLowerInvariant(s[0]) + s.Substring(1); }
        static HistorySample S(double ago, double u) => new HistorySample { TimestampUnix = Format.ToUnix(now.AddSeconds(-ago)), Utilization = u };
        static string Bars(string json) =>
            string.Join(\", \", WeeklyRows(Json.Parse<UsageResponse>(json)).Where(r => r.Kind == RowKind.Bar).Select(r => $\"{r.Label}={Percent(r.Utilization)}\"));
        static string NewestTag(string json) => NewestWindows(Json.Parse<List<GitHubRelease>>(json))?.TagName;
        static string Replay((double t, double u, string r)[] steps)
        {
            UsageHistory.Shared.ReplaceSamples(new HistorySample[0]);
            foreach (var (t, u, r) in steps) { Clock.Pinned = now.AddSeconds(t); UsageHistory.Shared.Append(u, r); }
            Clock.Pinned = now;
            return UsageHistory.Shared.Samples.Count.ToString();
        }

        static int Main()
        {
            Clock.Pinned = now;
            UsageHistory.Persist = false;
            Settings.InMemory = true;
", [Now]).

postlude(swift) :- format("~nprint(\"macos spec: \\(passed) passed, \\(failed) failed\")~nexit(failed == 0 ? 0 : 1)~n").
postlude(csharp) :- format("            Console.WriteLine($\"windows spec: {passed} passed, {failed} failed\");~n            return failed == 0 ? 0 : 1;~n        }~n    }~n}~n").
