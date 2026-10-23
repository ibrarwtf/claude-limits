:- encoding(utf8).
% plc — compiles logic/core.pl to macos/core/Logic.swift and windows/core/Logic.cs.
%
%   swipl logic/plc.pl            (from the repo root)
%
% core.pl is ordinary Prolog restricted to a deterministic subset: each fn is
% a list of clauses tried in order, heads are patterns, bodies are a sequence
% of bindings ending in an if-then-else tree. That subset maps onto both
% languages statement-for-statement: clause → `if <head matches>`, `X is E` →
% `let x = e`, `(C -> A ; B)` → if/else, outputs → `return`.
%
% Pipeline: read clauses (variables become '$v'(Name)) → IR (target-neutral
% statements/expressions, typed by unification) → text via emit//2 per target.
:- ensure_loaded(lang).
:- initialization(main, main).
:- dynamic((sig/3, (enum)/2, (record)/2, (native)/2, (const)/2, cl/3, (setting)/3, (choice)/2, (json)/2)).

main :-
    load('logic/core.pl'),
    forall(member(T-F, [swift-'macos/core/Logic.swift', csharp-'windows/core/Logic.cs']),
           ( file_text(T, Text), setup_call_cleanup(open(F, write, Out, [encoding(utf8)]), write(Out, Text), close(Out)) )).

%% ── Loading ─────────────────────────────────────────────────────────────────

load(File) :-
    setup_call_cleanup(open(File, read, In, [encoding(utf8)]), read_all(In), close(In)).
read_all(In) :-
    read_term(In, T, [variable_names(Bs)]),
    (   T == end_of_file -> true
    ;   maplist([N=V]>>(V = '$v'(N)), Bs), term_variables(T, Vs), maplist(=('$v'('_')), Vs),
        store(T), read_all(In) ).

store((:- fn Head -> Ret)) :- !, Head =.. [N|In], comma_list(Ret, Out), assertz(sig(N, In, Out)).
store((:- enum N = Cases)) :- !, assertz(enum(N, Cases)).
store((:- record R)) :- !, R =.. [N|Fs], assertz(record(N, Fs)).
store((:- native T = N)) :- !, assertz(native(T, N)).
store((:- const N = V)) :- !, assertz(const(N, V)).
store((:- choice N = Cs)) :- !, assertz(choice(N, Cs)).
store((:- json N = Fs)) :- !, assertz(json(N, Fs)).
store((:- setting N: T = K)) :- !, assertz(setting(N, T, K)).
store((:- setting N: T)) :- !, assertz(setting(N, T, key(N))).
store((:- _)) :- !.
store((H :- B)) :- !, functor(H, N, A), assertz(cl(N/A, H, B)).
store(H) :- functor(H, N, A), assertz(cl(N/A, H, true)).

%% ── Names ───────────────────────────────────────────────────────────────────

camel(Snake, Camel) :-
    atomic_list_concat([F|Rest], '_', Snake), maplist(cap, Rest, Caps), atomic_list_concat([F|Caps], Camel).
pascal(Snake, P) :- camel(Snake, C), cap(C, P).
cap(A, B) :- atom_chars(A, [C|Cs]), upcase_atom(C, U), atom_chars(U, [UC]), atom_chars(B, [UC|Cs]).
uncap(A, B) :- atom_chars(A, [C|Cs]), downcase_atom(C, L), atom_chars(L, [LC]), atom_chars(B, [LC|Cs]).

% Prolog variable → local name; never shadows a fn or a keyword.
local(V, L) :- uncap(V, L0), ( ( sig(F, _, _), camel(F, L0) ; memberchk(L0, [in, is, as, var, let, default, case, out, ref]) ) -> atom_concat(L0, '_', L) ; L = L0 ).
fname(swift, N, F) :- camel(N, F).
fname(csharp, N, F) :- pascal(N, F).

%% ── Types ───────────────────────────────────────────────────────────────────

ty(_, T, _) :- var(T), !, throw(error(untyped_expression, _)).
ty(swift, int, 'Int').      ty(csharp, int, int).
ty(swift, float, 'Double'). ty(csharp, float, double).
ty(swift, str, 'String').   ty(csharp, str, string).
ty(swift, bool, 'Bool').    ty(csharp, bool, bool).
ty(swift, time, 'Date').    ty(csharp, time, 'DateTime').
ty(T, opt(X), S) :- ty(T, X, XS), ( T == csharp, \+ value_type(X) -> S = XS ; format(atom(S), '~w?', [XS]) ).
ty(swift, list(X), S) :- ty(swift, X, XS), format(atom(S), '[~w]', [XS]).
ty(csharp, list(X), S) :- ty(csharp, X, XS), format(atom(S), 'IReadOnlyList<~w>', [XS]).
ty(T, tuple(Ts), S) :- maplist(ty(T), Ts, Ss), atomic_list_concat(Ss, ', ', J), format(atom(S), '(~w)', [J]).
ty(_, N, S) :- atom(N), native(N, Nat), !, ( atom(Nat) -> S = Nat ; functor(Nat, S, _) ).
ty(_, N, S) :- atom(N), ( enum(N, _) ; choice(N, _) ; json(N, _) ), !, pascal(N, S).
value_type(X) :- memberchk(X, [int, float, bool, time]) ; atom(X), choice(X, _).

ret_type([T], T) :- !.
ret_type(Ts, tuple(Ts)).

%% ── Compiling a fn ──────────────────────────────────────────────────────────

fn_ir(N, fn(N, Params, Ret, Body)) :-
    sig(N, InTs, OutTs), length(InTs, NI), length(OutTs, NO), A is NI + NO,
    findall(H-B, cl(N/A, H, B), Cls),
    numlist(1, NI, Is), maplist(param_name(Cls), Is, InTs, Params0), dedup(Params0, Params),
    ret_type(OutTs, Ret),
    clauses_ir(Cls, NI, Params, OutTs, Body).

param_name(Cls, I, T, P-T) :-
    (   member(H-_, Cls), arg(I, H, '$v'(V)), V \== '_' -> local(V, P)
    ;   atom(T), \+ memberchk(T, [int, float, str, bool, time]) -> P = T
    ;   format(atom(P), 'a~d', [I]) ).
dedup(Ps, Out) :- dedup(Ps, [], Out).
dedup([], _, []).
dedup([P-T|Ps], Seen, [Q-T|Out]) :- ( memberchk(P, Seen) -> atom_concat(P, '2', Q) ; Q = P ), dedup(Ps, [Q|Seen], Out).

clauses_ir([], _, _, _, [fail]).
clauses_ir([H-B|Cls], NI, Params, OutTs, Stmts) :-
    H =.. [_|Args], length(InArgs, NI), append(InArgs, OutArgs, Args),
    foldl(head_pat, InArgs, Params, []-[], Env-Guards0), reverse(Guards0, Guards),
    goals(B, Gs), body(Gs, Env, ret(OutArgs, OutTs), Body, _),
    (   Guards == [] -> Stmts = Body
    ;   Stmts = [if(Guards, Body, [])|Rest], clauses_ir(Cls, NI, Params, OutTs, Rest) ).

