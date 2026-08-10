-module(yacwu_git_port).
-export([run/2]).

-define(MAX_OUTPUT, 5242880).
-define(TIMEOUT_MS, 10000).

%% Run git without a shell. Both the executable and every argument are passed
%% directly to open_port, so workspace paths cannot become shell syntax.
run(Cwd, Args) ->
    case os:find_executable("git") of
        false ->
            {error, <<"git executable not found">>};
        Git ->
            Port = open_port(
                {spawn_executable, Git},
                [binary, exit_status, use_stdio, stderr_to_stdout, hide,
                 {cd, binary_to_list(Cwd)},
                 {args, [binary_to_list(Arg) || Arg <- Args]}]
            ),
            collect(Port, [], 0)
    end.

collect(Port, Chunks, Size) ->
    receive
        {Port, {data, Data}} ->
            NextSize = Size + byte_size(Data),
            case NextSize > ?MAX_OUTPUT of
                true ->
                    catch port_close(Port),
                    {error, <<"git output exceeds the 5 MB display limit">>};
                false ->
                    collect(Port, [Data | Chunks], NextSize)
            end;
        {Port, {exit_status, Code}} ->
            {ok, {Code, iolist_to_binary(lists:reverse(Chunks))}}
    after ?TIMEOUT_MS ->
        catch port_close(Port),
        {error, <<"git command timed out">>}
    end.
