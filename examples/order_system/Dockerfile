FROM elixir:1.18-slim

RUN apt-get update && apt-get install -y git curl && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy the entire orkestra repo (library + example)
COPY mix.exs mix.lock ./
COPY lib lib
COPY config config

# Copy the example app
COPY examples/order_system examples/order_system

WORKDIR /app/examples/order_system

# Install deps
RUN mix local.hex --force && mix local.rebar --force
RUN mix deps.get
RUN mix deps.compile

# Setup database and seed
CMD ["sh", "-c", "mix ecto.setup && mix run priv/seeds.exs && iex -S mix"]
