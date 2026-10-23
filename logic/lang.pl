:- encoding(utf8).
% The small language core.pl is written in. Loading this file makes core.pl
% runnable as ordinary Prolog (the oracle); logic/plc.pl compiles the same
% clauses to Swift and C#. Everything here has a twin in plc.pl's runtime.

:- op(1150, fx, fn).
:- op(1150, fx, enum).
:- op(1150, fx, record).
:- op(1150, fx, const).
:- op(1150, fx, native).
:- op(1150, fx, setting).
:- op(1150, fx, choice).
:- op(1150, fx, json).
:- use_module(library(arithmetic)).

% Declarations only matter to the compiler — except constants, which also
% become arithmetic functions so rules can write `X is poll_interval * 2`, and
% fn signatures and choices, kept as sig(Name, Ins, Outs) / choice(Name, Cases)
% for the oracle's typed calls.
:- dynamic sig/3, choice/2.
term_expansion((:- fn (H -> O)), (:- assertz(sig(N, Is, Os)))) :- H =.. [N|Is], ( O = (_, _) -> comma_list(O, Os) ; Os = [O] ).
term_expansion((:- choice N = Cs), (:- assertz(choice(N, Cs)))).
term_expansion((:- const Name = Value), [Fact, (:- arithmetic_function(Name/0))]) :- Fact =.. [Name, Value].
term_expansion((:- Decl), []) :- compound(Decl), functor(Decl, F, 1), memberchk(F, [fn, enum, record, native, setting, choice, json]).

% Time is seconds since 1970 here; Date / DateTime in the apps.
:- arithmetic_function(secs/2).
secs(From, To, S) :- S is To - From.

parse_iso(none, none) :- !.
parse_iso(S, D) :- catch(parse_time(S, iso_8601, D0), _, fail), !, D = D0.
parse_iso(_, none).

% Reset clock. The apps use the user's locale; the spec pins UTC + en-US.
clock(T, S) :-
    stamp_date_time(T, date(_, _, _, H, M, _, _, _, _), 'UTC'),
    H12 is (H + 11) mod 12 + 1,
    ( H < 12 -> AP = "AM" ; AP = "PM" ),
    pad2(M, MM), format(string(S), "~d:~w ~w", [H12, MM, AP]).

pad2(N, S) :- format(string(S), "~|~`0t~d~2+", [N]).
prefix(S, N, P) :- string_length(S, L), ( L =< N -> P = S ; sub_string(S, 0, N, _, P) ).
trim(S, T) :- split_string(S, "", " \t\n\r", [T]).
split(S, Sep, L) :- split_string(S, Sep, "", L).
to_int(S, N) :- ( catch(number_string(X, S), _, fail), integer(X) -> N = X ; N = none ).
drop_prefix(S, P, R) :- ( string_concat(P, R0, S) -> R = R0 ; R = S ).
last_n(L, N, Sub) :- length(L, Len), K is max(0, Len - N), length(Pre, K), append(Pre, Sub, L).
char_at(S, I, C) :- sub_string(S, I, 1, _, C).
repeat_str(S, N, R) :- length(L, N), maplist(=(S), L), atomic_list_concat(L, A), atom_string(A, R).
contains(S, Sub) :- once(sub_string(S, _, _, _, Sub)).
starts_with(S, P) :- once(string_concat(P, _, S)).
ends_with(S, X) :- once(string_concat(_, X, S)).
lowercase(S, L) :- string_lower(S, L).
or_else(X, D, V) :- ( X == none -> V = D ; V = X ).
get(Obj, Key, V) :- ( get_dict(Key, Obj, V0), V0 \== null -> V = V0 ; V = none ).
