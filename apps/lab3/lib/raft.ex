defmodule Raft do
  @moduledoc """
  An implementation of the Raft consensus protocol.
  """
  # Shouldn't need to spawn anything from this module, but if you do
  # you should add spawn to the imports.
  import Emulation, only: [send: 2, cancel_timer: 1, timer: 1, now: 0, whoami: 0]

  import Kernel,
    except: [spawn: 3, spawn: 1, spawn_link: 1, spawn_link: 3, send: 2]

  require Fuzzers
  # This allows you to use Elixir's loggers
  # for messages. See
  # https://timber.io/blog/the-ultimate-guide-to-logging-in-elixir/
  # if you are interested in this. Note we currently purge all logs
  # below Info
  require Logger

  # This structure contains all the process state
  # required by the Raft protocol.
  defstruct(
    # The list of current proceses.
    view: nil,
    # Current leader.
    current_leader: nil,
    # Time before starting an election.
    min_election_timeout: nil,
    max_election_timeout: nil,
    election_timer: nil,
    # Time between heartbeats from the leader.
    heartbeat_timeout: nil,
    heartbeat_timer: nil,
    # Persistent state on all servers.
    current_term: nil,
    voted_for: nil,
    # A short note on log structure: The functions that follow
    # (e.g., get_last_log_index, commit_log_index, etc.) all
    # assume that the log is a list with later entries (i.e.,
    # entries with higher index numbers) appearing closer to
    # the head of the list, and that index numbers start with 1.
    # For example if the log contains 3 entries committe in term
    # 2, 2, and 1 we would expect:
    #
    # `[{index: 3, term: 2, ..}, {index: 2, term: 2, ..},
    #     {index: 1, term: 1}]`
    #
    # If you change this structure, you will need to change
    # those functions.
    #
    # Finally, it might help to know that two lists can be
    # concatenated using `l1 ++ l2`
    log: nil,
    # Volatile state on all servers
    commit_index: nil,
    last_applied: nil,
    # Volatile state on leader
    is_leader: nil,
    next_index: nil,
    match_index: nil,
    # The queue we are building using this RSM.
    queue: nil
  )

  @doc """
  Create state for an initial Raft cluster. Each
  process should get an appropriately updated version
  of this state.
  """
  @spec new_configuration(
          [atom()],
          atom(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: %Raft{}
  def new_configuration(
        view,
        leader,
        min_election_timeout,
        max_election_timeout,
        heartbeat_timeout
      ) do
    %Raft{
      view: view,
      current_leader: leader,
      min_election_timeout: min_election_timeout,
      max_election_timeout: max_election_timeout,
      heartbeat_timeout: heartbeat_timeout,
      # Start from term 1
      current_term: 1,
      voted_for: nil,
      log: [],
      commit_index: 0,
      last_applied: 0,
      is_leader: false,
      next_index: nil,
      match_index: nil,
      queue: :queue.new()
    }
  end

  # Enqueue an item, this **modifies** the state
  # machine, and should only be called when a log
  # entry is committed.
  @spec enqueue(%Raft{}, any()) :: %Raft{}
  defp enqueue(state, item) do
    %{state | queue: :queue.in(item, state.queue)}
  end

  # Dequeue an item, modifying the state machine.
  # This function should only be called once a
  # log entry has been committed.
  @spec dequeue(%Raft{}) :: {:empty | {:value, any()}, %Raft{}}
  defp dequeue(state) do
    {ret, queue} = :queue.out(state.queue)
    {ret, %{state | queue: queue}}
  end

  @doc """
  Commit a log entry, advancing the state machine. This
  function returns a tuple:
  * The first element is {requester, return value}. Your
    implementation should ensure that the leader who committed
    the log entry sends the return value to the requester.
  * The second element is the updated state.
  """
  @spec commit_log_entry(%Raft{}, %Raft.LogEntry{}) ::
          {{atom() | pid(), :ok | :empty | {:value, any()}}, %Raft{}}
  def commit_log_entry(state, entry) do
    case entry do
      %Raft.LogEntry{operation: :nop, requester: r, index: i} ->
        {{r, :ok}, %{state | commit_index: i}}

      %Raft.LogEntry{operation: :enq, requester: r, argument: e, index: i} ->
        {{r, :ok}, %{enqueue(state, e) | commit_index: i}}

      %Raft.LogEntry{operation: :deq, requester: r, index: i} ->
        {ret, state} = dequeue(state)
        {{r, ret}, %{state | commit_index: i}}

      %Raft.LogEntry{} ->
        raise "Log entry with an unknown operation: maybe an empty entry?"

      _ ->
        raise "Attempted to commit something that is not a log entry."
    end
  end

  @doc """
  Commit log at index `index`. This index, which one should read from
  the log entry is assumed to start at 1. This function **does not**
  ensure that commits are processed in order.
  """
  @spec commit_log_index(%Raft{}, non_neg_integer()) ::
          {:noentry | {atom(), :ok | :empty | {:value, any()}}, %Raft{}}
  def commit_log_index(state, index) do

    if length(state.log) < index do
      {:noentry, state}
    else
      # Note that entry indexes are all 1, which in
      # turn means that we expect commit indexes to
      # be 1 indexed. Now a list is a reversed log,
      # so what we can do here is simple:
      # Given 0-indexed index i, length(log) - 1 - i
      # is the ith list element. => length(log) - (i +1),
      # and hence length(log) - index is what we want.
      correct_idx = length(state.log) - index
      commit_log_entry(state, Enum.at(state.log, correct_idx))
    end
  end

  # The next few functions are public so we can test them, see
  # log_test.exs.
  @doc """
  Get index for the last log entry.
  """
  @spec get_last_log_index(%Raft{}) :: non_neg_integer()
  def get_last_log_index(state) do
    Enum.at(state.log, 0, Raft.LogEntry.empty()).index
  end

  @doc """
  Get term for the last log entry.
  """
  @spec get_last_log_term(%Raft{}) :: non_neg_integer()
  def get_last_log_term(state) do
    Enum.at(state.log, 0, Raft.LogEntry.empty()).term
  end

  @doc """
  Check if log entry at index exists.
  """
  @spec logged?(%Raft{}, non_neg_integer()) :: boolean()
  def logged?(state, index) do
    index > 0 && length(state.log) >= index
  end

  @doc """
  Get log entry at `index`.
  """
  @spec get_log_entry(%Raft{}, non_neg_integer()) ::
          :no_entry | %Raft.LogEntry{}
  def get_log_entry(state, index) do
    if index <= 0 || length(state.log) < index do
      :noentry
    else
      # Note that entry indexes are all 1, which in
      # turn means that we expect commit indexes to
      # be 1 indexed. Now a list is a reversed log,
      # so what we can do here is simple:
      # Given 0-indexed index i, length(log) - 1 - i
      # is the ith list element. => length(log) - (i +1),
      # and hence length(log) - index is what we want.
      correct_idx = length(state.log) - index
      Enum.at(state.log, correct_idx)
    end
  end

  @doc """
  Get log entries starting at index.
  """
  @spec get_log_suffix(%Raft{}, non_neg_integer()) :: [%Raft.LogEntry{}]
  def get_log_suffix(state, index) do
    if length(state.log) < index do
      []
    else
      correct_idx = length(state.log) - index
      Enum.take(state.log, correct_idx + 1)
    end
  end

  @doc """
  Truncate log entry at `index`. This removes log entry
  with index `index` and larger.
  """
  @spec truncate_log_at_index(%Raft{}, non_neg_integer()) :: %Raft{}
  def truncate_log_at_index(state, index) do
    if length(state.log) < index do
      # Nothing to do
      state
    else
      to_drop = length(state.log) - index + 1
      %{state | log: Enum.drop(state.log, to_drop)}
    end
  end

  @doc """
  Add log entries to the log. This adds entries to the beginning
  of the log, we assume that entries are already correctly ordered
  (see structural note about log above.).
  """
  @spec add_log_entries(%Raft{}, [%Raft.LogEntry{}]) :: %Raft{}
  def add_log_entries(state, entries) do
    %{state | log: entries ++ state.log}
  end

  @doc """
  make_leader changes process state for a process that
  has just been elected leader.
  """
  @spec make_leader(%Raft{}) :: %Raft{
          is_leader: true,
          next_index: map(),
          match_index: map()
        }
  def make_leader(state) do
    log_index = get_last_log_index(state)

    # next_index needs to be reinitialized after each
    # election.
    next_index =
      state.view
      |> Enum.map(fn v -> {v, log_index} end)
      |> Map.new()

    # match_index needs to be reinitialized after each
    # election.
    match_index =
      state.view
      |> Enum.map(fn v -> {v, 0} end)
      |> Map.new()

    %{
      state
      | is_leader: true,
        next_index: next_index,
        match_index: match_index,
        current_leader: whoami()
    }
  end

  @doc """
  make_follower changes process state for a process
  to mark it as a follower.
  """
  @spec make_follower(%Raft{}) :: %Raft{
          is_leader: false
        }
  def make_follower(state) do
    %{state | is_leader: false}
  end

  # update_leader: update the process state with the
  # current leader.
  @spec update_leader(%Raft{}, atom()) :: %Raft{current_leader: atom()}
  defp update_leader(state, who) do
    %{state | current_leader: who}
  end

  # Compute a random election timeout between
  # state.min_election_timeout and state.max_election_timeout.
  # See the paper to understand the reasoning behind having
  # a randomized election timeout.
  @spec get_election_time(%Raft{}) :: non_neg_integer()
  defp get_election_time(state) do
    state.min_election_timeout +
      :rand.uniform(
        state.max_election_timeout -
          state.min_election_timeout
      )
  end

  # Save a handle to the election timer.
  @spec save_election_timer(%Raft{}, reference()) :: %Raft{}
  defp save_election_timer(state, timer) do
    %{state | election_timer: timer}
  end

  # Save a handle to the hearbeat timer.
  @spec save_heartbeat_timer(%Raft{}, reference()) :: %Raft{}
  defp save_heartbeat_timer(state, timer) do
    %{state | heartbeat_timer: timer}
  end

  # Utility function to send a message to all
  # processes other than the caller. Should only be used by leader.
  @spec broadcast_to_others(%Raft{is_leader: true}, any()) :: [boolean()]
  defp broadcast_to_others(state, message) do
    me = whoami()

    state.view
    |> Enum.filter(fn pid -> pid != me end)
    |> Enum.map(fn pid -> send(pid, message) end)
  end

  # END OF UTILITY FUNCTIONS. You should not need to (but are allowed to)
  # change any of the code above this line, but will definitely need to
  # change the code that follows.

  # This function should cancel the current
  # election timer, and set  a new one. You can use
  # `get_election_time` defined above to get a
  # randomized election timeout. You might need
  # to call this function from within your code.
  @spec reset_election_timer(%Raft{}) :: %Raft{}
  defp reset_election_timer(state) do
    # TODO: Set a new election timer
    # You might find `save_election_timer` of use.
    newTime = get_election_time(state)
    if state.election_timer != nil do
      cancel_timer(state.election_timer)
    end
    save_election_timer(state, timer(newTime))


  end

  # This function should cancel the current
  # hearbeat timer, and set  a new one. You can
  # get heartbeat timeout from `state.heartbeat_timeout`.
  # You might need to call this from your code.
  @spec reset_heartbeat_timer(%Raft{}) :: %Raft{}
  defp reset_heartbeat_timer(state) do
    # TODO: Set a new heartbeat timer.
    if state.heartbeat_timer != nil do
      cancel_timer(state.heartbeat_timer)
    end
    save_heartbeat_timer(state, timer(state.heartbeat_timeout))
    # You might find `save_heartbeat_timer` of use.

  end

  @doc """
  This function transitions a process so it is
  a follower.
  """
  @spec become_follower(%Raft{}) :: no_return()
  def become_follower(state) do
    # TODO: Do anything you need to when a process
    # transitions to a follower.
    # reset_heartbeat_timer(state)
    state = %{state | is_leader: false}

    cond do
      state.heartbeat_timer != nil ->
      cancel_timer(state.heartbeat_timer)
      state = reset_election_timer(state)
      state = %{state | heartbeat_timer: nil}
      follower(make_follower(state), nil)

      true ->
        state = reset_election_timer(state)
      state = %{state | heartbeat_timer: nil}
      follower(make_follower(state), nil)

    end

    # state = %{state | log: []}
    state = reset_election_timer(state)
    state = %{state | heartbeat_timer: nil}
    follower(make_follower(state), nil)

  end


  #return matched mylog
  # def getLeaderLogSuffix(leaderLog, myLog, prevLogIndex) do
  #   IO.inspect(leaderLog)
  #   IO.inspect(prevLogIndex)
  #   if length(leaderLog) < prevLogIndex do
  #     myLog
  #   else
  #     correct_index = length(leaderLog) - prevLogIndex
  #     tempLog = Enum.take(leaderLog, correct_index + 1)

  #     myLog =
  #     if length(myLog) < prevLogIndex + 1 do
  #       tempLog ++ myLog
  #     else
  #       drop = length(myLog) - prevLogIndex + 1
  #       tempLog ++ Enum.drop(myLog, drop)
  #     end
  #     IO.inspect(myLog)
  #     myLog

  #   end
  # end

  # def getLeaderLogSuffix(entries, state, term) do
  #   case entries do
  #     [] -> state
  #     [head | tail] ->
  #       if get_log_entry(state,head.index)!=:noentry && get_log_entry(state,head.index).term != term do
  #         state = truncate_log_at_index(state,head.index)
  #         getLeaderLogSuffix(tail, state, term)
  #       else
  #         getLeaderLogSuffix(tail, state, term)
  #       end
  #   end
  # end

  def getLeaderLogSuffix(entries, state) do
    firstEntryIndex = Enum.at(entries, 0).index
    state = truncate_log_at_index(state, firstEntryIndex)
    state = %{state | log: entries ++ state.log}
    state
  end


  @doc """
  This function implements the state machine for a process
  that is currently a follower.

  `extra_state` can be used to hod anything that you find convenient
  when building your implementation.
  """
  @spec follower(%Raft{is_leader: false}, any()) :: no_return()
  def follower(state, extra_state) do
    receive do
      # receive timer, then into election
      :timeout ->
        IO.puts(
          "trans from follower to candidate#{whoami()} ")
        become_candidate(state)
      # Messages that are a part of Raft.
      {sender,
       %Raft.AppendEntryRequest{
         term: term,
         leader_id: leader_id,
         prev_log_index: prev_log_index,
         prev_log_term: prev_log_term,
         entries: entries,
         leader_commit_index: leader_commit_index
       }} ->
        # TODO: Handle an AppendEntryRequest received by a
        # follower
        IO.puts(
          "follower #{whoami()} Received append entry for term #{term} with leader #{leader_id} " <>
            "(#{leader_commit_index})"
        )
        #reset election timer
        state = reset_election_timer(state)
        state =
        if term > state.current_term do
          state = %{state | current_term: term}
          state = %{state | voted_for: nil}
          state
        else
          state
        end
        cond do
          entries == nil ->
            IO.puts("follow reject case 1")
            # IO.inspect(state)
            reset_heartbeat_timer(state)
            # IO.inspect(entries)
            state = %{state | current_leader: sender}
            follower(state, extra_state)

            term < state.current_term or (get_log_entry(state,prev_log_index) != :noentry && get_log_entry(state,prev_log_index).term != prev_log_term) ->
            IO.puts("follow reject case 2 and 3")
            send(leader_id, %Raft.AppendEntryResponse{
              term: term,
              log_index: prev_log_index,
              success: false
            })
            follower(state, extra_state)
          #2
          # get_log_entry(state,prev_log_index) != :noentry && get_log_entry(state, prev_log_index) != prev_log_term ->
          #   IO.puts("follow reject case 3")
          #   send(leader_id, %Raft.AppendEntryResponse{
          #     term: term,
          #     log_index: prev_log_index,
          #     success: false
          #   })
          #   follower(state, extra_state)
          #3 if prevlogindex matches, then just concat everything from
          # leader log to my log
          true ->
          # agg it
          # IO.inspect("ll bugg")
          # IO.inspect(state.log)
          # IO.inspect(entries)
          # IO.inspect("updated loggs")
          state = getLeaderLogSuffix(entries, state)
          # IO.inspect(state.log)
          # state = add_log_entries(state,entries)
          # state = %{state | log: getLeaderLogSuffix(entries,state.log,prev_log_index)}
          IO.puts("good to send back")
          # IO.inspect(state.log)
          # IO.inspect(entries)
          state =
          if leader_commit_index > state.commit_index do
            %{state | commit_index: Enum.min([leader_commit_index,
            Enum.at(entries, 0, Raft.LogEntry.empty()).index])}
          else
            state
          end
          res = commit_log_index(state, state.commit_index+1)

          # state =
          # if term > state.current_term do
          #   %{state | current_term: term}
          # else
          #   state
          # end
          # state =
          case res do
            {:noentry, newState} -> follower(newState, extra_state)

            {{a, b}, newState} ->
              send(leader_id, %Raft.AppendEntryResponse{
                term: term,
                log_index: get_last_log_index(state),
                success: true
              })
              follower(newState, extra_state)
          end

          # send(leader_id, %Raft.AppendEntryResponse{
          #   term: state.current_term,
          #   log_index: get_last_log_index(state),
          #   success: true
          # })
          # follower(state, extra_state)
        end



      {sender,
       %Raft.AppendEntryResponse{
         term: term,
         log_index: index,
         success: succ
       }} ->
        # TODO: Handle an AppendEntryResponse received by
        # a follower.
        IO.puts(
          "Follower received append entry response #{term}," <>
            " index #{index}, succcess #{inspect(succ)}"
        )
        if term > state.current_term do
          state = %{state | current_term: term}
          state = %{state | voted_for: nil}
          follower(state, extra_state)
        end
        follower(state, extra_state)

      {sender,
       %Raft.RequestVote{
         term: term,
         candidate_id: candidate,
         last_log_index: last_log_index,
         last_log_term: last_log_term
       }} ->
        # TODO: Handle a RequestVote call received by a
        # follower.
        IO.puts(
          "Follower #{whoami()} received RequestVote " <>
            "term = #{term}, candidate = #{candidate}"
        )
        state_last_index = get_last_log_index(state)

#           If the logs have last entries with different terms, then
# the log with the later term is more up-to-date. If the logs
# end with the same term, then whichever log is longer is
# more up-to-date.
            # later term win case
        cond do
          term >= state.current_term && (state.voted_for == nil || state.voted_for == candidate) && get_last_log_term(state) < last_log_term ->
            send(sender, %Raft.RequestVoteResponse{
              term: term,
              granted: true
            } )
            state = %{state | current_term: term}
            state = %{state | voted_for: candidate}
            follower(state, extra_state)
          # term equal, then larger index win
          term >= state.current_term && (state.voted_for == nil || state.voted_for == candidate) && get_last_log_term(state) == last_log_term && state_last_index <= last_log_index ->
            send(sender, %Raft.RequestVoteResponse{
              term: term,
              granted: true
            } )
            state = %{state | voted_for: candidate}
            state = %{state | current_term: term}
            follower(state, extra_state)

          true ->
            send(sender, %Raft.RequestVoteResponse{
              term: state.current_term,
              granted: false
            } )
            state = %{state | current_term: term}
            follower(state, extra_state)
        end

      {sender,
       %Raft.RequestVoteResponse{
         term: term,
         granted: granted
       }} ->
        # TODO: Handle a RequestVoteResponse.
        IO.puts(
          "Follower #{whoami()} received RequestVoteResponse " <>
            "term = #{term}, granted = #{inspect(granted)}"
        )
        if term > state.current_term do
          state = %{state | current_term: term}
          state = %{state | voted_for: nil}
          follower(state, extra_state)
        end
        follower(state, extra_state)
        # raise "Not yet implemented"

      # Messages from external clients. In each case we
      # tell the client that it should go talk to the
      # leader.
      {sender, :nop} ->
        send(sender, {:redirect, state.current_leader})
        follower(state, extra_state)

      {sender, {:enq, item}} ->
        send(sender, {:redirect, state.current_leader})
        follower(state, extra_state)

      {sender, :deq} ->
        send(sender, {:redirect, state.current_leader})
        follower(state, extra_state)

      # Messages for debugging [Do not modify existing ones,
      # but feel free to add new ones.]
      {sender, :send_state} ->
        send(sender, state.queue)
        follower(state, extra_state)

      {sender, :send_log} ->
        send(sender, state.log)
        follower(state, extra_state)

      {sender, :whois_leader} ->
        send(sender, {state.current_leader, state.current_term})
        follower(state, extra_state)

      {sender, :current_process_type} ->
        send(sender, :follower)
        follower(state, extra_state)

      {sender, {:set_election_timeout, min, max}} ->
        state = %{state | min_election_timeout: min, max_election_timeout: max}
        state = reset_election_timer(state)
        send(sender, :ok)
        follower(state, extra_state)

      {sender, {:set_heartbeat_timeout, timeout}} ->
        send(sender, :ok)
        follower(%{state | heartbeat_timeout: timeout}, extra_state)
    end
  end

  @doc """
  This function transitions a process that is not currently
  the leader so it is a leader.
  """
  @spec become_leader(%Raft{is_leader: false}) :: no_return()
  def become_leader(state) do
    # TODO: Send out any one time messages that need to be sent,
    # you might need to update the call to leader too.
    state = %{state | current_leader: whoami()}
    cond do
      state.election_timer != nil ->
        cancel_timer(state.election_timer)
        state = reset_heartbeat_timer(state)
        state = %{state | election_timer: nil}

        extra_state = %{"clientRequest" => %{}}
        # set leader
        broadcast_to_others(state,%Raft.AppendEntryRequest{
          term: state.current_term,
          leader_id: state.current_leader,
          prev_log_index: get_last_log_index(state),
          prev_log_term: get_last_log_term(state),
          entries: nil,
          leader_commit_index: state.commit_index
        })
        leader(make_leader(state), extra_state)
      true ->
        state = reset_heartbeat_timer(state)
        state = %{state | election_timer: nil}
        extra_state = %{"clientRequest" => %{}}
        # set leader
        broadcast_to_others(state,%Raft.AppendEntryRequest{
          term: state.current_term,
          leader_id: state.current_leader,
          prev_log_index: get_last_log_index(state),
          prev_log_term: get_last_log_term(state),
          entries: nil,
          leader_commit_index: state.commit_index
        })
        leader(make_leader(state), extra_state)
    end


  end

  @doc """
  This function implements the state machine for a process
  that is currently the leader.

  `extra_state` can be used to hold any additional information.
  HINT: It might be useful to track the number of responses
  received for each AppendEntry request.
  """
  @spec leader(%Raft{is_leader: true}, any()) :: no_return()
  def leader(state, extra_state) do
    baseMsg = %Raft.AppendEntryRequest{
      term: state.current_term,
      leader_id: state.current_leader,
      prev_log_index: get_last_log_index(state),
      prev_log_term: get_last_log_term(state),
      entries: [],
      leader_commit_index: state.commit_index
    }
    # msg = %Raft.AppendEntryRequest{
    #   term: state.current_term,
    #   leader_id: state.current_leader,
    #   prev_log_index: get_last_log_index(state),
    #   prev_log_term: get_last_log_term(state),
    #   entries: nil,
    #   leader_commit_index: state.commit_index
    # }
    # broadcast_to_others(state, msg)
    # IO.inspect(state)
    # state =
    # if state.commit_index > state.last_applied do

    #   IO.puts("last applied #{state.last_applied + 1}")
    #   next = state.last_applied + 1
    #   {{a, b}, state} = commit_log_index(state, next)

    #   state = %{state | last_applied: next}

    # else
    #   state
    # end

    IO.puts("i am leader #{whoami()} just started with #{get_last_log_index(state)}")
    # me = whoami()
    # lastLogIndex = get_last_log_index(state)
    # if state.log != nil && state.log != [] do
    # IO.inspect(state)
    # IO.puts("sending")
    # state.view
    # |> Enum.filter(fn pid -> pid != me end)
    # |> Enum.map(fn pid ->
    #               if lastLogIndex >= state.next_index[pid] do
    #                 msg = %{msg |
    #                 entries: get_log_suffix(state, state.next_index[pid]),
    #                 prev_log_index: state.match_index[pid]
    #                 }
    #                 send(pid, msg)
    #               end
    #             end)
    # end
    receive do
      # Messages that are a part of Raft.
      :timeout ->
        broadcast_to_others(state,%Raft.AppendEntryRequest{
          term: state.current_term,
          leader_id: state.current_leader,
          prev_log_index: get_last_log_index(state),
          prev_log_term: get_last_log_term(state),
          entries: nil,
          leader_commit_index: state.commit_index
        })
        leader(state, extra_state)

      {sender,
       %Raft.AppendEntryRequest{
         term: term,
         leader_id: leader_id,
         prev_log_index: prev_log_index,
         prev_log_term: prev_log_term,
         entries: entries,
         leader_commit_index: leader_commit_index
       }} ->
        # TODO: Handle an AppendEntryRequest seen by the leader.
        IO.puts(
          "Leader #{whoami()} Received append entry for term #{term} with leader #{
            leader_id
          } " <>
            "(#{leader_commit_index})"
        )
        IO.puts("i am receving a rpc from #{leader_id} and my term is
        #{state.current_term} and his term is #{term}")
        if term > state.current_term do
          state = %{state | current_term: term}
          state = %{state | voted_for: nil}
          state = %{state | current_leader: sender}
          become_follower(state)
        end

        leader(state, extra_state)


      {sender,
       %Raft.AppendEntryResponse{
         term: term,
         log_index: index,
         success: succ
       }} ->
        # TODO: Handle an AppendEntryResposne received by the leader.
        IO.puts(
          "Received append entry response #{term}," <>
            " index #{index}, succcess #{succ}"
        )

        cond do
          # if term is bigger , turn into follower
          term > state.current_term ->
            state = %{state | current_term: term}
            state = %{state | voted_for: nil}
            # to do here we just make leader be the rpc's?
            state = %{state | current_leader: sender}
            become_follower(state)

          # to do
          succ == false ->
          state = %{state | next_index:
          Map.put(state.next_index, sender,state.next_index[sender]-1)}
          leader(state, extra_state)
          msg = %Raft.AppendEntryRequest{
            term: state.current_term,
            leader_id: state.current_leader,
            prev_log_index: get_last_log_index(state),
            prev_log_term: get_last_log_term(state),
            entries: get_log_suffix(state, index),
            leader_commit_index: state.commit_index
          }
          send(sender, msg)
          leader(state, extra_state)

          succ == true ->

          state = %{state | next_index:
          Map.put(state.next_index, sender,index ),
          match_index: Map.put(state.match_index, sender,state.match_index[sender]+1)}

          IO.puts("this means i got a true return,
          receive index: #{index} , current commit: #{state.commit_index}")

          # IO.inspect(extra_state)
          # IO.inspect(index)
          extra_state = Map.put(extra_state, "clientRequest", Map.put(extra_state["clientRequest"],
          index , extra_state["clientRequest"][index]+1))


          if index > state.commit_index &&
          extra_state["clientRequest"][index] >= length(state.view)/2+1
          && get_log_entry(state, index).term == state.current_term
          do
          # todo aggregate the following into one condition
          res = commit_log_index(state, index)
          # IO.puts("point")
          case res do
            {{a,b}, returnState} ->
              send(a, b)
              # IO.puts("backbackbackbackbackbackbackback")
              leader(returnState, extra_state)
            {_, returnState} ->
              # IO.puts("othersothersothersothers")
              leader(returnState, extra_state)

          end
          else
            leader(state, extra_state)
          end


        end

      {sender,
       %Raft.RequestVote{
         term: term,
         candidate_id: candidate,
         last_log_index: last_log_index,
         last_log_term: last_log_term
       }} ->
        # TODO: Handle a RequestVote call at the leader.
        IO.puts(
          "Leader #{whoami()} received RequestVote " <>
            "term = #{term}, candidate = #{candidate}"
        )
        state_last_index = get_last_log_index(state)
        cond do
          #send vote and become_follower
          term > state.current_term ->
            # change to nil so can decide, since we are voting for bigger term
            state = %{state | voted_for: nil}
            IO.puts(
                  "Leader #{whoami()} transfer to follower"
                )
            cond do
              term >= state.current_term && (state.voted_for == nil || state.voted_for == candidate) && get_last_log_term(state) < last_log_term ->
                send(sender, %Raft.RequestVoteResponse{
                  term: term,
                  granted: true
                } )
                state = %{state | current_term: term}
                state = %{state | voted_for: candidate}
                become_follower(state)
              # term equal, then larger index win
              term >= state.current_term && (state.voted_for == nil || state.voted_for == candidate) && get_last_log_term(state) == last_log_term && state_last_index <= last_log_index ->
                send(sender, %Raft.RequestVoteResponse{
                  term: term,
                  granted: true
                } )
                state = %{state | current_term: term}
                state = %{state | voted_for: candidate}
                become_follower(state)

              true ->
                send(sender, %Raft.RequestVoteResponse{
                  term: state.current_term,
                  granted: false
                } )
                state = %{state | current_term: term}
                state = %{state | voted_for: nil}
                become_follower(state)
            end

          true -> send(sender, %Raft.RequestVoteResponse{
            term: state.current_term,
            granted: false
          })

        end

        # leader(state, extra_state)

      {sender,
       %Raft.RequestVoteResponse{
         term: term,
         granted: granted
       }} ->
        # TODO: Handle RequestVoteResponse at a leader.
        IO.puts(
          "Leader #{whoami()} received RequestVoteResponse " <>
            "term = #{term}, granted = #{inspect(granted)}"
        )
        if term > state.current_term do
          state = %{state | current_term: term}
          state = %{state | voted_for: nil}
          state = %{state | current_leader: nil}
          become_follower(state)
        end
        leader(state, extra_state)

      # Messages from external clients. For all of what follows
      # you should send the `sender` an :ok (see `Raft.Client`
      # below) only after the request has completed, i.e., after
      # the log entry corresponding to the request has been **committed**.
      {sender, :nop} ->
        # TODO: entry is the log entry that you need to
        # append.
        entry =
          Raft.LogEntry.nop(
            get_last_log_index(state) + 1,
            state.current_term,
            sender
          )
          broadcast_to_others(state,%Raft.AppendEntryRequest{
            term: state.current_term,
            leader_id: state.current_leader,
            prev_log_index: get_last_log_index(state),
            prev_log_term: get_last_log_term(state),
            entries: [entry],
            leader_commit_index: state.commit_index
          })
        state = add_log_entries(state, [entry])
        extra_state = Map.put(extra_state, "clientRequest", Map.put(extra_state["clientRequest"],
        get_last_log_index(state) , 1))




        # TODO: You might need to update the following call.
        leader(state, extra_state)

      {sender, {:enq, item}} ->
        # TODO: entry is the log entry that you need to
        # append.
        entry =
          Raft.LogEntry.enqueue(
            get_last_log_index(state) + 1,
            state.current_term,
            sender,
            item
          )
          broadcast_to_others(state,%Raft.AppendEntryRequest{
            term: state.current_term,
            leader_id: state.current_leader,
            prev_log_index: get_last_log_index(state),
            prev_log_term: get_last_log_term(state),
            entries: [entry],
            leader_commit_index: state.commit_index
          })
          state = add_log_entries(state, [entry])

          extra_state = Map.put(extra_state, "clientRequest", Map.put(extra_state["clientRequest"],
        get_last_log_index(state) , 1))
        # TODO: You might need to update the following call.
        leader(state, extra_state)

      {sender, :deq} ->
        # TODO: entry is the log entry that you need to
        # append.
        entry =
          Raft.LogEntry.dequeue(
            get_last_log_index(state) + 1,
            state.current_term,
            sender
          )
          broadcast_to_others(state,%Raft.AppendEntryRequest{
            term: state.current_term,
            leader_id: state.current_leader,
            prev_log_index: get_last_log_index(state),
            prev_log_term: get_last_log_term(state),
            entries: [entry],
            leader_commit_index: state.commit_index
          })
          state = add_log_entries(state, [entry])

          extra_state = Map.put(extra_state, "clientRequest", Map.put(extra_state["clientRequest"],
        get_last_log_index(state) , 1))
        # TODO: You might need to update the following call.
        leader(state, extra_state)

      # Messages for debugging [Do not modify existing ones,
      # but feel free to add new ones.]
      {sender, :send_state} ->
        send(sender, state.queue)
        leader(state, extra_state)

      {sender, :send_log} ->
        send(sender, state.log)
        leader(state, extra_state)

      {sender, :whois_leader} ->
        send(sender, {whoami(), state.current_term})
        leader(state, extra_state)

      {sender, :current_process_type} ->
        send(sender, :leader)
        leader(state, extra_state)

      {sender, {:set_election_timeout, min, max}} ->
        send(sender, :ok)

        leader(
          %{state | min_election_timeout: min, max_election_timeout: max},
          extra_state
        )

      {sender, {:set_heartbeat_timeout, timeout}} ->
        state = %{state | heartbeat_timeout: timeout}
        state = reset_heartbeat_timer(state)
        send(sender, :ok)
        leader(state, extra_state)
    end
  end

  @doc """
  This function transitions a process to candidate.
  """
  @spec become_candidate(%Raft{is_leader: false}) :: no_return()
  def become_candidate(state) do
    # TODO:   Send out any messages that need to be sent out
    # you might need to update the call to candidate below.

    # Increment currentTerm
    state = %{state | current_term: state.current_term + 1}
    # • Vote for self
    # q1. what if one p dead, still need n/1  +1 ?
    extra_state = %{"voteCount" => 1}
    state = %{state | voted_for: whoami()}
    # • Reset election timer
    state = reset_election_timer(state)
    # • Send RequestVote RPCs to all other servers
    broadcast_to_others(state,%Raft.RequestVote{
      term: state.current_term,
      candidate_id: whoami(),
      last_log_index: get_last_log_index(state),
      last_log_term: get_last_log_term(state)
    })
    candidate(state, extra_state)
  end

  @doc """
  This function implements the state machine for a process
  that is currently a candidate.

  `extra_state` can be used to store any additional information
  required, e.g., to count the number of votes received.
  """
  @spec candidate(%Raft{is_leader: false}, any()) :: no_return()
  def candidate(state, extra_state) do
    receive do


      {sender,
       %Raft.AppendEntryRequest{
         term: term,
         leader_id: leader_id,
         prev_log_index: prev_log_index,
         prev_log_term: prev_log_term,
         entries: entries,
         leader_commit_index: leader_commit_index
       }} ->
        # TODO: Handle an AppendEntryRequest as a candidate
        IO.puts(
          "Candidate received append entry for term #{term} " <>
            "with leader #{leader_id} " <>
            "(#{leader_commit_index})"
        )
        # if term is at least current candidate' term, covert to follower
        cond do
          term > state.current_term ->
            state = %{state | current_term: term}
            state = %{state | voted_for: nil}
            state = %{state | current_leader: sender}
            become_follower(state)
          true -> candidate(state, extra_state)
        end

      {sender,
       %Raft.AppendEntryResponse{
         term: term,
         log_index: index,
         success: succ
       }} ->
        # TODO: Handle an append entry response as a candidate
        IO.puts(
          "Candidate received append entry response #{term}," <>
            " index #{index}, succcess #{succ}"
        )
        cond do
          term > state.current_term ->
            state = %{state | current_term: term}
            state = %{state | voted_for: nil}
            state = %{state | current_leader: nil}
            become_follower(state)
          true -> candidate(state, extra_state)
        end


      {sender,
       %Raft.RequestVote{
         term: term,
         candidate_id: candidate,
         last_log_index: last_log_index,
         last_log_term: last_log_term
       }} ->
        # TODO: Handle a RequestVote response as a candidate.
        IO.puts(
          "Candidate #{whoami()} received RequestVote " <>
            "term = #{term}, currentterm = #{state.current_term}, candidate = #{candidate}"
        )
        ## if term > current_term, decide vote and change to follower
        cond do
          term > state.current_term ->
          state = %{state | voted_for: nil}
          state_last_index = get_last_log_index(state)
          state = %{state | current_leader: nil}
          cond do
            term >= state.current_term && (state.voted_for == nil || state.voted_for == candidate) && get_last_log_term(state) < last_log_term ->
              send(sender, %Raft.RequestVoteResponse{
                term: term,
                granted: true
              } )
              state = %{state | current_term: term}
              state = %{state | voted_for: candidate}
              become_follower(state)
            # term equal, then larger index win
            term >= state.current_term && (state.voted_for == nil || state.voted_for == candidate) && get_last_log_term(state) == last_log_term && state_last_index <= last_log_index ->
              send(sender, %Raft.RequestVoteResponse{
                term: term,
                granted: true
              } )
              state = %{state | voted_for: candidate}
              state = %{state | current_term: term}
              become_follower(state)

            true ->
              send(sender, %Raft.RequestVoteResponse{
                term: term,
                granted: false
              } )
              state = %{state | current_term: term}
              become_follower(state)
          end
          true ->
            send(sender, %Raft.RequestVoteResponse{
              term: state.current_term,
              granted: false
            } )
          candidate(state, extra_state)
        end



      {sender,
       %Raft.RequestVoteResponse{
         term: term,
         granted: granted
       }} ->
        # TODO: Handle a RequestVoteResposne as a candidate.
        IO.puts(
          "Candidate #{whoami()} received RequestVoteResponse " <>
            "term = #{term},currentterm = #{state.current_term}, granted = #{inspect(granted)}"
        )
        cond do
          term > state.current_term ->
            state = %{state | current_term: term}
            state = %{state | voted_for: nil}
            become_follower(state)
          term == state.current_term && granted == true->
          current_count = extra_state["voteCount"]
          extra_state = Map.put(extra_state, "voteCount" ,current_count + 1)
          IO.puts("count is #{current_count + 1}")
          IO.puts("denum is #{div(length(state.view),2) + 1}")
          cond do
            current_count + 1 >= div(length(state.view),2) + 1 ->

            become_leader(state)
            true ->
              candidate(state, extra_state)
          end
          true ->
            candidate(state, extra_state)
         end
      :timeout ->
        become_candidate(state)

      # Messages from external clients.
      {sender, :nop} ->
        # Redirect in hopes that the current process
        # eventually gets elected leader.
        send(sender, {:redirect, whoami()})
        candidate(state, extra_state)

      {sender, {:enq, item}} ->
        # Redirect in hopes that the current process
        # eventually gets elected leader.
        send(sender, {:redirect, whoami()})
        candidate(state, extra_state)

      {sender, :deq} ->
        # Redirect in hopes that the current process
        # eventually gets elected leader.
        send(sender, {:redirect, whoami()})
        candidate(state, extra_state)

      # Messages for debugging [Do not modify existing ones,
      # but feel free to add new ones.]
      {sender, :send_state} ->
        send(sender, state.queue)
        candidate(state, extra_state)

      {sender, :send_log} ->
        send(sender, state.log)
        candidate(state, extra_state)

      {sender, :whois_leader} ->
        send(sender, {:candidate, state.current_term})
        candidate(state, extra_state)

      {sender, :current_process_type} ->
        send(sender, :candidate)
        candidate(state, extra_state)

      {sender, {:set_election_timeout, min, max}} ->
        state = %{state | min_election_timeout: min, max_election_timeout: max}
        state = reset_election_timer(state)
        send(sender, :ok)
        candidate(state, extra_state)

      {sender, {:set_heartbeat_timeout, timeout}} ->
        send(sender, :ok)
        candidate(%{state | heartbeat_timeout: timeout}, extra_state)
    end
  end
end

defmodule Raft.Client do
  import Emulation, only: [send: 2]

  import Kernel,
    except: [spawn: 3, spawn: 1, spawn_link: 1, spawn_link: 3, send: 2]

  @moduledoc """
  A client that can be used to connect and send
  requests to the RSM.
  """
  alias __MODULE__
  @enforce_keys [:leader]
  defstruct(leader: nil)

  @doc """
  Construct a new Raft Client. This takes an ID of
  any process that is in the RSM. We rely on
  redirect messages to find the correct leader.
  """
  @spec new_client(atom()) :: %Client{leader: atom()}
  def new_client(member) do
    %Client{leader: member}
  end

  @doc """
  Send a nop request to the RSM.
  """
  @spec nop(%Client{}) :: {:ok, %Client{}}
  def nop(client) do
    leader = client.leader
    send(leader, :nop)

    receive do
      {_, {:redirect, new_leader}} ->
        nop(%{client | leader: new_leader})

      {_, :ok} ->
        {:ok, client}
    end
  end

  @doc """
  Send a dequeue request to the RSM.
  """
  @spec deq(%Client{}) :: {:empty | {:value, any()}, %Client{}}
  def deq(client) do
    leader = client.leader
    send(leader, :deq)

    receive do
      {_, {:redirect, new_leader}} ->
        deq(%{client | leader: new_leader})

      {_, v} ->
        {v, client}
    end
  end

  @doc """
  Send an enqueue request to the RSM.
  """
  @spec enq(%Client{}, any()) :: {:ok, %Client{}}
  def enq(client, item) do
    leader = client.leader
    send(leader, {:enq, item})

    receive do
      {_, :ok} ->
        {:ok, client}

      {_, {:redirect, new_leader}} ->
        enq(%{client | leader: new_leader}, item)
    end
  end
end
