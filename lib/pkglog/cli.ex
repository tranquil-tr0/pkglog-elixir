defmodule Pkglog.CLI do
  import IO.ANSI

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
      print_help()
      System.halt(0)
    end

    if opts[:version] do
      IO.puts("pkglog 0.1.0")
      System.halt(0)
    end

    # Defaults
    days =
      cond do
        opts[:alldays] -> -1
        # Will parse later
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
      installed_net_days: opts[:installed_net_days] || 2.0,
      path: opts[:path],
      nojustify: opts[:nojustify] || false,
      glob: opts[:glob] || false,
      regex: opts[:regex] || false,
      timegap: opts[:timegap] || 2.0
    }

    config
  end

  defp print_help do
    IO.puts(
      IO.ANSI.format([
        bright(),
        "usage: pkglog ",
        yellow(),
        "[-h] [-u | -i | -I | -n] [-d DAYS] [-a] [-b] [-j] [-v] [-c]",
        IO.ANSI.format_fragment(
          [" ", yellow(), "[-p PATH] [-g | -r] [-t TIMEGAP] [-N DAYS] [-V]\n"],
          true
        ),
        "              ",
        IO.ANSI.reset(),
        "[package ...]\n\n",
        "Reports concise log of package changes.\n\n",
        IO.ANSI.format_fragment([green(), "positional arguments:\n"], true),
        "  ",
        IO.ANSI.format_fragment([yellow(), "package"], true),
        "               specific package name[s] to report\n\n",
        IO.ANSI.format_fragment([green(), "options:\n"], true),
        IO.ANSI.format_fragment([yellow(), "  -h, --help"], true),
        "            show this help message and exit\n",
        IO.ANSI.format_fragment([yellow(), "  -u, --updated-only"], true),
        "    show updated only\n",
        IO.ANSI.format_fragment([yellow(), "  -i, --installed"], true),
        "       show installed/removed only\n",
        IO.ANSI.format_fragment([yellow(), "  -I, --installed-only"], true),
        "  show installed only\n",
        IO.ANSI.format_fragment([yellow(), "  -n, --installed-net"], true),
        "   show net installed only\n",
        IO.ANSI.format_fragment([yellow(), "  -d, --days DAYS"], true),
        "       show all packages only from given number of days ago,\n",
        "                            or from given YYYY-MM-DD, default=30\n",
        IO.ANSI.format_fragment([yellow(), "  -a, --alldays"], true),
        "         show all packages for all days\n",
        IO.ANSI.format_fragment([yellow(), "  -b, --boot"], true),
        "            show only packages updated since last boot\n",
        IO.ANSI.format_fragment([yellow(), "  -j, --nojustify"], true),
        "       don't right justify version numbers\n",
        IO.ANSI.format_fragment([yellow(), "  -v, --verbose"], true),
        "         be verbose, describe upgrades/downgrades\n",
        IO.ANSI.format_fragment([yellow(), "  -c, --no-color"], true),
        "        do not color output lines\n",
        IO.ANSI.format_fragment([yellow(), "  -p, --path PATH"], true),
        "       alternate log path\n",
        IO.ANSI.format_fragment([yellow(), "  -g, --glob"], true),
        "            given package name[s] is glob pattern to match\n",
        IO.ANSI.format_fragment([yellow(), "  -r, --regex"], true),
        "            given package name[s] is regular expression to match\n",
        IO.ANSI.format_fragment([yellow(), "  -t, --timegap TIMEGAP"], true),
        "  max minutes gap between grouped changes, default=2\n",
        IO.ANSI.format_fragment([yellow(), "  -N, --installed-net-days DAYS"], true),
        "\n",
        "                            days previously removed before being re-considered as\n",
        "                            new net installed, default=2\n",
        IO.ANSI.format_fragment([yellow(), "  -V, --version"], true),
        "         just show pkglog version\n"
      ])
    )
  end
end
