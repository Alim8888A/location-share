# 位置共享信令服务器 Docker 镜像
FROM dart:stable

WORKDIR /app
COPY pubspec.* ./
RUN dart pub get --no-precompile
COPY bin bin
COPY public public
RUN dart compile exe bin/server.dart -o app/server

ENV PORT=10000
EXPOSE 10000
CMD ["/app/app/server"]
