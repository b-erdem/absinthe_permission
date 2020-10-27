defmodule Absinthe.Permission.DefaultFetcher do
  def fetch(_context, _condition, _args, _user_context) do
    {:ok, nil}
  end
end