% head_pat(+Pattern, +Param-Type, Env0-Guards0, Env-Guards)
head_pat(P, Name-T, E0-G0, E-G) :- pat(P, var(Name), T, E0-G0, E-G).

pat('$v'('_'), _, _, S, S) :- !.
pat('$v'(V), X, T, E-G, [V-(X:T)|E]-G) :- !.
pat(none, X, opt(_), E-G, E-[cond(op('==', X, nil))|G]) :- !.
pat([], X, list(_), E-G, E-[cond(empty(X))|G]) :- !.
pat([H|Tl], X, list(ET), E0-G0, S) :- !,
    pat(H, idx(X, i(0)), ET, E0-[cond(not(empty(X)))|G0], S1), pat(Tl, drop1(X), list(ET), S1, S).
pat(C, X, T, E0-G0, E-[case(X, T, Name, Binds)|G0]) :-
    enum(T, Cases), C =.. [Name|Ps], case_fields(Cases, Name, Fs), !,
    foldl(case_bind(X, T, Name), Ps, Fs, E0-[], E-Binds).
pat(C, X, T, S0, S) :- record(T, Fs), C =.. [T|Ps], !, foldl(rec_bind(X, T), Ps, Fs, S0, S).
pat(L, X, T, E-G, E-[cond(op('==', X, Lit))|G]) :- lit(L, Lit, T).

case_fields(Cases, Name, Fs) :- member(C, Cases), C =.. [Name|Fs], !.
case_bind(_, _, _, '$v'('_'), _, S, S) :- !.
case_bind(X, T, Case, '$v'(V), F:FT, E-B, [V-(efield(X, T, Case, F, L):FT)|E]-[F-L|B]) :- local(V, L).
rec_bind(_, _, '$v'('_'), _, S, S) :- !.
rec_bind(X, R, '$v'(V), F:FT, E-G, [V-(field(X, R, F):FT)|E]-G).

lit(S, s(S), str) :- string(S), !.
lit(N, i(N), int) :- integer(N), !.
lit(N, f(N), float) :- float(N), !.
lit(true, b(true), bool) :- !.
lit(false, b(false), bool) :- !.

goals(true, []) :- !.
goals((A, B), Gs) :- !, goals(A, Ga), goals(B, Gb), append(Ga, Gb, Gs).
goals(G, [G]).

%% Body. body(+Goals, +Env0, +Mode, -Stmts, -Env). Mode is ret(OutArgs, OutTypes)
%% (tail of a fn) or asg(Targets) (an if-then-else mid-body binding Targets).

body([], Env, ret(Outs, Ts), [ret(E)], Env) :- !, maplist(out_val(Env), Outs, Ts, Es), ( Es = [E] -> true ; E = tuple(Es) ).
body([], Env, asg(_), [], Env) :- !.
body([(C -> A ; B)], Env, Mode, [if(G, SA, SB)], Env1) :- !, ite(C, A, B, Env, Mode, G, SA, SB, Env1).
body([(C -> A ; B)|Rest], Env, Mode, Stmts, EnvOut) :- !,
    term_variables_v((C, A, B), Vs), term_variables_v(Rest, L0),
    ( Mode = asg(Outer) -> true ; Outer = [] ), ( Mode = ret(Os, _) -> term_variables_v(Os, L1) ; L1 = [] ),
    append([L0, L1, Outer], Later),
    findall(V, ( member(V, Vs), memberchk(V, Later), \+ memberchk(V-_, Env) ), New0), sort(New0, New),
    subtract(New, Outer, Fresh), append(Outer, Fresh, All),
    ite(C, A, B, Env, asg(All), G, SA, SB, TEnv),
    maplist([V, V-(var(L):T), decl(L, T)]>>(memberchk(V-(_:T), TEnv), local(V, L)), Fresh, Binds, Decls),
    append(Binds, Env, Env1), body(Rest, Env1, Mode, S1, EnvOut),
    append(Decls, [if(G, SA, SB)|S1], Stmts).
body([G|Rest], Env, Mode, Stmts, EnvOut) :- goal(G, Env, Mode, S0, Env1), body(Rest, Env1, Mode, S1, EnvOut), append(S0, S1, Stmts).

% Both branches run with the same targets; their types unify.
ite(C, A, B, Env, Mode, [cond(CE)], SA, SB, EnvA) :-
    cond(C, Env, CE, ET, EF), goals(A, GA), goals(B, GB),
    body(GA, ET, Mode, SA, EnvA), body(GB, EF, Mode, SB, EnvB),
    ( Mode = asg(Ts) -> unify_types(Ts, EnvA, EnvB) ; true ).

unify_types([], _, _).
unify_types([V|Vs], EA, EB) :- ( memberchk(V-(_:T), EA), memberchk(V-(_:T2), EB) -> T = T2 ; true ), unify_types(Vs, EA, EB).

term_variables_v(T, Vs) :- findall(V, ( sub_term(X, T), nonvar(X), X = '$v'(V), V \== '_' ), Vs0), sort(Vs0, Vs).

out_val(Env, '$v'(V), T, E) :- !, lookup(V, Env, E0, T0), ( T0 = T -> true ; true ), coerce(E0, T0, T, E).
out_val(_, [], list(ET), list([], ET)) :- !.
out_val(Env, X, T, E) :- val(X, Env, E0, T0), coerce(E0, T0, T, E).

coerce(i(N), int, float, f(F)) :- !, F is float(N).
coerce(E, int, float, conv(E)) :- !.
coerce(E, _, _, E).

% Bind a Prolog variable. Simple expressions are aliased; others get a let.
% Assignment targets of an enclosing if-then-else are assigned instead.
bind(V, E, T, Env, Mode, S, [V-(X:T)|Env]) :-
    (   Mode = asg(Ts), memberchk(V, Ts) -> local(V, L), S = [assign(L, E)], X = var(L)
    ;   simple(E) -> S = [], X = E
    ;   local(V, L), S = [let(L, E)], X = var(L) ).
simple(var(_)). simple(i(_)). simple(f(_)). simple(s(_)). simple(b(_)). simple(nil). simple(c(_)).
simple(field(X, _, _)) :- simple(X). simple(efield(_, _, _, _, _)). simple(unwrap(X, _)) :- simple(X).
simple(idx(var(_), I)) :- simple(I).
simple(jfield(X, _)) :- simple(X).

goal(V0 is A, Env, M, S, Env1) :- !, V0 = '$v'(V), arith(A, Env, E, T), bind(V, E, T, Env, M, S, Env1).
goal('$v'(V) = R, Env, M, S, Env1) :- \+ memberchk(V-_, Env), !, val(R, Env, E, T), bind(V, E, T, Env, M, S, Env1).
goal('$v'(V) = P, Env, _, [], Env1) :- !, lookup(V, Env, X, T), pat(P, X, T, Env-[], Env1-[]).
goal(get(X, F, '$v'(V)), Env, M, S, Env1) :- !,
    val(X, Env, E, J), json(J, Fs), memberchk(F:FT, Fs), bind(V, jfield(E, F), FT, Env, M, S, Env1).
