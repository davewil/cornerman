defmodule Cornerman.Spawn.Run do
  @moduledoc false
  # One OS command. Owns the erlexec child, relays its output to the caller, and kills its
  # process group itself (SIGTERM, grace, SIGKILL) rather than through erlexec's stop: erlexec
  # only escalates to SIGKILL while the group leader is alive, and its kill_timeout is in whole
  # seconds. erlexec's kill_group/kill_timeout remain the fallback when this process or the VM
  # dies.
  #
  # A command is done when its leader has exited AND nothing holds its stdout any more, which
  # is what Ringer's `proc.wait()` means (asyncio waits for every pipe to close). erlexec cannot
  # do that: when the leader exits it closes its pipe and signals the group. So the leader
  # erlexec starts is a small wrapper (@wrapper) that runs the command with stdout and stderr on
  # a pipe of its own, copies that to erlexec until EOF, and only then exits with the command's
  # exact status or signal. The wrapper is in the command's process group, so erlexec's
  # `:kill_group` (timeout, stop, owner death, death of the whole VM) reaches every process
  # that holds the pipe.

  use GenServer, restart: :temporary

  @default_grace_ms 2_000

  # exec-port's forked child occasionally fails its own setpgid(0, 0) with EPERM, before
  # execve, prints this line on the command's stdout and exits 1 (seen about once per 1,000
  # spawns under macOS; mechanism not established, see notes.md). The command never ran, so
  # running it again is side-effect free. Only a leader whose entire output is this line and
  # whose status is 1 is re-run, at most @max_respawns times, and never once a kill has been
  # requested.
  @setpgid_failure "Cannot set effective group to 0: Operation not permitted\n"
  @max_respawns 3

  # The wrapper is perl (in macOS and in Debian's base system), not sh: a shell reports both
  # `exit 137` and death by SIGKILL as 137, and a run's returncode must tell them apart. It
  # blocks TERM/INT/HUP/QUIT for itself, so a group SIGTERM reaches the command but the wrapper
  # stays until the command's output has ended; the command starts with them unblocked. The
  # command is exec'd as a list, so its argv is untouched, and a signal death is re-raised on
  # the wrapper, so erlexec sees the wait status the command had.
  #
  # The wrapper's own environment is scrubbed of PERL*, PERLIO and the locale (see
  # wrapper_env/1), so nothing in the caller's environment steers it; the command's complete
  # environment travels hex-encoded in CORNERMAN_WRAPPER_ENV and is what the command is exec'd
  # with. The wrapper's stderr, which erlexec keeps apart from the command's output (that goes
  # to stdout), is a control channel: lines "\0CM S <raw wait status>" as soon as the command
  # is reaped, which can be long before its output ends, and "\0CM E <errno name>" when the
  # command could not be exec'd.
  @control <<0, "CM ">>
  @wrapper ~S"""
  use POSIX qw(:signal_h :sys_wait_h _exit);
  use Config;
  my $env = pack("H*", delete $ENV{CORNERMAN_WRAPPER_ENV});
  sub control { syswrite(STDERR, "\0CM $_[0]\n") }
  my $held = POSIX::SigSet->new(SIGTERM, SIGINT, SIGHUP, SIGQUIT);
  sigprocmask(SIG_BLOCK, $held) or _exit(126);
  pipe(my $r, my $w) or _exit(126);
  pipe(my $er, my $ew) or _exit(126);
  my $pid = fork;
  defined $pid or _exit(126);
  if (!$pid) {
    close $r;
    close $er;
    open(STDOUT, ">&", $w) or _exit(126);
    open(STDERR, ">&", $w) or _exit(126);
    close $w;
    sigprocmask(SIG_UNBLOCK, $held);
    %ENV = ();
    for (split /\0/, $env) { my ($k, $v) = split /=/, $_, 2; $ENV{$k} = $v }
    exec { $ARGV[0] } @ARGV;
    my ($name) = grep { $!{$_} } keys %!;
    syswrite($ew, defined $name ? $name : "EINVAL");
    _exit(127);
  }
  close $w;
  close $ew;
  my $failed;
  while (1) {
    my $n = sysread($er, $failed, 64);
    next if !defined $n && $!{EINTR};
    last;
  }
  if (length $failed) {
    waitpid($pid, 0);
    control("E $failed");
    _exit(127);
  }
  my ($status, $buf, $rout);
  my $rin = '';
  vec($rin, fileno($r), 1) = 1;
  while (1) {
    if (!defined $status && waitpid($pid, WNOHANG) == $pid) {
      $status = $?;
      control("S $status");
    }
    my $ready = select($rout = $rin, undef, undef, defined $status ? undef : 0.1);
    if ($ready < 0) { next if $!{EINTR}; last }
    next unless $ready;
    my $n = sysread($r, $buf, 65536);
    if (!defined $n) { next if $!{EINTR}; last }
    last unless $n;
    for (my $off = 0; $off < $n;) {
      my $k = syswrite(STDOUT, $buf, $n - $off, $off);
      if (!defined $k) { next if $!{EINTR}; last }
      $off += $k;
    }
  }
  if (!defined $status) { waitpid($pid, 0); $status = $? }
  if (my $sig = $status & 127) {
    my $name = (split ' ', $Config{sig_name})[$sig];
    $SIG{$name} = 'DEFAULT' if defined $name;
    sigprocmask(SIG_SETMASK, POSIX::SigSet->new);
    kill $sig, $$;
    sleep 1;
    _exit(128 + $sig);
  }
  _exit($status >> 8);
  """

  def start_link({ref, _owner, _argv, _opts} = arg) do
    GenServer.start_link(__MODULE__, arg, name: {:via, Registry, {Cornerman.Spawn.Registry, ref}})
  end

  @impl true
  def init({ref, owner, argv, opts}) do
    Process.flag(:trap_exit, true)
    grace_ms = Keyword.get(opts, :kill_grace_ms, @default_grace_ms)

    with {:ok, command} <- wrap(argv) do
      state = %{
        ref: ref,
        owner: owner,
        notify?: true,
        lwp: nil,
        os_pid: nil,
        grace_ms: grace_ms,
        opts: opts,
        exit_detail?: Keyword.get(opts, :exit_detail, false),
        notify_start?: Keyword.get(opts, :notify_start, false),
        command: command,
        # the leader's exit reason, once it has exited
        leader_reason: nil,
        # from the wrapper's control channel: the command's raw wait status, once it is reaped,
        # and the errno name if it could not be exec'd
        command_raw: nil,
        exec_error: nil,
        # output held back while it could still be exec-port's setpgid failure
        held: nil,
        respawns: 0,
        # nil while running; the reason to report once the kill has been requested
        ending: nil,
        leader_exited?: false,
        # the exit has been reported to the owner (or the owner is gone)
        reported?: false,
        killed?: false
      }

      case launch(state) do
        {:ok, state} ->
          Process.monitor(owner)
          schedule_timeout(Keyword.get(opts, :timeout_ms, :infinity))
          announce_start(state)
          {:ok, state}

        {:error, reason} ->
          {:stop, reason}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  # argv elements stay binaries: erlexec passes them through as bytes, so invalid UTF-8 survives.
  defp wrap(argv) do
    case perl() do
      nil -> {:error, :perl_not_found}
      perl -> {:ok, [perl, "-e", @wrapper, "--" | argv]}
    end
  end

  defp perl do
    if File.exists?("/usr/bin/perl"), do: "/usr/bin/perl", else: System.find_executable("perl")
  end

  # The command's complete environment: the VM's, with the caller's changes applied.
  defp command_env(opts) do
    Enum.reduce(Keyword.get(opts, :env, []), System.get_env(), fn
      {name, false}, env -> Map.delete(env, to_string(name))
      {name, value}, env -> Map.put(env, to_string(name), to_string(value))
    end)
  end

  # What perl itself runs with: everything but the settings that steer it (PERL*, which covers
  # PERLIO, PERL5OPT, PERL5LIB; the locale; macOS's perl version selection), and no locale
  # complaint. The command's own environment goes in a variable of its own.
  defp wrapper_env(env) do
    kept =
      env
      |> Enum.reject(fn {name, _} ->
        String.starts_with?(name, ["PERL", "LC_", "VERSIONER_PERL"]) or
          name in ["LANG", "LANGUAGE"]
      end)

    payload =
      env
      |> Enum.map_join("\0", fn {name, value} -> name <> "=" <> value end)
      |> Base.encode16(case: :lower)

    [:clear | kept] ++ [{"PERL_BADLANG", "0"}, {"CORNERMAN_WRAPPER_ENV", payload}]
  end

  # Starts (or restarts) the command.
  defp launch(state) do
    case :exec.run(state.command, exec_options(state)) do
      {:ok, lwp, os_pid} ->
        {:ok,
         %{
           state
           | lwp: lwp,
             os_pid: os_pid,
             leader_reason: nil,
             command_raw: nil,
             exec_error: nil,
             leader_exited?: false,
             held: nil
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp announce_start(%{notify_start?: true} = state),
    do: notify(state, {:started, state.os_pid})

  defp announce_start(_state), do: :ok

  defp exec_options(%{opts: opts, grace_ms: grace_ms}) do
    base = [
      # New process group whose id is the wrapper's pid, which the command inherits.
      {:group, 0},
      {:kill_timeout, max(1, ceil(grace_ms / 1000))},
      {:stdin, :null},
      {:stdout, self()},
      # The wrapper's control channel, and (rarely) exec-port's own pre-exec failure line.
      {:stderr, self()},
      {:env, wrapper_env(command_env(opts))},
      # Linked, so exec-port stops the command if this process dies.
      :link,
      # Fallback cleanup by exec-port: signal the whole group, not just the leader.
      :kill_group
    ]

    case Keyword.fetch(opts, :cwd) do
      # A UTF-8 binary: exec-port rejects a charlist holding code points above 255.
      {:ok, cwd} -> [{:cd, IO.chardata_to_string(cwd)} | base]
      :error -> base
    end
  end

  defp schedule_timeout(:infinity), do: :ok
  defp schedule_timeout(ms) when is_integer(ms), do: Process.send_after(self(), :timeout, ms)

  @impl true
  def handle_cast(:stop, state), do: {:noreply, terminate_group(state, :stopped)}

  # The owner is going away: SIGKILL the group now, report nothing.
  def handle_cast(:kill_now, state) do
    signal_group(state.os_pid, "KILL")

    state = %{state | notify?: false, killed?: true, ending: state.ending || :killed}
    if state.reported?, do: finish(state), else: {:noreply, state}
  end

  @impl true
  def handle_info({:stdout, os_pid, data}, %{os_pid: os_pid} = state) do
    {:noreply, relay(state, data)}
  end

  def handle_info(:timeout, state), do: {:noreply, terminate_group(state, :timeout)}

  def handle_info({:DOWN, _, :process, owner, _}, %{owner: owner} = state) do
    {:noreply, terminate_group(%{state | notify?: false}, :owner_down)}
  end

  def handle_info(:kill_group, state) do
    signal_group(state.os_pid, "KILL")
    finish(%{state | killed?: true})
  end

  def handle_info({:stderr, os_pid, data}, %{os_pid: os_pid} = state),
    do: {:noreply, stderr(state, data)}

  # erlexec's per-command process exits with the leader: :normal for status 0, otherwise
  # {:exit_status, raw} with the raw wait status. The leader is the wrapper, which exits only
  # once the command's output has ended, so this is the command's end. After we have started a
  # kill, the kill reason is reported instead of the status. Only that process counts: the
  # ports behind our System.cmd("kill") calls are linked to us too, and their :normal exits are
  # not the leader's.
  #
  # Any other reason means erlexec itself failed under the command (its :exec server died).
  # Nothing will report the command's end then, so the group is killed here and the exit is
  # reported as a kill; waiting for a message that never comes would hang the caller.
  def handle_info({:EXIT, lwp, reason}, %{lwp: lwp, leader_exited?: false} = state) do
    normal? = reason == :normal or (is_tuple(reason) and elem(reason, 0) == :exit_status)

    unless normal? do
      signal_group(state.os_pid, "KILL")
    end

    complete(%{
      state
      | leader_exited?: true,
        leader_reason: reason,
        killed?: state.killed? or not normal?
    })
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Control lines from the wrapper (@control); anything else on stderr is exec-port's own
  # pre-exec failure line, which is handled like output.
  defp stderr(state, <<@control, _::binary>> = data) do
    data
    |> String.split("\n", trim: true)
    |> Enum.reduce(state, fn
      <<@control, "S ", raw::binary>>, state -> %{state | command_raw: String.to_integer(raw)}
      <<@control, "E ", name::binary>>, state -> %{state | exec_error: name}
      _other, state -> state
    end)
  end

  defp stderr(state, data), do: relay(state, data)

  # The command is over. Report the exit, or run the command again.
  defp complete(state) do
    if respawn?(state, state.leader_reason) do
      respawn(state)
    else
      state = release(state)
      notify(state, {:exit, final_exit(state)})
      finish(%{state | notify?: false, reported?: true})
    end
  end

  # Output is relayed at once unless everything so far could still be exec-port's
  # pre-exec failure line; that is held until more output or the exit decides.
  defp relay(%{respawns: n, ending: nil} = state, data) when n < @max_respawns do
    candidate = (state.held || "") <> data

    if String.starts_with?(@setpgid_failure, candidate),
      do: %{state | held: candidate},
      else: state |> Map.put(:held, nil) |> tap(&notify(&1, {:data, candidate}))
  end

  defp relay(state, data) do
    state = release(state)
    notify(state, {:data, data})
    state
  end

  defp release(%{held: nil} = state), do: state

  defp release(%{held: held} = state) do
    notify(state, {:data, held})
    %{state | held: nil}
  end

  defp respawn?(state, reason) do
    state.held == @setpgid_failure and state.ending == nil and
      state.respawns < @max_respawns and detail(reason) == {:status, 1}
  end

  defp respawn(state) do
    case launch(%{state | respawns: state.respawns + 1}) do
      {:ok, state} ->
        announce_start(state)
        {:noreply, state}

      {:error, _} ->
        state = release(state)
        notify(state, {:exit, exit_reason(state, {:exit_status, 256})})
        finish(%{state | notify?: false, reported?: true})
    end
  end

  # Signals the group once; a second request (say, stop after timeout) keeps the first reason.
  defp terminate_group(%{ending: nil, leader_exited?: false} = state, reason) do
    signal_group(state.os_pid, "TERM")
    Process.send_after(self(), :kill_group, state.grace_ms)
    %{state | ending: reason}
  end

  defp terminate_group(state, _reason), do: state

  # Done when the leader has exited and, if we started a kill, the SIGKILL has gone out, so
  # stragglers that ignore SIGTERM still die.
  defp finish(%{reported?: true, ending: nil} = state), do: {:stop, :normal, state}
  defp finish(%{reported?: true, killed?: true} = state), do: {:stop, :normal, state}
  defp finish(state), do: {:noreply, state}

  defp notify(%{notify?: true, owner: owner, ref: ref}, event),
    do: send(owner, {:cornerman_spawn, ref, event})

  defp notify(_state, _event), do: :ok

  defp signal_group(pgid, signal) do
    System.cmd("kill", ["-s", signal, "--", "-#{pgid}"], stderr_to_stdout: true)
    :ok
  end

  # A command that could not be exec'd is reported as such. Otherwise the command's own status
  # when the wrapper reported it (it knows it as soon as it reaps the command, before any
  # SIGKILL can take the wrapper), else the leader's.
  defp final_exit(%{exec_error: name}) when is_binary(name),
    do: {:exec_failed, name |> String.downcase() |> String.to_atom()}

  defp final_exit(%{command_raw: raw} = state) when is_integer(raw),
    do: exit_reason(state, {:exit_status, raw})

  defp final_exit(state), do: exit_reason(state, state.leader_reason)

  defp exit_reason(%{exit_detail?: false} = state, reason),
    do: state.ending || {:status, status(reason)}

  defp exit_reason(%{ending: nil}, reason), do: detail(reason)
  defp exit_reason(%{ending: ending}, reason), do: {ending, detail(reason)}

  # With :exit_detail, a signal death is reported as the signal, not folded into 128 + n.
  defp detail(:normal), do: {:status, 0}

  # erlexec failed under the command and the group was killed here.
  defp detail(reason) when not is_tuple(reason) or elem(reason, 0) != :exit_status,
    do: {:signal, 9}

  defp detail({:exit_status, raw}) do
    case Bitwise.band(raw, 0x7F) do
      0 -> {:status, Bitwise.bsr(raw, 8) |> Bitwise.band(0xFF)}
      signal -> {:signal, signal}
    end
  end

  defp status(:normal), do: 0
  defp status(reason) when not is_tuple(reason) or elem(reason, 0) != :exit_status, do: 137

  defp status({:exit_status, raw}) do
    case Bitwise.band(raw, 0x7F) do
      0 -> Bitwise.bsr(raw, 8) |> Bitwise.band(0xFF)
      signal -> 128 + signal
    end
  end
end
