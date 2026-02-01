defmodule Pkglog.Parsers.Pacman do
  @behaviour Pkglog.Parser

  @impl true
  def logfile(), do: "/var/log/pacman.log"

  @impl true
  def initial_state(), do: ""

  @impl true
  def parse_line(line, _state) do
    # Expected format: [2022-10-25T08:52:12-0400] [ALPM] upgraded ...
    # Or old: [2022-10-25 08:52:12-0400] ...
    
    with [dts_raw, linetype, rest] <- String.split(line, " ", parts: 3),
         true <- linetype in ["[ALPM]", "[PACMAN]"] do
      
      dts = 
        dts_raw
        |> String.trim_leading(<<0>>)
        |> String.trim()
        |> String.trim_leading("[")
        |> String.trim_trailing("]")
      
      # Handle space instead of T if present (old format)
      dts = 
        if String.length(dts) > 10 and String.at(dts, 10) == " " do
          String.replace(dts, " ", "T", global: false)
        else
          dts
        end

      case DateTime.from_iso8601(dts) do
        {:ok, dt, offset_seconds} ->
          # Convert to naive wall time (apply offset to UTC)
          naive = 
             dt
             |> DateTime.to_naive()
             |> NaiveDateTime.add(offset_seconds, :second)
          {:ok, naive, rest}
        _ ->
          {:skip, ""}
      end
    else
      _ -> {:skip, ""}
    end
  end

  @impl true
  def get_packages(line_content) do
    # content: "upgraded package (1.0 -> 1.1)"
    # or "installed package (1.0)"
    case String.split(line_content, " ", parts: 3) do
      [action, pkg, ver_raw] ->
        ver = String.trim_trailing(ver_raw) |> String.trim_trailing(")") |> String.trim_leading("(")
        {[{action, pkg, ver}], ""}
      _ ->
        {[], ""}
    end
  end
end
