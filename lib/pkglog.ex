defmodule Pkglog do
  alias Pkglog.Parsers.Pacman

  @parsers %{
    "pacman" => Pacman
  }

  @actions MapSet.new(["installed", "removed", "upgraded", "downgraded", "reinstalled"])

  def run(config) do
    parser_mod = determine_parser(nil)
    start_time = compute_start_time(config.days)
    boot_time = get_boot_time()

    config = 
      if config.packages != [] do
        packages = 
          Enum.map(config.packages, fn pkg ->
            cond do
              config.glob -> 
                pattern = 
                  pkg
                  |> String.replace(".", "\\.")
                  |> String.replace("*", ".*")
                  |> String.replace("?", ".")
                Regex.compile!("^#{pattern}$")
              config.regex -> 
                Regex.compile!(pkg)
              true -> 
                pkg
            end
          end)
        %{config | packages: packages}
      else
        config
      end

    files = get_log_files(parser_mod.logfile(), config)

    boot_str = 
      if config.packages == [] and !config.boot do
         "#{format_boot_time(boot_time)} ### LAST SYSTEM BOOT ###"
      else
         nil
      end

    initial_state = %{
      queue: [],
      installed: %{},
      installed_previously: %{},
      last_dt: nil,
      parser_state: parser_mod.initial_state(),
      config: config,
      boot_time: boot_time,
      boot_str: boot_str,
      boot_printed: false,
      # Packages explicitly installed per pacman local DB (loaded when needed)
      explicit_pkgs: if(config.explicit_net, do: get_explicit_packages(), else: nil),
      # --pacman-actions tracking
      pacman_cmd: nil,
      pkg_status: %{}
    }

    final_state = 
      Enum.reduce(files, initial_state, fn file, state ->
        process_file(file, parser_mod, start_time, state)
      end)

    final_state = output_queue(final_state)

    if !final_state.boot_printed and !config.boot and final_state.last_dt do
       print_boot_marker(final_state, trailing: false)
    end
  end

  @doc """
  Return a MapSet of packages currently explicitly installed, according to
  pacman's local database (/var/lib/pacman/local/*/desc). Install Reason 0
  means explicitly installed; 1 means installed as a dependency.
  """
  def get_explicit_packages(db_dir \\ "/var/lib/pacman/local") do
    case File.ls(db_dir) do
      {:ok, entries} ->
        Enum.reduce(entries, MapSet.new(), fn entry, acc ->
          desc_path = Path.join([db_dir, entry, "desc"])

          if File.regular?(desc_path) do
            case parse_desc(desc_path) do
              {pkg, :explicit} -> MapSet.put(acc, pkg)
              _ -> acc
            end
          else
            acc
          end
        end)

      {:error, reason} ->
        IO.puts(
          "ERROR: Can not read pacman database at #{db_dir} (#{reason}) to determine explicit installs."
        )

        System.halt(1)
    end
  end

  defp parse_desc(path) do
    case File.read(path) do
      {:ok, content} ->
        lines = String.split(content, "\n")

        name =
          with idx when idx != nil <- Enum.find_index(lines, &(&1 == "%NAME%")),
               n <- Enum.at(lines, idx + 1),
               true <- is_binary(n) and n != "" do
            n
          else
            _ -> nil
          end

        reason =
          with idx when idx != nil <- Enum.find_index(lines, &(&1 == "%REASON%")) do
            Enum.at(lines, idx + 1)
          else
            _ -> nil
          end

        if is_binary(name) and name != "" and reason in [nil, "0"] do
          {name, :explicit}
        else
          nil
        end

      _ ->
        nil
    end
  end

  defp determine_parser(nil) do
    found = 
      Enum.find(@parsers, fn {_name, mod} ->
        File.exists?(mod.logfile())
      end)
    
    case found do
      {_name, mod} -> mod
      nil -> 
        IO.puts("ERROR: Can not determine log parser for this system.")
        System.halt(1)
    end
  end

  defp compute_start_time(-1), do: nil # All days
  defp compute_start_time("-1"), do: nil # All days (string form)
  defp compute_start_time(days_str) when is_binary(days_str) do
    case Integer.parse(days_str) do
      {days, ""} ->
        if days == 0 do
           NaiveDateTime.beginning_of_day(NaiveDateTime.local_now())
        else
           Date.add(Date.utc_today(), -days) |> NaiveDateTime.new!(~T[00:00:00])
        end
      _ ->
        # Assuming YYYY-MM-DD
        case Date.from_iso8601(days_str) do
          {:ok, date} -> NaiveDateTime.new!(date, ~T[00:00:00])
          _ -> 
             IO.puts("ERROR: Can not parse days value.")
             System.halt(1)
        end
    end
  end
  defp compute_start_time(_), do: nil

  defp get_boot_time() do
    {uptime_str, 0} = System.cmd("cat", ["/proc/uptime"])
    [uptime_sec | _] = String.split(uptime_str, " ")
    {sec, _} = Float.parse(uptime_sec)
    
    NaiveDateTime.add(NaiveDateTime.local_now(), -trunc(sec), :second)
  end

  defp get_log_files(logfile, config) do
    if config.path do
      String.split(config.path, ":")
    else
      path = Path.expand(logfile)
      dir = Path.dirname(path)
      base = Path.basename(path)
      
      files = 
        case File.ls(dir) do
          {:ok, list} ->
            list
            |> Enum.filter(fn f -> String.starts_with?(f, base) end)
            |> Enum.sort_by(fn f -> 
               case Regex.run(~r/\.(\d+)(?:\.gz)?$/, f) do
                 [_, num] -> String.to_integer(num)
                 nil -> 0 # The main file
               end
            end, :desc) # Python: reverse=True (biggest number first = oldest)
            |> Enum.map(&Path.join(dir, &1))
          {:error, _} -> []
        end
        
      if files == [], do: [path], else: files
    end
  end

  defp process_file(path, parser_mod, start_time, state) do
    if !File.exists?(path) do
       IO.puts("ERROR: #{path} does not exist.")
       System.halt(1)
    end
    
    stream = 
      if String.ends_with?(path, ".gz") do
        File.stream!(path, [:read, :compressed])
      else
        File.stream!(path)
      end
      
    Enum.reduce(stream, state, fn line, acc ->
      process_line(line, parser_mod, start_time, acc)
    end)
  end

  defp process_line(line, parser_mod, start_time, state) do
    case parser_mod.parse_line(line, state.parser_state) do
      {:ok, dt, new_parser_state} ->
        state = %{state | parser_state: new_parser_state}
        
        if (start_time && NaiveDateTime.compare(dt, start_time) == :lt) ||
           (state.config.boot && NaiveDateTime.compare(dt, state.boot_time) == :lt) do
           state
        else
           state = 
             if state.last_dt &&
                NaiveDateTime.diff(dt, state.last_dt, :second) > state.config.timegap * 60 &&
                !state.config.installed_net do
                
                output_queue(state)
             else
                state
             end
             
           state = %{state | last_dt: dt}
           
           {pkgs, final_parser_state} = parser_mod.get_packages(state.parser_state)
           state = %{state | parser_state: final_parser_state}
           
           Enum.reduce(pkgs, state, fn {action, pkg, ver}, acc ->
             cond do
               MapSet.member?(@actions, action) and !acc.config.pacman_actions ->
                 queue_append(acc, dt, action, pkg, ver)

               acc.config.pacman_actions ->
                 handle_pacman_action(acc, dt, action, pkg, ver)

               true ->
                 acc
             end
           end)
        end

      {:skip, new_parser_state} ->
        %{state | parser_state: new_parser_state}
    end
  end

  defp queue_append(state, dt, action, pkg, ver) do
    # Maintain installed/removed maps for net-installed logic
    state = 
      case action do
        a when a in ["installed", "installed_asdep"] -> 
          %{state | installed: Map.put(state.installed, pkg, dt)}
        "removed" -> 
          %{state | installed: Map.delete(state.installed, pkg), 
                    installed_previously: Map.put(state.installed_previously, pkg, dt)}
        _ -> state
      end

    %{state | queue: state.queue ++ [{dt, action, pkg, ver}]}
  end

  # ==========================================================================
  # --pacman-actions
  #
  # Uses the [PACMAN] Running '...' command records and the [ALPM]
  # transaction started/completed markers in pacman.log to determine how
  # each package was acted upon:
  #
  # - A package named in the recorded pacman command which directly precedes
  #   the ALPM transaction where it is installed is shown. If that command
  #   contained --asdeps it is shown as "installed as dependency" (blue),
  #   otherwise as a regular "installed".
  # - A package installed during a transaction but NOT named in the
  #   preceding command was pulled in as a dependency and is not shown.
  # - `pacman -D --asexplicit` / `pacman -D --asdeps` commands emit
  #   "marked as explicit" / "marked as dependency" lines.
  # - When a package is removed, dependencies auto-removed within the same
  #   transaction are hidden unless they were earlier installed as a
  #   dependency or marked as a dependency.
  # ==========================================================================

  @pacman_op_chars %{
    "S" => :sync,
    "R" => :remove,
    "D" => :database,
    "U" => :upgrade,
    "Q" => :query,
    "F" => :files,
    "T" => :check
  }

  @pacman_long_ops %{
    "--sync" => :sync,
    "--remove" => :remove,
    "--database" => :database,
    "--upgrade" => :upgrade,
    "--query" => :query,
    "--files" => :files,
    "--deptest" => :check
  }

  defp handle_pacman_action(state, dt, action, pkg, ver) do
    case action do
      "pacman_running" ->
        cmd = parse_pacman_command(pkg)
        state = %{state | pacman_cmd: cmd}

        if cmd && cmd.op == :database && (cmd.asexplicit || cmd.asdeps) do
          {action_str, status} =
            if cmd.asexplicit do
              {"marked_explicit", :explicit}
            else
              {"marked_dependency", :dep_marked}
            end

          Enum.reduce(cmd.names, state, fn name, acc ->
            acc
            |> put_pkg_status(name, status)
            |> queue_append(dt, action_str, name, "")
          end)
        else
          state
        end

      "transaction completed" ->
        %{state | pacman_cmd: nil}

      "transaction started" ->
        state

      "installed" ->
        handle_install(state, dt, pkg, ver)

      "removed" ->
        handle_remove(state, dt, pkg, ver)

      _ ->
        # upgraded / downgraded / reinstalled are always shown as usual;
        # ignore any other [ALPM] line content (warnings, scriptlets, ...)
        if MapSet.member?(@actions, action) do
          queue_append(state, dt, action, pkg, ver)
        else
          state
        end
    end
  end

  defp handle_install(state, dt, pkg, ver) do
    cmd = state.pacman_cmd

    cond do
      named_in_cmd?(cmd, [:sync, :upgrade], pkg) && cmd.asdeps ->
        state
        |> put_pkg_status(pkg, :asdeps)
        |> queue_append(dt, "installed_asdep", pkg, ver)

      named_in_cmd?(cmd, [:sync, :upgrade], pkg) ->
        state
        |> put_pkg_status(pkg, :explicit)
        |> queue_append(dt, "installed", pkg, ver)

      true ->
        # Pulled in as a dependency: track it but don't display.
        put_pkg_status(state, pkg, :dep_pulled_in)
    end
  end

  defp handle_remove(state, dt, pkg, ver) do
    cmd = state.pacman_cmd
    status = Map.get(state.pkg_status, pkg)

    if named_in_cmd?(cmd, [:remove], pkg) or status in [:asdeps, :dep_marked] do
      queue_append(state, dt, "removed", pkg, ver)
    else
      state
    end
  end

  defp named_in_cmd?(nil, _ops, _pkg), do: false

  defp named_in_cmd?(cmd, ops, pkg) do
    cmd.op in ops and
      Enum.any?(cmd.names, fn name ->
        # Exact match (regular package name), or for -U/--upgrade commands
        # where the command line refers to a package archive file or URL in
        # the format "name[-ver-rel-arch].pkg.tar.zst"
        name == pkg or (cmd.op == :upgrade and upgrade_archive_match?(name, pkg))
      end)
  end

  # Matches a package archive reference whose file name begins with the
  # package name. Only resources ending in ".pkg.tar.zst" count; anything
  # else (plain URLs, other files) does not.
  defp upgrade_archive_match?(ref, pkg) do
    case Regex.run(~r/^([^\/?#]+)\.pkg\.tar\.zst$/, Path.basename(ref)) do
      [_, stem] ->
        stem == pkg or String.starts_with?(stem, pkg <> "-")

      _ ->
        false
    end
  end

  defp parse_pacman_command(cmdline) do
    tokens = String.split(cmdline)

    if program_is_pacman?(tokens) do
      case find_op(tokens) do
        nil ->
          nil

        op ->
          {names, asdeps, asexplicit} = scan_tokens(tokens, [], false, false)

          %{
            op: op,
            asdeps: asdeps,
            asexplicit: asexplicit,
            names: names
          }
      end
    else
      nil
    end
  end

  # The recorded command must actually be pacman itself ("pacman" or a path
  # to it), not some other program or an ALPM hook reference.
  defp program_is_pacman?([token | _]), do: Path.basename(token) == "pacman"
  defp program_is_pacman?([]), do: false

  defp find_op(tokens) do
    # The operation is the first operation flag found, either a long form
    # (--sync) or a short form which may be clustered with other flags
    # (e.g. -Rns, -Syu). Only uppercase letters are pacman operations.
    Enum.find_value(tokens, fn token ->
      cond do
        Map.has_key?(@pacman_long_ops, token) ->
          Map.fetch!(@pacman_long_ops, token)

        Regex.match?(~r/^-[a-zA-Z]+$/, token) ->
          token
          |> String.slice(1..-1//1)
          |> String.graphemes()
          |> Enum.map(&Map.get(@pacman_op_chars, &1))
          |> Enum.find(&(&1 != nil))

        true ->
          nil
      end
    end)
  end

  defp scan_tokens([], names, asdeps, asexplicit),
    do: {:lists.reverse(names), asdeps, asexplicit}

  defp scan_tokens(["--" | rest], names, asdeps, asexplicit) do
    # Everything after "--" is a package name
    {Enum.reverse(names) ++ rest, asdeps, asexplicit}
  end

  defp scan_tokens(["--asdeps" | rest], names, _, asexplicit),
    do: scan_tokens(rest, names, true, asexplicit)

  defp scan_tokens(["--asexplicit" | rest], names, asdeps, _),
    do: scan_tokens(rest, names, asdeps, true)

  defp scan_tokens([token | rest], names, asdeps, asexplicit) do
    cond do
      String.starts_with?(token, "-") ->
        scan_tokens(rest, names, asdeps, asexplicit)

      Path.basename(token) == "pacman" ->
        scan_tokens(rest, names, asdeps, asexplicit)

      true ->
        scan_tokens(rest, [token | names], asdeps, asexplicit)
    end
  end

  defp put_pkg_status(state, pkg, status) do
    %{state | pkg_status: Map.put(state.pkg_status, pkg, status)}
  end

  defp output_queue(state) do
    if state.queue == [] do
      state
    else
      
      filtered = 
        state.queue
        |> Enum.filter(fn {dt, action, pkg, ver} ->
           filter_package(dt, action, pkg, ver, state)
        end)
        |> Enum.map(fn {dt, action, pkg, ver} ->
           color = get_color(action)
           vers_disp = display_text(action, ver, state.config.verbose)
           {dt, pkg, vers_disp, color}
        end)
      
      if filtered != [] do
        should_print_delim = 
          state.config.packages == [] and 
          not state.config.installed and 
          not state.config.installed_only
          
        maxlen = 
           if state.config.nojustify do
             1
           else
             Enum.map(filtered, fn {_, pkg, _, _} -> String.length(pkg) end) |> Enum.max(fn -> 1 end)
           end
          
        {new_state, _} = 
          Enum.reduce(filtered, {state, 0}, fn {dt, pkg, vers, color}, {acc_state, idx} ->
             {acc_state, printed_boot} = 
               if !acc_state.boot_printed and NaiveDateTime.compare(dt, acc_state.boot_time) == :gt do
                 {print_boot_marker(acc_state), true}
               else
                 {acc_state, false}
               end
             
             if !printed_boot and idx == 0 and should_print_delim do
               IO.puts(String.duplicate("-", 80))
             end
             
             padding = if acc_state.config.nojustify, do: 0, else: maxlen
             if acc_state.config.color do
               IO.puts([color, "#{dt} ", String.pad_trailing(pkg, padding), " #{vers}", IO.ANSI.reset()])
             else
               IO.puts("#{dt} #{String.pad_trailing(pkg, padding)} #{vers}")
             end
             
             {acc_state, idx + 1}
          end)
          
        %{new_state | queue: []}
      else
        %{state | queue: []}
      end
    end
  end
  
  defp display_text(action, ver, verbose) do
    case action do
      a when a in ["upgraded", "downgraded"] ->
        if verbose, do: "#{ver} #{a}", else: ver

      "installed_asdep" ->
        "#{ver} installed as dependency"

      "marked_explicit" ->
        "marked as explicit"

      "marked_dependency" ->
        "marked as dependency"

      _ ->
        "#{ver} #{action}"
    end
  end

  defp filter_package(dt, action, pkg, _ver, state) do
     
     keep = 
       cond do
         state.config.updated_only and action != "upgraded" and action != "downgraded" -> false
         state.config.installed and !(action in ["installed", "installed_asdep", "removed"]) -> false
         state.config.installed_only and !(action in ["installed", "installed_asdep"]) -> false

         state.config.explicit_net and !MapSet.member?(state.explicit_pkgs, pkg) -> false
         
         state.config.packages != [] ->
            Enum.any?(state.config.packages, fn arg_pkg ->
              if state.config.glob || state.config.regex do
                Regex.run(arg_pkg, pkg)
              else
                pkg == arg_pkg
              end
            end)
         
         state.config.installed_net ->
            pkgdt = Map.get(state.installed, pkg)
            pkgdt_rm = Map.get(state.installed_previously, pkg)
            
            cond do
               !pkgdt || NaiveDateTime.compare(dt, pkgdt) == :lt -> false
               pkgdt_rm && NaiveDateTime.diff(pkgdt, pkgdt_rm, :day) < state.config.installed_net_days -> false
               true -> true
            end
            
         true -> true
       end
       
     keep
  end

  defp get_color("installed"), do: IO.ANSI.green()
  defp get_color("removed"), do: IO.ANSI.red()
  defp get_color("upgraded"), do: IO.ANSI.yellow()
  defp get_color("downgraded"), do: IO.ANSI.magenta()
  defp get_color("reinstalled"), do: IO.ANSI.cyan()
  defp get_color("installed_asdep"), do: IO.ANSI.blue()
  defp get_color("marked_explicit"), do: IO.ANSI.white()
  defp get_color("marked_dependency"), do: IO.ANSI.white()
  defp get_color(_), do: IO.ANSI.white()
  
  defp print_boot_marker(state, opts \\ []) do
     if !state.boot_printed and state.boot_str do
       trailing = Keyword.get(opts, :trailing, true)
       should_print_delim = 
          state.config.packages == [] and 
          not state.config.installed and 
          not state.config.installed_only

       if should_print_delim do
         IO.puts(String.duplicate("-", 80))
       end
       IO.puts(state.boot_str)
       if should_print_delim and trailing do
         IO.puts(String.duplicate("-", 80))
       end
       %{state | boot_printed: true}
     else
       state
     end
  end

  defp format_boot_time(dt) do
     # Format NaiveDateTime to "YYYY-MM-DD HH:MM:SS"
     # NaiveDateTime.to_string usually works but defaults to ISO which might have T.
     # We want space.
     dt
     |> NaiveDateTime.truncate(:second)
     |> NaiveDateTime.to_string()
     |> String.replace("T", " ")
  end
end
