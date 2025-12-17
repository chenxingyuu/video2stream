#!/usr/bin/env bash

###############################################################################
# 简介：
#  - 监听指定目录中的视频文件
#  - 一旦发现有未处理的视频文件，就使用 ffmpeg 进行“模拟推流”
#
# 使用前请先修改下面的配置区：
###############################################################################

set -euo pipefail

###############################################################################
# 配置区（支持通过环境变量覆盖）
###############################################################################

# 要监听的视频目录（容器内默认 /app/videos）
# 可通过环境变量 VIDEO_DIR 覆盖
VIDEO_DIR="${VIDEO_DIR:-/app/videos}"

# 推流的 RTMP 基础地址（不包含流名，默认指向 docker-compose 中的 zlmediakit 服务）
# 实际推流地址会是：${RTMP_URL}/{文件名去掉扩展名}
# 可通过环境变量 RTMP_URL 覆盖
RTMP_URL="${RTMP_URL:-rtmp://zlmediakit:1935/live}"

# ffmpeg 路径（如果在 PATH 里，可直接用 ffmpeg）
# 可通过环境变量 FFMPEG_BIN 覆盖
FFMPEG_BIN="${FFMPEG_BIN:-ffmpeg}"

# 支持的视频后缀（小写）
# 可通过环境变量 VIDEO_EXTENSIONS 配置，逗号分隔，例如：mp4,flv,mkv
if [[ -n "${VIDEO_EXTENSIONS:-}" ]]; then
  IFS=',' read -r -a VIDEO_EXTENSIONS <<< "$VIDEO_EXTENSIONS"
else
  VIDEO_EXTENSIONS=("mp4" "flv" "mkv" "mov" "avi")
fi

# 轮询间隔（秒），如果没有安装 fswatch，就用这个间隔定时扫描目录
# 可通过环境变量 POLL_INTERVAL 覆盖
POLL_INTERVAL="${POLL_INTERVAL:-5}"

# 处理完成后的视频移动到的目录（仅轮询模式使用）
PROCESSED_DIR="${VIDEO_DIR}/processed"

# 存放每个文件对应推流 PID 的目录（仅 fswatch 事件模式使用）
# 会把文件路径做简单转义作为文件名，内容为对应 ffmpeg 的 PID
PID_DIR="${PID_DIR:-${VIDEO_DIR}/.pids}"

###############################################################################
# 函数定义（保证所有函数在使用前定义）
###############################################################################

is_supported_video_file() {
  local file="$1"
  local filename ext

  filename=$(basename -- "$file")
  ext="${filename##*.}"
  ext=$(printf '%s' "$ext" | tr 'A-Z' 'a-z')

  for e in "${VIDEO_EXTENSIONS[@]}"; do
    if [[ "$ext" == "$e" ]]; then
      return 0
    fi
  done

  return 1
}

ensure_directories() {
  if [[ ! -d "$VIDEO_DIR" ]]; then
    mkdir -p "$VIDEO_DIR"
  fi

  if [[ ! -d "$PROCESSED_DIR" ]]; then
    mkdir -p "$PROCESSED_DIR"
  fi

  if [[ ! -d "$PID_DIR" ]]; then
    mkdir -p "$PID_DIR"
  fi
}

build_stream_url_for_file() {
  # 根据“完整路径”生成推流地址：
  #  - 文件名: /path/to/foo.mp4
  #  - 基础地址: rtmp://host/live
  #  - 结果: rtmp://host/live/path-to-foo.mp4
  local file="$1"
  local normalized base url

  # 去掉开头的 /，并把路径分隔符 / 替换为 -
  normalized=$(printf '%s' "$file" | sed 's,^/,,; s,/, -,g')

  base="$RTMP_URL"
  if [[ -z "$base" ]]; then
    echo "错误：RTMP_URL 为空，无法构建推流地址" >&2
    exit 1
  fi

  if [[ "${base: -1}" == "/" ]]; then
    url="${base}${normalized}"
  else
    url="${base}/${normalized}"
  fi

  printf '%s\n' "$url"
}

pidfile_for_path() {
  # 把绝对路径中的 / 和空格等替换掉，避免作为文件名出问题
  local file="$1"
  local safe

  safe=$(printf '%s' "$file" | sed 's/[\/[:space:]]/_/g')
  printf '%s/%s.pid\n' "$PID_DIR" "$safe"
}

