defmodule Pkglog.Parser do
  @moduledoc """
  Behaviour for log parsers.
  """

  @callback parse_line(String.t(), any()) :: {:ok, DateTime.t(), any()} | {:skip, any()}
  @callback get_packages(any()) :: {[{String.t(), String.t(), String.t()}], any()}
  @callback initial_state() :: any()
  @callback logfile() :: String.t()
end
