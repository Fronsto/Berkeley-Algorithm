% some dynamic variables to be used in this program
:- dynamic leader_info/2.
:- dynamic time_vals/1.
:- dynamic leader_timestamp/1.
:- dynamic msgers/1.
:- dynamic msger_time_value/2.

% -------------------------------------------- %
% Platform information
% -------------------------------------------- %

% We hardcoded the platform information here, and the path taken by the leader agent.
:- dynamic all_platforms/2.
all_platforms(guid, [(localhost, 6001), (localhost, 6002), (localhost, 6003), (localhost, 6004), (localhost, 6005)]).

:- dynamic jump_from_to/3.
jump_from_to(guid, (localhost, 6001), (localhost, 6002)).
jump_from_to(guid, (localhost, 6002), (localhost, 6003)).
jump_from_to(guid, (localhost, 6003), (localhost, 6004)).
jump_from_to(guid, (localhost, 6004), (localhost, 6005)).
jump_from_to(guid, (localhost, 6005), (localhost, 6001)).

% keep track of number of iterations 
:- dynamic iteration/2.
iteration(guid, 0).

%------------------------------------------------------------%
%    code to compute the average time from a given list
%------------------------------------------------------------%
count(0, []).
count(Count, [_|Tail]) :- count(TailCount, Tail), Count is TailCount + 1.
sum(0, []).
sum(Total, [Head|Tail]) :- sum(Sum, Tail), Total is Head + Sum.
average(Average, List) :- sum(Sum, List), count(Count, List), Average is Sum/Count.

%------------------------------------------------------------%
% Code to handle time adjustment values
%------------------------------------------------------------%
% instantiate time
:- dynamic cur_time/1.
cur_time(90).

% sets time to a new value
set_time(T) :- 
    retract(cur_time(_)),
    assert(cur_time(T)),
    write("Time is "), writeln(T).

% drifts time by a random amount
drift_time:-
    get_time(T),
    T1 is T + 10 + random(5),
    set_time(T1).

% gets current time
get_time(T) :- 
    cur_time(T).

% change time by a fixed offset
set_time_offset(T_offset) :-
    get_time(T),
    T1 is T + T_offset,
    set_time(T1).

% initially we randomize time value.
?- drift_time.

%------------------------------------------------------------%
%   code to send time adjustment values to other platforms
%------------------------------------------------------------%

:- dynamic msger_handler2/3.
msger_handler2(guid, (_, _), main) :-
    msger_time_value(guid, TimeAdj),
    set_time_offset(TimeAdj), % correct the clock
    sleep(1), % wait a while
    writeln("Randomly incrementing time..."),
    drift_time, % increment time by a random amount
    purge_agent(guid). % kill itself.

% send time adjustment value to all platforms
:- dynamic send_time_adjustment/2.
send_time_adjustment( Average, (AgentZ, (IP, Port))) :-
    msger_time_value(AgentZ, Time), % Time recorded by the messenger of that platform
    TimeAdj is Average - Time, % destination platform will add this amount to its clock

    write("Sending time adjustment value of "), write(TimeAdj), write(" to platform: "), writeln(Port),

    leader_info(AgentZ, (L_IP, L_Port)),
    purge_agent(AgentZ), % kill this agent
    gensym(AgentZ, AgentP), % generate another, (with a diff handler) this will carry the TimeAdj value
    retractall(msger_time_value(AgentP, _)), assertz(msger_time_value(AgentP, TimeAdj)),

    % create the agent and send it to the destination platform with the TimeAdj value
    create_mobile_agent(AgentP, (L_IP, L_Port), msger_handler2, [11, 12, 13, 14, 15]),
    add_payload(AgentP, [(msger_time_value, 2)]),
    move_agent(AgentP, (IP, Port))
    .
%------------------------------------------------------------%
% check if all messengers have returned with their time values
% if yes then compute average, call send_time_adjustment, and move leader to the next platform.
%------------------------------------------------------------%
:- dynamic chk_time_and_call_send_adj/0.
chk_time_and_call_send_adj:-
    time_vals(TV), length(TV, Len1),
    all_platforms(leader, A), length(A, Len2),
    ( Len1 =:= Len2 -> 
        writeln("All messengers have returned with their time values."),
        average(Average, TV),
        write("Average time is: "), writeln(Average),
        
        % change time of current platform
        leader_timestamp(MyTime), T is Average - MyTime, set_time_offset(T), 
        write(T), writeln(" is the time offset for this platform."),
        % send time adjustment value to all other platforms
        msgers(M), maplist(send_time_adjustment(Average), M),

        % move leader to the next platform
        sleep(5), 
        platform_Ip(IP), platform_port(Port),
        jump_from_to(leader, (IP, Port), (NextIP, NextPort)),
        iteration(leader, Iter),
        ( Iter =:= 5 ->
            writeln("5 iterations done, ending execution."),
            purge_agent(leader)
            ;
            writeln("Work done, Jumping to the next platform..."),
            move_agent(leader, (NextIP, NextPort))
        )
        ;
        true
    ).

