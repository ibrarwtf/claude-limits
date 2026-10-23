:- encoding(utf8).
% Runs spec/cases.json against core.pl directly — Prolog as the reference
% implementation. `swipl logic/oracle.pl` from the repo root; exits 1 on any
% mismatch. (Token-JSON and weekly-row cases need a JSON decoder, so they're
% checked by the app runners only.)
:- use_module(library(json)).
:- ensure_loaded(core).
:- initialization(main, main).

main :-
    set_stream(user_output, encoding(utf8)),
    open('spec/cases.json', read, In, [encoding(utf8)]), json_read_dict(In, D), close(In),
    parse_iso(D.now, Now),
    nb_setval(failed, 0), nb_setval(passed, 0),
    forall(member(C, D.timeRemaining),
           ( iso_in(C.resetsIn, Now, Iso), check(countdown, countdown(Iso, Now), C.expect) )),
    forall(member(C, D.nextAttempt), check(next_attempt, next_attempt(C.secs), C.expect)),
    forall(member(C, D.relativeTime), ( T is Now - C.ago, check(relative_time, relative_time(T, Now), C.expect) )),
    forall(member(C, D.isNewerVersion),
           check(is_newer_version, is_newer_version(C.latest, C.current), C.expect)),
    forall(member(C, D.sparkline), ( samples(C.samples, Now, S), check(sparkline, sparkline(S, C.width), C.expect) )),
    forall(member(C, D.resetLine),
           ( iso_in(C.resetsIn, Now, Iso), samples(C.samples, Now, S), U is float(C.utilization),
             check(reset_line, reset_line(U, Iso, S, Now), C.expect) )),
    forall(member(C, D.rollover), ( replay(C.steps, Now, none, none, 0, N), check(rollover, count(C.name), N, C.expectCount) )),
    nb_getval(passed, P), nb_getval(failed, F),
    format("prolog spec: ~d passed, ~d failed~n", [P, F]),
    ( F =:= 0 -> halt(0) ; halt(1) ).

iso_in(null, _, none) :- !.
iso_in(Secs, Now, Iso) :- T is Now + Secs, stamp_date_time(T, DT, 'UTC'), format_time(string(Iso), '%FT%TZ', DT).

samples(Pairs, Now, S) :- findall(sample(T, U), ( member([Ago, U0], Pairs), T is Now - Ago, U is float(U0) ), S).

% History.append: a rollover clears the history before the new sample.
replay([], _, _, _, N, N).
replay([St|Rest], Now, LastU, LastR, N0, N) :-
    T is Now + St.t, U is float(St.u), iso_in(St.r, Now, R),
    once(rollover(LastU, U, LastR, R, T, Roll)),
    ( Roll == true -> N1 = 1 ; N1 is min(60, N0 + 1) ),
    replay(Rest, Now, U, R, N1, N).

check(Name, Goal, Want) :- Goal =.. L, append(L, [Got], L2), G =.. L2, once(G), check(Name, Goal, Got, Want).
check(Name, Goal, Got, Want) :-
    norm(Got, G), norm(Want, W),
    (   G == W -> nb_getval(passed, P), P1 is P + 1, nb_setval(passed, P1)
    ;   nb_getval(failed, F), F1 is F + 1, nb_setval(failed, F1),
        format("FAIL ~w ~q~n  got:  ~q~n  want: ~q~n", [Name, Goal, G, W]) ).

norm(none, null) :- !.
norm(X, S) :- atom(X), \+ X == null, \+ X == true, \+ X == false, !, atom_string(X, S).
norm(X, X).