stop_stream_if_running() {
  local file="$1"
  local pid_file pid

  pid_file=$(pidfile_for_path "$file")

  if [[ ! -f "$pid_file" ]]; then
    return 0
  fi

  pid=$(cat "$pid_file" 2>/dev/null || true)
  if [[ -z "$pid" ]]; then
    return 0
  fi

  if kill -0 "$pid" >/dev/null 2>&1; then
    echo "检测到文件正在推流，先停止旧推流: $file (pid=$pid)"
    # 优雅停止
    kill "$pid" >/dev/null 2>&1 || true
    # 等待进程退出，避免僵尸进程
    wait "$pid" 2>/dev/null || true
  fi

  rm -f "$pid_file"
}

start_stream_background() {
  local file="$1"
  local pid_file pid stream_url

  pid_file=$(pidfile_for_path "$file")

  # 同一个文件如果已经在推流，先停掉旧的
  stop_stream_if_running "$file"

  echo "开始推流文件（后台运行）: $file"

  stream_url=$(build_stream_url_for_file "$file")

  "$FFMPEG_BIN" -re -stream_loop -1 -i "$file" \
    -c copy \
    -f flv "$stream_url" &

  pid=$!
  echo "$pid" > "$pid_file"
  echo "推流进程 PID: $pid"
}

find_next_video_file() {
  # 查找目录中第一个符合后缀的视频文件
  local f
  for f in "$VIDEO_DIR"/*; do
    if [[ -f "$f" ]] && is_supported_video_file "$f"; then
      printf '%s\n' "$f"
      return 0
    fi
  done

  return 1
}

do_stream_file() {
  local file="$1"
  local stream_url

  echo "开始推流文件: $file"

  # -re 表示按原始帧率读文件，实现“模拟实时推流”
  # 可以根据需要调整编码参数
  stream_url=$(build_stream_url_for_file "$file")

  "$FFMPEG_BIN" -re -stream_loop -1 -i "$file" \
    -c copy \
    -f flv "$stream_url"
}

process_one_file() {
  local file="$1"
  local base target

  if [[ ! -f "$file" ]]; then
    echo "文件不存在: $file"
    return 1
  fi

  # 推流（阻塞直到 ffmpeg 退出）
  do_stream_file "$file"

  # 推流结束后移动到 processed 目录，避免重复推流
  base=$(basename -- "$file")
  target="${PROCESSED_DIR}/${base}"

  mv "$file" "$target"
  echo "已将文件移动到: $target"
}

process_one_file_event_mode() {
  # fswatch 事件模式下使用：
  # - 不移动原文件（方便多次修改同一文件）
  # - 对同一文件，如果已有推流，则先杀掉旧推流再重新推
  local file="$1"

  if [[ ! -f "$file" ]]; then
    echo "文件不存在: $file"
    return 1
  fi

  start_stream_background "$file"
}

watch_loop_polling() {
  echo "使用轮询模式监听目录: $VIDEO_DIR"
  echo "轮询间隔: ${POLL_INTERVAL} 秒"

  while true; do
    if next_file=$(find_next_video_file); then
      process_one_file "$next_file"
    else
      sleep "$POLL_INTERVAL"
    fi
  done
}

watch_loop_fswatch() {
  echo "检测到 fswatch，可使用事件驱动模式监听目录: $VIDEO_DIR"

  fswatch -0 "$VIDEO_DIR" | while IFS= read -r -d '' path; do
    if [[ -f "$path" ]] && is_supported_video_file "$path"; then
      process_one_file_event_mode "$path"
    fi
  done
}

main() {
  ensure_directories

  if ! command -v "$FFMPEG_BIN" >/dev/null 2>&1; then
    echo "错误：未找到 ffmpeg（当前设置为: $FFMPEG_BIN）" >&2
    echo "请先安装 ffmpeg 或修改脚本中的 FFMPEG_BIN 变量。" >&2
    exit 1
  fi

  if command -v fswatch >/dev/null 2>&1; then
    watch_loop_fswatch
  else
    watch_loop_polling
  fi
}

main "$@"


