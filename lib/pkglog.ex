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

    # Pre-process package patterns
    config = 
      if config.packages != [] do
        packages = 
          Enum.map(config.packages, fn pkg ->
            cond do
              config.glob -> 
                # Basic glob to regex conversion
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

    # Get last boot time
    _boot_time = boot_time # Fix unused warning while keeping the value if needed
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
      last_dt: nil, # NaiveDateTime.from_iso8601("0000-01-01T00:00:00")
      parser_state: parser_mod.initial_state(),
      config: config,
      boot_time: boot_time,
      boot_str: boot_str,
      boot_printed: false
    }

    final_state = 
      Enum.reduce(files, initial_state, fn file, state ->
        process_file(file, parser_mod, start_time, state)
      end)

    # Flush remaining queue
    final_state = output_queue(final_state, true)

    if !final_state.boot_printed and !config.boot and final_state.last_dt do
       print_boot_marker(final_state, trailing: false)
    end
  end

  defp determine_parser(name) when is_binary(name) do
    Map.get(@parsers, name) || System.halt(1) # TODO: Error message
  end

  defp determine_parser(nil) do
    # Try to find existing logfile
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
  defp compute_start_time(days_str) when is_binary(days_str) do
    # Try integer
    case Integer.parse(days_str) do
      {days, ""} ->
        # days ago
        if days == 0 do
           NaiveDateTime.beginning_of_day(NaiveDateTime.local_now())
        else
           Date.add(Date.utc_today(), -days) |> NaiveDateTime.new!(~T[00:00:00])
        end
      _ ->
        # Try parse date
        # Assuming YYYY-MM-DD
        case Date.from_iso8601(days_str) do
          {:ok, date} -> NaiveDateTime.new!(date, ~T[00:00:00])
          _ -> 
             IO.puts("ERROR: Can not parse days value.")
             System.halt(1)
        end
    end
  end
  defp compute_start_time(_), do: nil # Should be handled

  defp get_boot_time() do
    {uptime_str, 0} = System.cmd("cat", ["/proc/uptime"]) # or File.read!
    [uptime_sec | _] = String.split(uptime_str, " ")
    {sec, _} = Float.parse(uptime_sec)
    
    # Boot time = Now - uptime
    NaiveDateTime.add(NaiveDateTime.local_now(), -trunc(sec), :second)
  end

  defp get_log_files(logfile, config) do
    if config.path do
      String.split(config.path, ":")
    else
      path = Path.expand(logfile)
      dir = Path.dirname(path)
      base = Path.basename(path)
      
      # Find all files starting with base
      # e.g. pacman.log, pacman.log.1, pacman.log.2.gz
      # Python sorts them by number extension reversed.
      
      files = 
        case File.ls(dir) do
          {:ok, list} ->
            list
            |> Enum.filter(fn f -> String.starts_with?(f, base) end)
            |> Enum.sort_by(fn f -> 
               # Extract number
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
    
    # Use Stream.resource or simple reduce if line based
    # File.stream! works for lines
    
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
    # 1. Parse time
    case parser_mod.parse_line(line, state.parser_state) do
      {:ok, dt, new_parser_state} ->
        state = %{state | parser_state: new_parser_state}
        
        # Check start time
        if (start_time && NaiveDateTime.compare(dt, start_time) == :lt) or
           (state.config.boot && NaiveDateTime.compare(dt, state.boot_time) == :lt) do
           state
        else
           # Time gap check
           state = 
             if state.last_dt &&
                NaiveDateTime.diff(dt, state.last_dt, :second) > state.config.timegap * 60 &&
                !state.config.installed_net do
                
                output_queue(state, true)
             else
                state
             end
             
           state = %{state | last_dt: dt}
           
           # Get packages
           {pkgs, final_parser_state} = parser_mod.get_packages(state.parser_state)
           state = %{state | parser_state: final_parser_state}
           
           Enum.reduce(pkgs, state, fn {action, pkg, ver}, acc ->
             if MapSet.member?(@actions, action) do
               queue_append(acc, dt, action, pkg, ver)
             else
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
        "installed" -> 
          %{state | installed: Map.put(state.installed, pkg, dt)}
        "removed" -> 
          %{state | installed: Map.delete(state.installed, pkg), 
                    installed_previously: Map.put(state.installed_previously, pkg, dt)}
        _ -> state
      end

    %{state | queue: state.queue ++ [{dt, action, pkg, ver}]}
  end

  defp output_queue(state, _flush \\ false) do
    if state.queue == [] do
      state
    else
      # Process queue
      # 1. Calculate maxlen
      # 2. Filter based on options
      
      filtered = 
        state.queue
        |> Enum.filter(fn {dt, action, pkg, ver} ->
           filter_package(dt, action, pkg, ver, state)
        end)
        |> Enum.map(fn {dt, action, pkg, ver} ->
           color = get_color(action)
           vers_disp = if action != "upgraded" and action != "downgraded" or state.config.verbose, do: "#{ver} #{action}", else: ver
           {dt, pkg, vers_disp, color}
        end)
      
      if filtered != [] do
        # Determine if we should print delimiter
        # Python: if not args.package and not (args.installed or args.installed_only): Queue.delim = 80 * '-'
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
          
        # Output
        {new_state, _} = 
          Enum.reduce(filtered, {state, 0}, fn {dt, pkg, vers, color}, {acc_state, idx} ->
             # Check boot time printing
             {acc_state, printed_boot} = 
               if !acc_state.boot_printed and NaiveDateTime.compare(dt, acc_state.boot_time) == :gt do
                 {print_boot_marker(acc_state), true}
               else
                 {acc_state, false}
               end
             
             # Delimiter logic
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
  
  defp filter_package(dt, action, pkg, _ver, state) do
     # Add filtering logic based on config (updated_only, installed, etc)
     # and installed_net
     
     keep = 
       cond do
         state.config.updated_only and action != "upgraded" and action != "downgraded" -> false
         state.config.installed and action != "installed" and action != "removed" -> false
         state.config.installed_only and action != "installed" -> false
         
         # Package name filtering
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