goal(format(string('$v'(V)), Fmt, Args), Env, M, S, Env1) :- !,
    fmt(Fmt, Args, Env, Parts), bind(V, interp(Parts), str, Env, M, S, Env1).
goal(G, Env, M, S, Env1) :-
    G =.. [F|Args], callee(F, Args, NI, OutTs0), length(In, NI), append(In, Outs, Args), !,
    maplist([A, E-T]>>val(A, Env, E, T), In, ETs), pairs_keys_values(ETs, Es, InTs),
    ( sig(F, _, _) -> Call = call(F, Es), OutTs = OutTs0 ; Call = b(F, Es), btype(F, InTs, OT), OutTs = [OT] ),
    (   Outs = [O] -> OutTs = [T], out_bind(O, Call, T, Env, M, S, Env1)
    ;   maplist([O1, V]>>(O1 = '$v'(V)), Outs, Vs), maplist(local, Vs, Ls),
        pairs3(Vs, Ls, OutTs, Bs), append(Bs, Env, Env1), S = [lettuple(Ls, Call)] ).
goal(G, _, _, _, _) :- throw(error(unsupported_goal(G), _)).

pairs3([], [], [], []).
pairs3([V|Vs], [L|Ls], [T|Ts], [V-(var(L):T)|Bs]) :- pairs3(Vs, Ls, Ts, Bs).

out_bind('$v'(V), E, T, Env, M, S, Env1) :- !, bind(V, E, T, Env, M, S, Env1).
out_bind(P, E, T, Env, M, S, Env1) :-          % e.g. nth0(I, L, sample(T1, U1))
    gensym('Tmp', Tmp), bind(Tmp, E, T, Env, M, S, Env0), lookup(Tmp, Env0, X, T), pat(P, X, T, Env0-[], Env1-[]).

% A user fn (inputs per its signature) or a builtin (all args but the last).
callee(F, _, NI, Outs) :- sig(F, In, Outs), !, length(In, NI).
callee(F, Args, NI, [_]) :- length(Args, A), NI is A - 1, builtin(F, NI).

builtin(F, N) :- memberchk(F/N, [parse_iso/1, clock/1, pad2/1, prefix/2, trim/1, split/2, to_int/1,
    drop_prefix/2, last_n/2, length/1, char_at/2, repeat_str/2, string_concat/2, nth0/2, string_length/1, append/2, or_else/2, lowercase/1]).
btype(parse_iso, _, opt(time)).  btype(split, _, list(str)).  btype(to_int, _, opt(int)).
btype(last_n, [L, _], L).  btype(append, [L, L], L).  btype(or_else, [opt(T), T], T).        btype(length, _, int).        btype(string_length, _, int).        btype(nth0, [_, list(T)], T).
btype(F, _, str) :- memberchk(F, [clock, pad2, prefix, trim, drop_prefix, char_at, repeat_str, string_concat, lowercase]).

lookup(V, Env, E, T) :- ( memberchk(V-(E:T), Env) -> true ; throw(error(unbound_variable(V), _)) ).

%% Values (right-hand sides, call arguments)

val('$v'(V), Env, E, T) :- !, lookup(V, Env, E, T).
val(none, _, nil, opt(_)) :- !.
val([], _, list([], T), list(T)) :- !.
val([H|Tl], Env, E, list(T)) :- !,
    (   is_list([H|Tl]) -> vals([H|Tl], Env, Es, T), E = list(Es, T)
    ;   val(H, Env, HE, T), val(Tl, Env, TE, list(T)), E = cons(HE, TE, T) ).
val(X, _, E, T) :- lit(X, E, T), !.
val(A, Env, E, T) :- atom(A), const(A, _), !, arith(A, Env, E, T).
val(A, _, ector(EN, A, []), EN) :- atom(A), enum(EN, Cs), memberchk(A, Cs), !.
val(A, _, chval(CN, A), CN) :- atom(A), choice(CN, Cs), memberchk(A, Cs), !.
val(C, Env, ector(EN, Name, Es), EN) :-
    compound(C), C =.. [Name|Args], enum(EN, Cs), member(D, Cs), D =.. [Name|Fs], same_length(Fs, Args), !,
    maplist([A, _:FT, E]>>(val(A, Env, E0, T0), coerce(E0, T0, FT, E)), Args, Fs, Es).
val(X, _, _, _) :- throw(error(unsupported_value(X), _)).

% Elements share one type (a lambda would copy T per element).
vals([], _, [], _).
vals([X|Xs], Env, [E|Es], T) :- val(X, Env, E, T), vals(Xs, Env, Es, T).


%% Arithmetic

