defmodule Absinthe.Permission.DefaultFetcher do
  def fetch(model: _model, preload: _preload, clause: _clause, extras: _extras) do
    {:ok, nil}
  end
end
