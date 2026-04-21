Application.put_env(:orkestra, Orkestra.MessageBus,
  adapter: Orkestra.MessageBus.PubSub,
  app_prefix: nil
)

Application.put_env(:orkestra, Orkestra.MessageBus.PubSub,
  pubsub: Orkestra.PubSub
)

{:ok, _} = Phoenix.PubSub.Supervisor.start_link(name: Orkestra.PubSub)

ExUnit.start()
