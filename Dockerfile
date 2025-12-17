FROM alpine:3.20

LABEL maintainer="video2stream"

WORKDIR /app

# 安装 ffmpeg 和 fswatch（可选，用于事件监听）
RUN apk add --no-cache \
    ffmpeg \
    fswatch \
    bash \
  && mkdir -p /app/videos

# 拷贝脚本
COPY stream_watcher.sh /app/stream_watcher.sh

RUN chmod +x /app/stream_watcher.sh

# 默认环境变量（可被外部覆盖）
ENV VIDEO_DIR=/app/videos \
    RTMP_URL=rtmp://zlmediakit:1935/live/stream \
    FFMPEG_BIN=ffmpeg \
    POLL_INTERVAL=5

# 默认命令：启动监听脚本
CMD ["/app/stream_watcher.sh"]


