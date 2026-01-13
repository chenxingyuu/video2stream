# 第一阶段：构建 Go HTTP 服务
FROM golang:1.21-alpine AS builder

WORKDIR /build

# 复制 Go 模块文件和源代码
COPY go.mod ./
COPY main.go ./

# 下载依赖并生成 go.sum（如果不存在）
RUN go mod download && go mod tidy

# 构建二进制文件
RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o video2stream-api .

# 第二阶段：最终镜像
FROM alpine:3.20

LABEL maintainer="video2stream"

WORKDIR /app

# 安装 ffmpeg（用于推流）、bash 和字体（drawtext 需要）
# 说明：Alpine 官方源没有提供 fswatch，这里容器内默认使用轮询模式；
# 如果需要事件模式，可以在宿主机安装 fswatch 再直接运行脚本。
RUN apk add --no-cache \
    ffmpeg \
    bash \
    ttf-dejavu \
  && mkdir -p /app/videos

# 从构建阶段复制 Go 服务二进制文件
COPY --from=builder /build/video2stream-api /app/video2stream-api

# 拷贝脚本
COPY stream_watcher.sh /app/stream_watcher.sh

RUN chmod +x /app/stream_watcher.sh /app/video2stream-api

# 默认环境变量（可被外部覆盖）
ENV VIDEO_DIR=/app/videos \
    RTMP_URL=rtmp://zlmediakit:1935/live \
    FFMPEG_BIN=ffmpeg \
    POLL_INTERVAL=5 \
    HTTP_PORT=8081 \
    WATCHER_SCRIPT=/app/stream_watcher.sh

# 暴露 HTTP API 端口
EXPOSE 8081

# 默认命令：启动 Go HTTP 服务（它会管理 stream_watcher.sh 的启动/停止）
CMD ["/app/video2stream-api"]
