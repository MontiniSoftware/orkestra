FROM elixir:1.18-slim

RUN apt-get update && apt-get install -y git curl && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy the orkestra library (the example depends on it via path: "../..")
COPY mix.exs mix.lock ./
COPY lib lib

# Build the MCP escript
COPY orkestra_mcp orkestra_mcp
RUN cd orkestra_mcp && mix local.hex --force && mix local.rebar --force \
    && mix deps.get && mix escript.build

# Copy the example app
COPY examples/order_system examples/order_system

WORKDIR /app/examples/order_system

# Install deps
RUN mix local.hex --force && mix local.rebar --force
RUN mix deps.get
RUN mix deps.compile

# Setup database and seed on start
CMD ["sh", "-c", "mix ecto.setup && mix run priv/seeds.exs && iex -S mix"]
