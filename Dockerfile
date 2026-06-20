# Dockerfile for Sub Zero aggregator

FROM crystallang/crystal:1.13.3-alpine AS builder

WORKDIR /app

COPY shard.yml ./
RUN shards install
RUN shards update

COPY . .

RUN crystal build src/main.cr --release --static --no-debug -o sub_zero

FROM alpine:3.19

RUN apk add --no-cache libcrypto3 libssl3

WORKDIR /app

COPY --from=builder /app/sub_zero .

EXPOSE 3000

CMD ["./sub_zero"]