%------------------------------------------------------------%
% create messenger agents with random names and make them move to the given platform
% there the messenger handler executes and takes on the execution
%------------------------------------------------------------%
:- dynamic msger_handler/3.
msger_handler(guid, (IP, Port), main) :-
    leader_info(guid, (L_IP, L_Port)),
    ( (IP = L_IP, Port = L_Port) ->
        msger_time_value(guid, Time),

        % Updating time values needs to be ATOMIC, since agent execution in tartarus is multi-threaded
        mutex_lock(time_vals_mutex),
        time_vals(TV), retractall(time_vals(_)), assertz(time_vals([Time|TV])), % insert in list
        mutex_unlock(time_vals_mutex),

        chk_time_and_call_send_adj  % check if all messengers have returned with their time values
        ;
        % get time value and move back to the leader platform
        get_time(Time), retractall(msger_time_value(guid, _)), assertz(msger_time_value(guid, Time)),
        move_agent(guid, (L_IP, L_Port))
    ) 
    .

% Dispatch messenger agents to the given platform

:- dynamic dispatch_messengers/2.
% if the messenger is on the same platform as the leader, then it just records its time value
dispatch_messengers((IP, Port), (IP, Port)) :-

    % Updating time values needs to be ATOMIC, since agent execution in tartarus is multi-threaded
    mutex_lock(time_vals_mutex),
    get_time(Time), time_vals(TV), retractall(time_vals(_)), assertz(time_vals([Time|TV])),
    mutex_unlock(time_vals_mutex),

    retractall(leader_timestamp(_)), assertz(leader_timestamp(Time)),
    chk_time_and_call_send_adj. % check if the list is populated with all time values

% if not, then create a new messenger agent and move it to the given platform
dispatch_messengers((L_IP, L_Port), (IP, Port)) :-

    gensym(msger, AgentZ), % get a random name for this agent
    msgers(A), retractall(msgers(_)), assertz(msgers([(AgentZ, (IP, Port))|A])), % save this info

    write("Dispatching Agent "), write(AgentZ), write(" to platform: "), writeln(Port), 

    create_mobile_agent(AgentZ, (L_IP, L_Port), msger_handler, [11, 12, 13, 14, 15]),
    retractall(leader_info(AgentZ, _)), assertz(leader_info(AgentZ, (L_IP, L_Port))),
    add_payload(AgentZ, [(leader_info, 2)]), % need to have leader info to return back here
    add_payload(AgentZ, [(msger_time_value, 2)]), 
    move_agent(AgentZ, (IP, Port)) .

%------------------------------------------------------------%
%  leader agent 
%------------------------------------------------------------%
% defining the leader_handler - the main function of the leader agent
    % it dispatches messengers to all other platforms and when 
    % all messengers have returned their time values, the chk_time function
    % computes the average time and makes call to send_time_adjustment 
:- dynamic leader_handler/3.
leader_handler(guid,(IP, Port),main):-
    % setting variables
    iteration(guid, Iter), retractall(iteration(guid, _)), assertz(iteration(guid, Iter+1)),
    retractall(time_vals(_)), assertz(time_vals([])),
    retractall(msgers(_)), assertz(msgers([])),

    % helpful print statements
    writeln("Leader agent here."),
    writeln("Polling other platforms..."),

    % dispatch messengers to all other platforms
    all_platforms(guid, AllPlatforms),
    maplist(dispatch_messengers((IP, Port)), AllPlatforms).


% -------------------------------------------- %
% Start Berkeley - create leader agent and start execution
% -------------------------------------------- %

start_berkeley:-
    platform_Ip(IP), platform_port(Port),
    create_mobile_agent(leader, (IP, Port), leader_handler, [11, 12, 13, 14, 15]),
    add_payload(leader, [(all_platforms, 2)]),
    add_payload(leader, [(jump_from_to, 3)]),
    add_payload(leader, [(iteration, 2)]),
    execute_agent(leader, (IP, Port), leader_handler).