arith('$v'(V), Env, E, T) :- !, lookup(V, Env, E, T).
arith(N, _, i(N), int) :- integer(N), !.
arith(N, _, f(N), float) :- float(N), !.
arith(A, _, c(A), T) :- atom(A), const(A, V), !, ( integer(V) -> T = int ; T = float ).
arith(-A, Env, neg(E), T) :- !, arith(A, Env, E, T).
arith(X, Env, op(Op, EA, EB), T) :- X =.. [Op0, A, B], memberchk(Op0-Op, [(+)-(+), (-)-(-), (*)-(*)]), !, num2(A, B, Env, EA, EB, T).
arith(A / B, Env, op(/, EA, EB), float) :- !, arith(A, Env, EA0, TA), arith(B, Env, EB0, TB), tofloat(EA0, TA, EA), tofloat(EB0, TB, EB).
arith(A // B, Env, op(/, EA, EB), int) :- !, arith(A, Env, EA, int), arith(B, Env, EB, int).
arith(A rem B, Env, op('%', EA, EB), int) :- !, arith(A, Env, EA, int), arith(B, Env, EB, int).
arith(A ** B, Env, b(pow, [EA, EB]), float) :- !, arith(A, Env, EA0, TA), arith(B, Env, EB0, TB), coerce(EA0, TA, float, EA), coerce(EB0, TB, float, EB).
arith(min(A, B), Env, b(min, [EA, EB]), T) :- !, num2(A, B, Env, EA, EB, T).
arith(max(A, B), Env, b(max, [EA, EB]), T) :- !, num2(A, B, Env, EA, EB, T).
arith(abs(A), Env, b(abs, [E]), T) :- !, arith(A, Env, E, T).
arith(float(A), Env, E, float) :- !, arith(A, Env, E0, T), coerce(E0, T, float, E).
arith(truncate(A), Env, E, int) :- !, arith(A, Env, E0, T), ( T == int -> E = E0 ; E = trunc(E0) ).
arith(round(A), Env, round(E), int) :- !, arith(A, Env, E0, T), coerce(E0, T, float, E).
arith(secs(A, B), Env, secs(EA, EB), float) :- !, arith(A, Env, EA, _), arith(B, Env, EB, _).
arith(X, _, _, _) :- throw(error(unsupported_arith(X), _)).

num2(A, B, Env, EA, EB, T) :-
    arith(A, Env, EA0, TA), arith(B, Env, EB0, TB),
    ( TA == int, TB == int -> T = int, EA = EA0, EB = EB0 ; T = float, coerce(EA0, TA, float, EA), coerce(EB0, TB, float, EB) ).
tofloat(i(N), int, f(F)) :- !, F is float(N).
tofloat(E, T, E1) :- coerce(E, T, float, E1).

%% Conditions: cond(+Goal, +Env, -Expr, -EnvIfTrue, -EnvIfFalse). Testing an
%% optional against none narrows it on the matching branch.

cond((A, B), Env, op('&&', EA, EB), ET, Env) :- !, cond(A, Env, EA, E1, _), cond(B, E1, EB, ET, _).
cond((A ; B), Env, op('||', EA, EB), Env, Env) :- !, cond(A, Env, EA, _, _), cond(B, Env, EB, _, _).
cond(\+ A, Env, not(E), EF, ET) :- !, cond(A, Env, E, ET, EF).
cond('$v'(V) == none, Env, op('==', X, nil), Env, EF) :- !, narrow(V, Env, X, EF).
cond('$v'(V) \== none, Env, op('!=', X, nil), ET, Env) :- !, narrow(V, Env, X, ET).
cond('$v'(V) = P, Env, kind(X, Case), Env, Env) :- lookup(V, Env, X0, T0), strip_opt(X0, T0, X, T), enum(T, _), !, functor(P, Case, _).
cond(A == [], Env, empty(EA), Env, Env) :- !, val(A, Env, EA, _).
cond(A \== [], Env, not(empty(EA)), Env, Env) :- !, val(A, Env, EA, _).
cond(A == B, Env, op('==', EA, EB), Env, Env) :- !, val(A, Env, EA, _), val(B, Env, EB, _).
cond(A \== B, Env, op('!=', EA, EB), Env, Env) :- !, val(A, Env, EA, _), val(B, Env, EB, _).
cond(member(X, L), Env, b(member, [EL, EX]), Env, Env) :- !, val(X, Env, EX, _), val(L, Env, EL, _).
cond(contains(S, X), Env, b(contains, [ES, EX]), Env, Env) :- !, val(S, Env, ES, _), val(X, Env, EX, _).
cond(starts_with(S, X), Env, b(starts_with, [ES, EX]), Env, Env) :- !, val(S, Env, ES, _), val(X, Env, EX, _).
cond(ends_with(S, X), Env, b(ends_with, [ES, EX]), Env, Env) :- !, val(S, Env, ES, _), val(X, Env, EX, _).
cond(C, Env, op(Op, EA, EB), Env, Env) :-
    C =.. [Op0, A, B], memberchk(Op0-Op, [(<)-(<), (>)-(>), (=<)-(<=), (>=)-(>=), (=:=)-(==), (=\=)-('!=')]), !,
    arith(A, Env, EA0, TA), arith(B, Env, EB0, TB),
    ( TA == int, TB == float -> coerce(EA0, TA, float, EA), EB = EB0
    ; TA == float, TB == int -> coerce(EB0, TB, float, EB), EA = EA0
    ; EA = EA0, EB = EB0 ).
cond(C, _, _, _, _) :- throw(error(unsupported_condition(C), _)).

narrow(V, Env, X, [V-(unwrap(X, T):T)|Env]) :- lookup(V, Env, X, opt(T)), !.
narrow(V, Env, X, Env) :- lookup(V, Env, X, _).
strip_opt(unwrap(X, T), T, unwrap(X, T), T) :- !.
strip_opt(X, opt(T), unwrap(X, T), T) :- !.
strip_opt(X, T, X, T).

%% format/3 → interpolation parts

fmt(Fmt, Args, Env, Parts) :- string_codes(Fmt, Cs), fmt_parts(Cs, Args, Env, Parts).
fmt_parts([], [], _, []) :- !.
fmt_parts([0'~, 0'~|Cs], As, Env, [s("~")|Ps]) :- !, fmt_parts(Cs, As, Env, Ps).
fmt_parts([0'~, D|Cs], [A|As], Env, [P|Ps]) :- memberchk(D, `wdas`), !, val(A, Env, E, _), P = hole(E), fmt_parts(Cs, As, Env, Ps).
fmt_parts([0'~, N, 0'f|Cs], [A|As], Env, [fixed(E, D)|Ps]) :- !, D is N - 0'0, val(A, Env, E, _), fmt_parts(Cs, As, Env, Ps).
fmt_parts(Cs, As, Env, [s(S)|Ps]) :- append(Lit, Rest, Cs), Lit \== [], ( Rest = [0'~|_] ; Rest == [] ), !, string_codes(S, Lit), fmt_parts(Rest, As, Env, Ps).

%% ── Emitting ────────────────────────────────────────────────────────────────

file_text(T, Text) :-
    findall(N, sig(N, _, _), Ns0), list_to_set(Ns0, Ns),
    maplist([N, F]>>catch(fn_ir(N, F), E, (print_message(error, E), format(user_error, "in fn ~w~n", [N]), halt(1))), Ns, Fns),
    with_output_to(string(Text), ( header(T), forall(enum(EN, Cs), enum_decl(T, EN, Cs)), forall(choice(CN, Cs), choice_decl(T, CN, Cs)), forall(json(JN, JFs), json_decl(T, JN, JFs)), settings_decl(T), class_open(T),
        forall(const(CN, CV), const_decl(T, CN, CV)), forall(member(F, Fns), ( nl, catch(fn_decl(T, F), E, ( arg(1, F, FN), format(user_error, "emitting ~w: ~q~n", [FN, E]), halt(1) )) )), runtime(T), class_close(T) )).

header(swift) :- format("// Generated by logic/plc.pl from logic/core.pl — do not edit.~nimport Foundation~n").
header(csharp) :- format("// Generated by logic/plc.pl from logic/core.pl — do not edit.~nusing System;~nusing System.Collections.Generic;~nusing System.Globalization;~nusing System.Linq;~n~nnamespace ClaudeLimits~n{~n").
class_open(swift) :- nl.
class_open(csharp) :- format("public static partial class Logic~n{~n").
class_close(swift).
class_close(csharp) :- format("}~n}~n").

const_decl(swift, N, V) :- camel(N, C), format("let ~w = ~w~n", [C, V]).
const_decl(csharp, N, V) :- pascal(N, C), ( integer(V) -> T = int ; T = double ), format("    public const ~w ~w = ~w;~n", [T, C, V]).

nat(EN, N) :- ( native(EN, N0), atom(N0) -> N = N0 ; pascal(EN, N) ).

enum_decl(swift, EN, Cases) :-
    nat(EN, Nat), ( EN == error -> format("~nenum ~w: LocalizedError {~n", [Nat]) ; format("~nenum ~w {~n", [Nat]) ),
    forall(member(C, Cases), ( C =.. [N|Fs], camel(N, CN), ( Fs == [] -> format("    case ~w~n", [CN])
        ; maplist([_:FT, S]>>ty(swift, FT, S), Fs, Ss), atomic_list_concat(Ss, ', ', J), format("    case ~w(~w)~n", [CN, J]) ) )),
    maplist([C, CN]>>(functor(C, N, _), camel(N, CN)), Cases, CNs), atomic_list_concat(CNs, ', ', All),
    format("    enum Kind { case ~w }~n    var kind: Kind {~n        switch self {~n", [All]),
    forall(member(CN, CNs), format("        case .~w: return .~w~n", [CN, CN])),
    format("        }~n    }~n"), ( EN == error -> format("    var errorDescription: String? { friendlyMessage(self) }~n") ; true ), format("}~n").
enum_decl(csharp, EN, Cases) :-
    nat(EN, Nat), maplist([C, CN]>>(functor(C, N, _), pascal(N, CN)), Cases, CNs), atomic_list_concat(CNs, ', ', All),
    ( EN == error -> Base = ' : Exception', Ctor = ' : base(null)' ; Base = '', Ctor = '' ),
    format("public enum ~wKind { ~w }~n~npublic sealed class ~w~w~n{~n    public readonly ~wKind Kind;~n", [Nat, All, Nat, Base, Nat]),
    findall(F-FT, ( member(C, Cases), C =.. [_|Fs], member(F:FT, Fs) ), FTs0), sort(FTs0, FTs),
    forall(member(F-FT, FTs), ( pascal(F, P), ty(csharp, FT, S), format("    public ~w ~w;~n", [S, P]) )),
    format("    ~w(~wKind kind)~w { Kind = kind; }~n", [Nat, Nat, Ctor]),
    forall(member(C, Cases), ( C =.. [N|Fs], pascal(N, CN),
        maplist([F:FT, S]>>(ty(csharp, FT, T1), camel(F, FC), format(atom(S), '~w ~w', [T1, FC])), Fs, Ps), atomic_list_concat(Ps, ', ', PJ),
        maplist([F:_, S]>>(pascal(F, FP), camel(F, FC), format(atom(S), '~w = ~w', [FP, FC])), Fs, As), atomic_list_concat(As, ', ', AJ),
        ( Fs == [] -> Init = '' ; format(atom(Init), ' { ~w }', [AJ]) ),
        format("    public static ~w ~w(~w) => new ~w(~wKind.~w)~w;~n", [Nat, CN, PJ, Nat, Nat, CN, Init]) )),
    ( EN == error -> format("    public override string Message => Logic.FriendlyMessage(this);~n") ; true ), format("}~n~n").

fn_decl(T, fn(N, Ps, Ret, Body)) :-
    fname(T, N, F), ty(T, Ret, RS),
    (   T == swift -> maplist([P-PT, S]>>(ty(swift, PT, TS), format(atom(S), '_ ~w: ~w', [P, TS])), Ps, PSs),
        atomic_list_concat(PSs, ', ', PJ), format("func ~w(~w) -> ~w {~n", [F, PJ, RS])
    ;   maplist([P-PT, S]>>(ty(csharp, PT, TS), format(atom(S), '~w ~w', [TS, P])), Ps, PSs),
        atomic_list_concat(PSs, ', ', PJ), format("    public static ~w ~w(~w)~n    {~n", [RS, F, PJ]) ),
    ( T == swift -> D = 1 ; D = 2 ), peep(Body, B), stmts(T, B, D),
    ( T == swift -> format("}~n") ; format("    }~n") ).

% let x = e; return x  →  return e
peep([let(L, E), ret(var(L))], [ret(E)]) :- !.
peep([lettuple(Ls, E), ret(tuple(Vs))], [ret(E)]) :- maplist([L, var(L)]>>true, Ls, Vs), !.
peep([S|Ss], [S1|Ss1]) :- !, peep_s(S, S1), peep(Ss, Ss1).
peep([], []).
peep_s(if(G, A, B), if(G, A1, B1)) :- !, peep(A, A1), peep(B, B1).
peep_s(S, S).

ind(D) :- forall(between(1, D, _), write("    ")).

stmts(T, Ss, D) :- forall(member(S, Ss), stmt(T, S, D)).

stmt(swift, let(L, E), D) :- ind(D), format("let ~w = ", [L]), ex(swift, E), nl.
stmt(csharp, let(L, E), D) :- ind(D), format("var ~w = ", [L]), ex(csharp, E), format(";~n").
stmt(swift, lettuple(Ls, E), D) :- ind(D), atomic_list_concat(Ls, ', ', J), format("let (~w) = ", [J]), ex(swift, E), nl.
stmt(csharp, lettuple(Ls, E), D) :- ind(D), atomic_list_concat(Ls, ', ', J), format("var (~w) = ", [J]), ex(csharp, E), format(";~n").
stmt(swift, decl(L, Ty), D) :- ind(D), ty(swift, Ty, S), format("let ~w: ~w~n", [L, S]).
stmt(csharp, decl(L, Ty), D) :- ind(D), ty(csharp, Ty, S), format("~w ~w;~n", [S, L]).
stmt(T, assign(L, E), D) :- ind(D), format("~w = ", [L]), ex(T, E), ( T == csharp -> format(";~n") ; nl ).
stmt(T, ret(E), D) :- ind(D), write("return "), ex(T, E), ( T == csharp -> format(";~n") ; nl ).
stmt(swift, fail, D) :- ind(D), format("fatalError(\"unreachable\")~n").
stmt(csharp, fail, D) :- ind(D), format("throw new InvalidOperationException();~n").
stmt(T, if(G, A, B), D) :- ind(D), if_chain(T, G, A, B, D).

if_chain(T, G, A, B, D) :-
    write("if "), guards(T, G), ( T == swift -> format(" {~n") ; format("~n"), ind(D), format("{~n") ),
    case_binds(T, G, D), D1 is D + 1, stmts(T, A, D1), ind(D), write("}"),
    (   B == [] -> nl
    ;   B = [if(G2, A2, B2)] -> ( T == csharp -> nl, ind(D) ; true ), write(" else "), if_chain(T, G2, A2, B2, D)
    ;   ( T == swift -> format(" else {~n") ; nl, ind(D), format("else~n"), ind(D), format("{~n") ),
        stmts(T, B, D1), ind(D), format("}~n") ).

guards(swift, Gs) :- foldl([G, Sep0, ", "]>>(write(Sep0), guard(swift, G)), Gs, "", _).
guards(csharp, Gs) :- write("("), foldl([G, Sep0, " && "]>>(write(Sep0), guard(csharp, G)), Gs, "", _), write(")").
guard(T, cond(E)) :- ex(T, E).
guard(swift, case(X, _, Case, Binds)) :-
    camel(Case, C), enum(_, Cases), case_fields(Cases, Case, Fs),
    (   Binds \== [] -> maplist([F:_, S]>>( memberchk(F-L, Binds) -> format(atom(S), 'let ~w', [L]) ; S = '_' ), Fs, Ss),
        atomic_list_concat(Ss, ', ', J), format("case .~w(~w) = ", [C, J])
    ;   format("case .~w = ", [C]) ),
    ex(swift, X).
guard(csharp, case(X, T, Case, _)) :- nat(T, N), pascal(Case, C), ex(csharp, X), format(".Kind == ~wKind.~w", [N, C]).
case_binds(_, _, _).

%% Expressions

ex(T, E) :- ex(T, E, S), write(S).
ex(T, E, S) :- et(E, As, Sw, Cs), !, maplist(both(T), As, Ss), ( T == swift -> Tpl = Sw ; Tpl = Cs ), fill(Tpl, Ss, S).
ex(_, i(N), S) :- format(string(S), "~w", [N]).
ex(_, f(N), S) :- format(string(S), "~w", [N]).
ex(T, s(X), S) :- quote(T, X, S).
ex(_, b(B), S) :- memberchk(B, [true, false]), !, atom_string(B, S).
ex(swift, nil, "nil").
ex(csharp, nil, "null").
ex(_, var(L), S) :- atom_string(L, S).
ex(swift, c(N), S) :- camel(N, C), atom_string(C, S).
ex(csharp, c(N), S) :- pascal(N, C), atom_string(C, S).
ex(T, op(Op, A, B), S) :- sub(T, A, SA), sub(T, B, SB), format(string(S), "~w ~w ~w", [SA, Op, SB]).
ex(T, not(A), S) :- ex(T, A, SA), ( A = var(_) -> format(string(S), "!~w", [SA]) ; format(string(S), "!(~w)", [SA]) ).
ex(swift, unwrap(A, _), S) :- sub(swift, A, SA), format(string(S), "~w!", [SA]).
ex(csharp, unwrap(A, T), S) :- sub(csharp, A, SA), ( value_type(T) -> format(string(S), "~w.Value", [SA]) ; S = SA ).
ex(T, field(X, R, F), S) :- sub(T, X, SX), native(R, N), N =.. [_|Langs], member(L, Langs), functor(L, T, _), record(R, Fs), nth1(I, Fs, F:_), !, arg(I, L, NF), format(string(S), "~w.~w", [SX, NF]).
ex(swift, efield(_, _, _, _, L), S) :- atom_string(L, S).
ex(csharp, efield(X, _, _, F, _), S) :- sub(csharp, X, SX), pascal(F, P), format(string(S), "~w.~w", [SX, P]).
ex(swift, kind(X, Case), S) :- sub(swift, X, SX), camel(Case, C), format(string(S), "~w.kind == .~w", [SX, C]).
ex(csharp, kind(X, Case), S) :- sub(csharp, X, SX), enum(EN, Cs), member(D, Cs), functor(D, Case, _), !, nat(EN, N), pascal(Case, C), format(string(S), "~w.Kind == ~wKind.~w", [SX, N, C]).
ex(swift, list(Es, _), S) :- maplist(ex(swift), Es, Ss), atomic_list_concat(Ss, ', ', J), format(string(S), "[~w]", [J]).
ex(csharp, list(Es, T), S) :- maplist(ex(csharp), Es, Ss), atomic_list_concat(Ss, ', ', J), ty(csharp, T, TS), format(string(S), "new List<~w> { ~w }", [TS, J]).
ex(swift, list([], _), "[]") :- !.
ex(csharp, list([], T), S) :- !, ty(csharp, T, TS), format(string(S), "new List<~w>()", [TS]).
ex(T, tuple(Es), S) :- maplist(ex(T), Es, Ss), atomic_list_concat(Ss, ', ', J), format(string(S), "(~w)", [J]).
ex(T, call(F, Es), S) :- fname(T, F, FN), maplist(ex(T), Es, Ss), atomic_list_concat(Ss, ', ', J), format(string(S), "~w(~w)", [FN, J]).
ex(T, b(F, Es), S) :- maplist(both(T), Es, Ss), bi(T, F, Ss, S), !.
ex(swift, jfield(X, F), S) :- sub(swift, X, SX), camel(F, C), format(string(S), "~w.~w", [SX, C]).
ex(csharp, jfield(X, F), S) :- sub(csharp, X, SX), pascal(F, C), format(string(S), "~w.~w", [SX, C]).
ex(T, chval(CN, A), S) :- pascal(CN, P), ( T == swift -> camel(A, C) ; pascal(A, C) ), format(string(S), "~w.~w", [P, C]).
ex(swift, ector(EN, A, Es), S) :- nat(EN, N), camel(A, C), ( Es == [] -> format(string(S), "~w.~w", [N, C]) ; maplist(ex(swift), Es, Ss), atomic_list_concat(Ss, ', ', J), format(string(S), "~w.~w(~w)", [N, C, J]) ).
ex(csharp, ector(EN, A, Es), S) :- nat(EN, N), pascal(A, C), maplist(ex(csharp), Es, Ss), atomic_list_concat(Ss, ', ', J), format(string(S), "~w.~w(~w)", [N, C, J]).
ex(T, interp(Ps), S) :- interp(T, Ps, S).

% Simple expression forms as Swift / C# templates over their (parenthesised) operands.
et(neg(A), [A], "-%1", "-%1").
et(conv(A), [A], "Double(%1)", "(double)%1").
et(trunc(A), [A], "Int(%1)", "(int)%1").
et(round(A), [A], "Int(%1.rounded())", "(int)Math.Round(%1, MidpointRounding.AwayFromZero)").
et(secs(A, B), [A, B], "%2.timeIntervalSince(%1)", "(%2 - %1).TotalSeconds").
et(idx(X, I), [X, I], "%1[%2]", "%1[%2]").
et(empty(X), [X], "%1.isEmpty", "%1.Count == 0").
et(drop1(X), [X], "Array(%1.dropFirst())", "%1.Skip(1).ToList()").
et(cons(H, Tl, _), [H, Tl], "[%1] + %2", "Cons(%1, %2)").

% Parenthesise compound operands.
sub(T, E, S) :- ex(T, E, S0), ( compound(E), E = op(_, _, _) -> format(string(S), "(~w)", [S0]) ; S = S0 ).

% Builtins as Swift / C# templates; %1, %2 are the emitted arguments.
bi(T, F, As, S) :- bt(F, Sw, Cs), ( T == swift -> Tpl = Sw ; Tpl = Cs ), fill(Tpl, As, S).
fill(Tpl, As, S) :- string_codes(Tpl, Codes), tpl(Codes, 0' , As, Out), string_codes(S, Out).
% %N takes the bare operand where it's already delimited — e.g. `f(%1)`, `%1, ` —
% and the parenthesised one anywhere else (`%1.count`, `(int)%1`).
tpl([], _, _, []).
tpl([0'%, D|Cs], Prev, As, Out) :- between(0'1, 0'9, D), !, I is D - 0'0, nth1(I, As, Bare-Par),
    ( memberchk(Prev, `([ `), ( Cs = [] ; Cs = [N|_], memberchk(N, `)],`) ) -> A = Bare ; A = Par ),
    string_codes(A, AC), tpl(Cs, 0'), As, Rest), append(AC, Rest, Out).
tpl([C|Cs], _, As, [C|Out]) :- tpl(Cs, C, As, Out).
both(T, E, Bare-Par) :- ex(T, E, Bare), sub(T, E, Par).

bt(parse_iso, "parseISO(%1)", "Format.ParseISO(%1)").
bt(clock, "formatClock(%1)", "Format.ClockTime(%1)").
bt(pad2, "String(format: \"%02d\", %1)", "%1.ToString(\"00\")").
bt(prefix, "String(%1.prefix(%2))", "Prefix(%1, %2)").
bt(trim, "%1.trimmingCharacters(in: .whitespacesAndNewlines)", "%1.Trim()").
bt(split, "%1.components(separatedBy: %2)", "%1.Split(new[] { %2 }, StringSplitOptions.None)").
bt(to_int, "Int(%1)", "ToInt(%1)").
bt(drop_prefix, "(%1.hasPrefix(%2) ? String(%1.dropFirst(%2.count)) : %1)", "(%1.StartsWith(%2) ? %1.Substring(%2.Length) : %1)").
bt(last_n, "Array(%1.suffix(%2))", "%1.Skip(Math.Max(0, %1.Count - %2)).ToList()").
bt(length, "%1.count", "%1.Count").
bt(char_at, "String(Array(%1)[%2])", "%1[%2].ToString()").
bt(repeat_str, "String(repeating: %1, count: %2)", "string.Concat(Enumerable.Repeat(%1, %2))").
bt(string_concat, "%1 + %2", "%1 + %2").
bt(append, "%1 + %2", "Append(%1, %2)").
bt(or_else, "(%1 ?? %2)", "(%1 ?? %2)").
bt(string_length, "%1.count", "%1.Length").
bt(nth0, "%2[%1]", "%2[%1]").
bt(min, "min(%1, %2)", "Math.Min(%1, %2)").
bt(max, "max(%1, %2)", "Math.Max(%1, %2)").
bt(pow, "pow(%1, %2)", "Math.Pow(%1, %2)").
bt(abs, "abs(%1)", "Math.Abs(%1)").
bt(member, "%1.contains(%2)", "%1.Contains(%2)").
bt(contains, "%1.contains(%2)", "%1.Contains(%2)").
bt(starts_with, "%1.hasPrefix(%2)", "%1.StartsWith(%2, StringComparison.Ordinal)").
bt(ends_with, "%1.hasSuffix(%2)", "%1.EndsWith(%2, StringComparison.Ordinal)").
bt(lowercase, "%1.lowercased()", "%1.ToLowerInvariant()").

quote(T, X, S) :- string_codes(X, Cs), foldl(esc(T, plain), Cs, Parts, []), atomic_list_concat([""|Parts], Body0), format(string(S), "\"~w\"", [Body0]).
esc(_, _, 0'\\, ["\\\\"|R], R) :- !.
esc(_, _, 0'", ["\\\""|R], R) :- !.
esc(_, _, 0'\n, ["\\n"|R], R) :- !.
esc(csharp, interp, 0'{, ["{{"|R], R) :- !.
esc(csharp, interp, 0'}, ["}}"|R], R) :- !.
esc(_, _, C, [S|R], R) :- char_code(A, C), atom_string(A, S).

interp(T, Ps, S) :-
    foldl(ipart(T), Ps, Parts, []), atomic_list_concat([""|Parts], B),
    ( T == swift -> format(string(S), "\"~w\"", [B]) ; format(string(S), "$\"~w\"", [B]) ).
ipart(T, s(X), [P|R], R) :- !, string_codes(X, Cs), ( T == csharp -> M = interp ; M = plain ), foldl(esc(T, M), Cs, Ps, []), atomic_list_concat([""|Ps], P).
ipart(swift, hole(E), [P|R], R) :- ex(swift, E, S), format(string(P), "\\(~w)", [S]).
ipart(csharp, hole(E), [P|R], R) :- ex(csharp, E, S), format(string(P), "{(~w)}", [S]).
ipart(swift, fixed(E, D), [P|R], R) :- ex(swift, E, S), format(string(P), "\\(String(format: \"%.~df\", ~w))", [D, S]).
ipart(csharp, fixed(E, D), [P|R], R) :- ex(csharp, E, S), length(Zs, D), maplist(=('0'), Zs), atomic_list_concat(Zs, Z), format(string(P), "{(~w).ToString(\"0.~w\", CultureInfo.InvariantCulture)}", [S, Z]).

%% JSON models: Codable structs / DataContract classes

jty(swift, float, 'Double'). jty(swift, bool, 'Bool'). jty(swift, str, 'String').
jty(csharp, float, double). jty(csharp, bool, bool). jty(csharp, str, string).
jty(_, N, P) :- json(N, _), nat(N, P).
jty(swift, opt(X), S) :- jty(swift, X, XS), format(atom(S), '~w?', [XS]).
jty(csharp, opt(X), S) :- jty(csharp, X, XS), ( memberchk(X, [float, bool]) -> format(atom(S), '~w?', [XS]) ; S = XS ).
jty(swift, list(X), S) :- jty(swift, X, XS), format(atom(S), '[~w]', [XS]).
jty(csharp, list(X), S) :- jty(csharp, X, XS), format(atom(S), 'List<~w>', [XS]).

json_decl(swift, N, Fs) :-
    nat(N, P), format("~nstruct ~w: Codable {~n", [P]),
    forall(member(F:T, Fs), ( camel(F, C), jty(swift, T, S), format("    let ~w: ~w~n", [C, S]) )),
    (   forall(member(F:_, Fs), camel(F, F)) -> true
    ;   maplist([F:_, S]>>(camel(F, C), ( C == F -> S = C ; format(atom(S), '~w = "~w"', [C, F]) )), Fs, Ss),
        atomic_list_concat(Ss, ', ', J), format("    enum CodingKeys: String, CodingKey { case ~w }~n", [J]) ),
    format("}~n").
% A required number is stored nullable and read as 0 when missing, so one odd
% field can't fail the whole decode.
json_decl(csharp, N, Fs) :-
    nat(N, P), format("[System.Runtime.Serialization.DataContract]~npublic sealed class ~w~n{~n", [P]),
    forall(member(F:T, Fs), ( pascal(F, C),
        (   T == float -> format("    [System.Runtime.Serialization.DataMember(Name = \"~w\")] public double? ~wRaw;~n    public double ~w => ~wRaw ?? 0;~n", [F, C, C, C])
        ;   jty(csharp, T, S), format("    [System.Runtime.Serialization.DataMember(Name = \"~w\")] public ~w ~w;~n", [F, S, C]) ) )),
    format("}~n~n").

%% Choices (plain enums) and persisted settings

choice_decl(swift, N, Cs) :- pascal(N, P), maplist(camel, Cs, Cc), atomic_list_concat(Cc, ', ', J), format("~nenum ~w: Int { case ~w }~n", [P, J]).
choice_decl(csharp, N, Cs) :- pascal(N, P), maplist(pascal, Cs, Cc), atomic_list_concat(Cc, ', ', J), format("public enum ~w { ~w }~n~n", [P, J]).

key(key(K), K, false).
key(hide(K), K, true).

settings_decl(swift) :-
    format("~nextension Settings {~n"),
    forall(setting(N, T, S), ( camel(N, P), key(S, K0, Inv), camel(K0, K), sw_setting(T, Inv, K, Ty, G, St),
        format("    var ~w: ~w {~n        get { ~w }~n        set { ~w }~n    }~n", [P, Ty, G, St]) )),
    format("}~n").
settings_decl(csharp) :-
    format("[System.Runtime.Serialization.DataContract]~nsealed class SettingsData~n{~n"),
    forall(setting(_, T, S), ( key(S, K0, _), camel(K0, K), cs_field(T, FT),
        format("    [System.Runtime.Serialization.DataMember] public ~w ~w;~n", [FT, K]) )),
    format("}~n~npublic sealed partial class Settings~n{~n"),
    forall(setting(N, T, S), ( pascal(N, P), key(S, K0, Inv), camel(K0, K), cs_setting(T, Inv, K, Ty, G, St),
        format("    public ~w ~w { get { lock (gate) return ~w; } set { lock (gate) { ~w; Save(); } } }~n", [Ty, P, G, St]) )),
    format("}~n~n").

% sw_setting(Type, Inverted, Key, SwiftType, Getter, Setter)
sw(K, G0, S0, G, S) :- format(atom(G), G0, [K]), format(atom(S), S0, [K]).
sw_setting(bool, false, K, 'Bool', G, S) :- sw(K, 'd.bool(forKey: "~w")', 'd.set(newValue, forKey: "~w")', G, S).
sw_setting(bool, true, K, 'Bool', G, S) :- sw(K, '!d.bool(forKey: "~w")', 'd.set(!newValue, forKey: "~w")', G, S).
sw_setting(int, _, K, 'Int', G, S) :- sw(K, 'd.integer(forKey: "~w")', 'd.set(newValue, forKey: "~w")', G, S).
sw_setting(str, _, K, 'String', G, S) :- sw(K, 'd.string(forKey: "~w") ?? ""', 'd.set(newValue, forKey: "~w")', G, S).
sw_setting(opt(str), _, K, 'String?', G, S) :- sw(K, 'd.string(forKey: "~w")', 'd.set(newValue, forKey: "~w")', G, S).
sw_setting(opt(int), _, K, 'Int?', G, S) :- sw(K, 'd.object(forKey: "~w") as? Int', 'd.set(newValue, forKey: "~w")', G, S).
sw_setting(opt(time), _, K, 'Date?', G, S) :- sw(K, 'd.object(forKey: "~w") as? Date', 'd.set(newValue, forKey: "~w")', G, S).
sw_setting(json, _, K, 'Data?', G, S) :- sw(K, 'd.data(forKey: "~w")', 'd.set(newValue, forKey: "~w")', G, S).
sw_setting(set(int), _, K, 'Set<Int>', G, S) :- sw(K, 'Set(d.array(forKey: "~w") as? [Int] ?? [])', 'd.set(Array(newValue), forKey: "~w")', G, S).
sw_setting(C, _, K, P, G, S) :-
    choice(C, [D|_]), pascal(C, P), camel(D, DC),
    format(atom(G), '~w(rawValue: d.integer(forKey: "~w")) ?? .~w', [P, K, DC]), format(atom(S), 'd.set(newValue.rawValue, forKey: "~w")', [K]).

cs_field(bool, bool). cs_field(int, int). cs_field(str, string). cs_field(opt(str), string). cs_field(opt(int), 'int?').
cs_field(opt(time), 'double?'). cs_field(json, string). cs_field(set(int), 'int[]'). cs_field(C, int) :- choice(C, _).

% cs_setting(Type, Inverted, Key, CSharpType, Getter, Setter) — Getter/Setter run on SettingsData d.
cs_setting(bool, false, K, bool, G, S) :- sw(K, 'd.~w', 'd.~w = value', G, S).
cs_setting(bool, true, K, bool, G, S) :- sw(K, '!d.~w', 'd.~w = !value', G, S).
cs_setting(int, _, K, int, G, S) :- sw(K, 'd.~w', 'd.~w = value', G, S).
cs_setting(str, _, K, string, G, S) :- sw(K, 'd.~w ?? ""', 'd.~w = value', G, S).
cs_setting(opt(str), _, K, string, G, S) :- sw(K, 'd.~w', 'd.~w = value', G, S).
cs_setting(opt(int), _, K, 'int?', G, S) :- sw(K, 'd.~w', 'd.~w = value', G, S).
cs_setting(json, _, K, string, G, S) :- sw(K, 'd.~w', 'd.~w = value', G, S).
cs_setting(opt(time), _, K, 'DateTime?', G, S) :-
    format(atom(G), 'd.~w.HasValue ? Format.FromUnix(d.~w.Value) : (DateTime?)null', [K, K]),
    format(atom(S), 'd.~w = value.HasValue ? Format.ToUnix(value.Value) : (double?)null', [K]).
cs_setting(set(int), _, K, 'HashSet<int>', G, S) :- sw(K, 'new HashSet<int>(d.~w ?? new int[0])', 'd.~w = value.ToArray()', G, S).
cs_setting(C, _, K, P, G, S) :- choice(C, _), pascal(C, P), format(atom(G), '(~w)d.~w', [P, K]), format(atom(S), 'd.~w = (int)value', [K]).

%% Runtime helpers the C# output needs (Swift's stdlib covers the rest).
runtime(swift).
runtime(csharp) :- format("~n    public static string Prefix(string s, int n) => s == null ? \"\" : s.Length <= n ? s : s.Substring(0, n);~n    static int? ToInt(string s) => int.TryParse(s, NumberStyles.None, CultureInfo.InvariantCulture, out var n) ? n : (int?)null;~n    static List<T> Cons<T>(T h, IEnumerable<T> t) { var l = new List<T> { h }; l.AddRange(t); return l; }~n    static List<T> Append<T>(IEnumerable<T> a, IEnumerable<T> b) { var l = new List<T>(a); l.AddRange(b); return l; }~n").
