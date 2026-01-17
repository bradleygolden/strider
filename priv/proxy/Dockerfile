# Build stage
FROM hexpm/elixir:1.18.4-erlang-28.2-debian-trixie-20251229-slim AS build

RUN apt-get update -y && apt-get install -y build-essential git \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

WORKDIR /app

RUN mix local.hex --force && \
    mix local.rebar --force

ENV MIX_ENV=prod

# Copy strider source for local path dependency
COPY mix.exs mix.lock ./strider/
COPY lib ./strider/lib/

# Copy proxy source
WORKDIR /app/proxy
COPY priv/proxy/mix.exs ./
RUN mix deps.get --only $MIX_ENV
RUN mix deps.compile

COPY priv/proxy/lib lib
RUN mix compile
RUN mix release

# Runtime stage
FROM debian:trixie-slim

RUN apt-get update -y && \
    apt-get install -y libstdc++6 openssl libncurses6 locales ca-certificates \
    && apt-get clean && rm -f /var/lib/apt/lists/*_*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

WORKDIR /app

COPY --from=build /app/proxy/_build/prod/rel/strider_proxy ./

ENV PROXY_PORT=4000
EXPOSE 4000

CMD ["bin/strider_proxy", "start"]
