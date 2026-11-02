defmodule Pkglog.CLI do
  def main(args) do
    args
    |> parse_args()
    |> process_options()
    |> Pkglog.run()
  end

  def parse_args(args) do
    {opts, argv, _} =
      OptionParser.parse(args,
        switches: [
          days: :string,
          alldays: :boolean,
          boot: :boolean,
          timegap: :float,
          verbose: :boolean,
          no_color: :boolean,
          nojustify: :boolean,
          installed_net: :boolean,
          installed_net_days: :float,
          pacman_actions: :boolean,
          updated_only: :boolean,
          installed: :boolean,
          installed_only: :boolean,
          path: :string,
          glob: :boolean,
          regex: :boolean,
          help: :boolean,
          version: :boolean
        ],
        aliases: [
          d: :days,
          a: :alldays,
          b: :boot,
          t: :timegap,
          v: :verbose,
          c: :no_color,
          j: :nojustify,
          n: :installed_net,
          N: :installed_net_days,
          u: :updated_only,
          i: :installed,
          I: :installed_only,
          e: :explicit_net,
          P: :pacman_actions,
          p: :path,
          g: :glob,
          r: :regex,
          h: :help,
          V: :version
        ]
      )

    {opts, argv}
  end

  def process_options({opts, argv}) do
    if opts[:help] do
      print_help(opts)
      System.halt(0)
    end

    if opts[:version] do
      IO.puts("pkglog #{version()}")
      System.halt(0)
    end

    days =
      cond do
        opts[:alldays] -> -1
        opts[:days] -> opts[:days]
        true -> "30"
      end

    config = %{
      packages: argv,
      days: days,
      boot: opts[:boot] || false,
      verbose: opts[:verbose] || false,
      color: !opts[:no_color] && IO.ANSI.enabled?(),
      updated_only: opts[:updated_only] || false,
      installed: opts[:installed] || opts[:installed_net] || false,
      installed_only: opts[:installed_only] || false,
      installed_net: opts[:installed_net] || false,
      pacman_actions: opts[:pacman_actions] || false,
      explicit_net: opts[:explicit_net] || false,
      installed_net_days: opts[:installed_net_days] || 2.0,
      path: opts[:path],
      nojustify: opts[:nojustify] || false,
      glob: opts[:glob] || false,
      regex: opts[:regex] || false,
      timegap: opts[:timegap] || 2.0
    }

    config
  end

  defp version do
    case Application.spec(:pkglog, :vsn) do
      nil -> Mix.Project.config()[:version] || "unknown"
      vsn -> to_string(vsn)
    end
  end

  # Help menu definition: {section, [{short, long, metavar, description_lines, default}]}
  @help_sections [
    {"Filters",
     [
       {"-u", "--updated-only", nil, ["show *updated* only"], nil},
       {"-i", "--installed", nil, ["show *installed*/*removed* only"], nil},
       {"-I", "--installed-only", nil, ["show *installed* only"], nil},
       {"-n", "--installed-net", nil, ["show *net installed* only"], nil},
       {"-e", "--explicit-net", nil, ["show currently installed *explicit* installs only"], nil},
       {"-P", "--pacman-actions", nil,
        [
          "show actions performed by `pacman` commands; packages pulled",
          "in as dependencies are not shown, installs done with",
          "`--asdeps` are shown as *\"installed as dependency\"*"
        ], nil}
     ]},
    {"Time range",
     [
       {"-d", "--days", "DAYS",
        [
          "show packages from given number of *days ago*, or from",
          "{YYYY-MM-DD[ HH:MM[:SS]]} or {YYYY-MM-DDTHH:MM[:SS]}",
          "(if only a {HH:MM[:SS]} time is given, today is assumed)"
        ], "30"},
       {"-a", "--alldays", nil, ["show packages for *all* days"], nil},
       {"-b", "--boot", nil, ["show only packages updated since *last boot*"], nil},
       {"-t", "--timegap", "TIMEGAP", ["max *minutes* gap between grouped changes"], "2"},
       {"-N", "--installed-net-days", "DAYS",
        ["*days* previously removed before being re-considered", "as new net installed"], "2"}
     ]},
    {"Matching",
     [
       {"-g", "--glob", nil, ["given package name[s] is a *glob* pattern"], nil},
       {"-r", "--regex", nil, ["given package name[s] is a *regular expression*"], nil}
     ]},
    {"Output",
     [
       {"-v", "--verbose", nil, ["be verbose, describe upgrades/downgrades"], nil},
       {"-j", "--nojustify", nil, ["don't right justify version numbers"], nil},
       {"-c", "--no-color", nil, ["do not color output"], nil},
       {"-p", "--path", "PATH", ["alternate log path"], "/var/log/pacman.log"}
     ]},
    {"General",
     [
       {"-h", "--help", nil, ["show this help message and exit"], nil},
       {"-V", "--version", nil, ["show pkglog version and exit"], nil}
     ]}
  ]

  @usage_groups [
    ["-h"],
    ["-u", "-i", "-I", "-n"],
    ["-e"],
    ["-P"],
    [{"-d", "DAYS"}],
    ["-a"],
    ["-b"],
    ["-j"],
    ["-v"],
    ["-c"],
    [{"-p", "PATH"}],
    ["-g", "-r"],
    [{"-t", "TIMEGAP"}],
    [{"-N", "DAYS"}],
    ["-V"]
  ]

  defp print_help(opts) do
    color? = !opts[:no_color] && IO.ANSI.enabled?()

    flag_col =
      @help_sections
      |> Enum.flat_map(fn {_, entries} -> entries end)
      |> Enum.map(&(&1 |> flag_text() |> String.length()))
      |> Enum.max()
      |> Kernel.+(4)

    indent = String.duplicate(" ", 2 + flag_col)

    sections =
      Enum.map(@help_sections, fn {title, entries} ->
        [
          "\n",
          heading(title),
          "\n",
          Enum.map(entries, &help_entry(&1, flag_col, indent))
        ]
      end)

    [
      [:bright, "pkglog", :reset, " - reports a concise log of package changes\n\n"],
      heading("Usage"),
      "\n  ",
      usage(),
      "\n\n",
      heading("Arguments"),
      "\n  ",
      [:yellow, "package", :reset],
      String.duplicate(" ", flag_col - String.length("package")),
      "specific package name[s] to report\n",
      sections
    ]
    |> IO.ANSI.format(color?)
    |> IO.write()
  end

  defp heading(title), do: [:bright, :green, title, ":", :reset]

  defp flag_text({short, long, nil, _, _}), do: "#{short}, #{long}"
  defp flag_text({short, long, meta, _, _}), do: "#{short}, #{long} #{meta}"

  defp help_entry({short, long, meta, [first | rest], default} = entry, flag_col, indent) do
    pad = String.duplicate(" ", flag_col - String.length(flag_text(entry)))

    metavar = if meta, do: [" ", :magenta, meta, :reset], else: []

    default_line =
      if default,
        do: [
          indent,
          :faint,
          "(default: ",
          :reset,
          :bright,
          default,
          :reset,
          :faint,
          ")",
          :reset,
          "\n"
        ],
        else: []

    [
      "  ",
      [:bright, :cyan, short, :reset],
      ", ",
      [:cyan, long, :reset],
      metavar,
      pad,
      markup(first),
      "\n",
      Enum.map(rest, &[indent, markup(&1), "\n"]),
      default_line
    ]
  end

  # Lightweight inline markup for help descriptions:
  #   `code`    -> commands / flags (cyan)
  #   *text*    -> emphasized keyword (bold light green)
  #   {pattern} -> date/time pattern, colored per component
  defp markup(text) do
    ~r/`[^`]+`|\*[^*]+\*|\{[^}]+\}/
    |> Regex.split(text, include_captures: true, trim: true)
    |> Enum.map(fn
      "`" <> rest -> [:cyan, String.trim_trailing(rest, "`"), :reset]
      "*" <> rest -> [:bright, :light_green, String.trim_trailing(rest, "*"), :reset]
      "{" <> rest -> rest |> String.trim_trailing("}") |> date_pattern()
      plain -> plain
    end)
  end

  # Colors YYYY-MM-DD (yellow) and HH:MM:SS (blue) components, highlights the
  # "T" separator, and dims optional-part brackets and separators.
  defp date_pattern(pattern) do
    start = if String.starts_with?(pattern, ["H", "["]), do: :time, else: :date

    pattern
    |> String.graphemes()
    |> Enum.chunk_by(&date_token_kind/1)
    |> Enum.map_reduce(start, fn [c | _] = chunk, part ->
      str = Enum.join(chunk)

      case date_token_kind(c) do
        :letter -> {[if(part == :date, do: :yellow, else: :light_blue), str, :reset], part}
        :t_sep -> {[:bright, :magenta, str, :reset], :time}
        :space -> {str, :time}
        _ -> {[:faint, str, :reset], part}
      end
    end)
    |> elem(0)
  end

  defp date_token_kind("T"), do: :t_sep
  defp date_token_kind(" "), do: :space
  defp date_token_kind(c) when c in ["[", "]", "-", ":"], do: :punct
  defp date_token_kind(_), do: :letter

  defp usage do
    prefix = "pkglog "
    wrap_at = 76
    cont = String.duplicate(" ", 2 + String.length(prefix))

    {lines, current, _} =
      (@usage_groups ++ [:package])
      |> Enum.reduce({[], [], String.length(prefix)}, fn group, {lines, cur, width} ->
        {plain, colored} = usage_group(group)
        len = String.length(plain) + 1

        if width + len > wrap_at and cur != [] do
          {[Enum.reverse(cur) | lines], [colored], len}
        else
          {lines, [colored | cur], width + len}
        end
      end)

    all_lines = Enum.reverse([Enum.reverse(current) | lines])

    [
      [:bright, prefix, :reset],
      all_lines
      |> Enum.map(&Enum.intersperse(&1, " "))
      |> Enum.intersperse(["\n", cont])
    ]
  end

  defp usage_group(:package) do
    {"[package ...]", [:faint, "[", :reset, :yellow, "package ...", :reset, :faint, "]", :reset]}
  end

  defp usage_group(flags) do
    parts =
      Enum.map(flags, fn
        {flag, meta} ->
          {"#{flag} #{meta}", [:cyan, flag, :reset, " ", :magenta, meta, :reset]}

        flag ->
          {flag, [:cyan, flag, :reset]}
      end)

    plain = "[" <> Enum.map_join(parts, " | ", &elem(&1, 0)) <> "]"

    colored = [
      :faint,
      "[",
      :reset,
      parts |> Enum.map(&elem(&1, 1)) |> Enum.intersperse([:faint, " | ", :reset]),
      :faint,
      "]",
      :reset
    ]

    {plain, colored}
  end
end
