-module(game_server_ffi).
-export([generate_id/0, dynamic_to_json/1, get_env/1]).

%% Génère un identifiant de partie de 6 caractères alphanumériques.
generate_id() ->
    Chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789",
    Len = length(Chars),
    Id = lists:map(fun(_) ->
        lists:nth(rand:uniform(Len), Chars)
    end, lists:seq(1, 6)),
    list_to_binary(Id).

%% Convertit une valeur Dynamic (issue du parsing JSON par OTP 27+)
%% en sa représentation JSON binaire, puis en string Gleam.
%%
%% OTP 27+ expose json:encode/1 qui accepte les types issus de json:decode/1 :
%%   null        -> null
%%   true/false  -> boolean
%%   number      -> number
%%   binary      -> string JSON
%%   list        -> array JSON
%%   map         -> object JSON
get_env(Name) ->
    case os:getenv(binary_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, list_to_binary(Value)}
    end.

dynamic_to_json(Value) ->
    try
        Encoded = json:encode(Value),
        {ok, unicode:characters_to_binary(Encoded)}
    catch
        _:_ -> {error, nil}
    end.
