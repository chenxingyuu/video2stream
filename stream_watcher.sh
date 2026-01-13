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

# 推流失败重试次数（只在轮询模式下生效）
#  - >0：失败达到该次数后会被标记为失败，不再重试
#  - <=0：表示无限重试，永不标记为失败
RETRY_MAX_ATTEMPTS="${RETRY_MAX_ATTEMPTS:-3}"

# 轮询模式下的处理状态记录目录（不再移动源视频文件）
#  - STATE_DIR/processed.list    记录已成功推流的文件（绝对路径）
#  - STATE_DIR/failed.list       记录推流失败的文件（绝对路径，已达到最大重试次数）
#  - STATE_DIR/in_progress.list  记录正在推流中的文件（绝对路径）
#  - STATE_DIR/retry.list        记录每个文件已失败的次数（格式：<path>|<count>）
# 默认放在 /app/.state，与视频目录分离
STATE_DIR="${STATE_DIR:-/app/.state}"
PROCESSED_LIST="${STATE_DIR}/processed.list"
FAILED_LIST="${STATE_DIR}/failed.list"
IN_PROGRESS_LIST="${STATE_DIR}/in_progress.list"
RETRY_LIST="${STATE_DIR}/retry.list"

# ffmpeg 日志目录（按文件名输出到独立日志，避免刷屏 docker 日志）
# 默认放在 /app/.logs，与状态目录分离
FFMPEG_LOG_DIR="${FFMPEG_LOG_DIR:-/app/ffmpeg_logs}"

# 存放每个文件对应推流 PID 的目录（仅 fswatch 事件模式使用）
# 会把文件路径做简单转义作为文件名，内容为对应 ffmpeg 的 PID
# 默认放在 /app/.pids，与视频目录分离
PID_DIR="${PID_DIR:-/app/.pids}"

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

  if [[ ! -d "$PID_DIR" ]]; then
    mkdir -p "$PID_DIR"
  fi

  if [[ ! -d "$STATE_DIR" ]]; then
    mkdir -p "$STATE_DIR"
  fi

  if [[ ! -d "$FFMPEG_LOG_DIR" ]]; then
    mkdir -p "$FFMPEG_LOG_DIR"
  fi

  # 状态文件如果不存在则创建为空文件
  if [[ ! -f "$PROCESSED_LIST" ]]; then
    : > "$PROCESSED_LIST"
  fi

  if [[ ! -f "$FAILED_LIST" ]]; then
    : > "$FAILED_LIST"
  fi

  if [[ ! -f "$IN_PROGRESS_LIST" ]]; then
    : > "$IN_PROGRESS_LIST"
  fi

  if [[ ! -f "$RETRY_LIST" ]]; then
    : > "$RETRY_LIST"
  fi
}

is_file_in_list() {
  local list="$1"
  local file="$2"

  if [[ ! -f "$list" ]]; then
    return 1
  fi

  # 精确匹配整行，避免部分匹配
  if grep -Fx -- "$file" "$list" >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

mark_file_in_list() {
  local list="$1"
  local file="$2"

  # 先检查是否已经存在，避免重复写入
  if ! is_file_in_list "$list" "$file"; then
    printf '%s\n' "$file" >> "$list"
  fi
}

mark_file_in_progress() {
  local file="$1"
  mark_file_in_list "$IN_PROGRESS_LIST" "$file"
}

remove_file_from_list() {
  local list="$1"
  local file="$2"

  if [[ ! -f "$list" ]]; then
    return 0
  fi

  # 删除匹配该路径的整行
  local tmp
  tmp="${list}.tmp.$$"
  if ! grep -Fvx -- "$file" "$list" >"$tmp" 2>/dev/null; then
    # 如果 grep 失败（例如没找到匹配），保留原文件内容
    cp "$list" "$tmp" 2>/dev/null || :
  fi
  mv "$tmp" "$list"
}

get_retry_count() {
  local file="$1"
  local line count

  if [[ ! -f "$RETRY_LIST" ]]; then
    printf '%s\n' "0"
    return 0
  fi

  # 行格式：<path>|<count>
  line=$(grep -F -- "$file|" "$RETRY_LIST" 2>/dev/null | head -n 1 || true)
  if [[ -z "$line" ]]; then
    printf '%s\n' "0"
    return 0
  fi

  count="${line##*|}"
  if [[ -z "$count" ]]; then
    printf '%s\n' "0"
  else
    printf '%s\n' "$count"
  fi
}

set_retry_count() {
  local file="$1"
  local count="$2"
  local tmp

  if [[ ! -f "$RETRY_LIST" ]]; then
    : > "$RETRY_LIST"
  fi

  tmp="${RETRY_LIST}.tmp.$$"
  # 删除旧记录
  if ! grep -Fv -- "$file|" "$RETRY_LIST" >"$tmp" 2>/dev/null; then
    cp "$RETRY_LIST" "$tmp" 2>/dev/null || :
  fi
  printf '%s|%s\n' "$file" "$count" >>"$tmp"
  mv "$tmp" "$RETRY_LIST"
}

increment_retry_and_should_stop() {
  # 返回 0 表示还可以重试，返回 1 表示达到上限，应标记为失败
  local file="$1"
  local current next

  current=$(get_retry_count "$file")
  next=$((current + 1))
  set_retry_count "$file" "$next"

  # RETRY_MAX_ATTEMPTS <= 0 表示无限重试
  if [[ "${RETRY_MAX_ATTEMPTS:-0}" -le 0 ]]; then
    echo "文件推流失败，将无限重试（当前失败次数: ${next})：$file"
    return 0
  fi

  if [[ "$next" -ge "$RETRY_MAX_ATTEMPTS" ]]; then
    echo "文件已达到最大重试次数(${RETRY_MAX_ATTEMPTS})，将标记为失败: $file"
    return 1
  fi

  echo "文件推流失败，将在后续轮询中重试（当前失败次数: ${next}/${RETRY_MAX_ATTEMPTS}）: $file"
  return 0
}

build_stream_url_for_file() {
  # 根据“文件名”生成推流地址：
  #  - 文件名: /path/to/foo.mp4
  #  - 基础地址: rtmp://host/live
  #  - 结果: rtmp://host/live/foo（空白会被替换为 -，不带扩展名）
  local file="$1"
  local name name_no_ext normalized base url

  # 使用 basename 取纯文件名，去掉扩展名，并将所有空白字符替换为 -
  name=$(basename -- "$file")
  name_no_ext="${name%.*}"
  normalized=$(printf '%s' "$name_no_ext" | sed -e 's|[[:space:]]\+|-|g')

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
  local pid_file pid stream_url log_file cmd

  pid_file=$(pidfile_for_path "$file")

  # 同一个文件如果已经在推流，先停掉旧的
  stop_stream_if_running "$file"

  echo "开始推流文件（后台运行）: $file"

  stream_url=$(build_stream_url_for_file "$file")
  log_file="${FFMPEG_LOG_DIR}/$(basename -- "$file").log"

  # 构建 drawtext 滤镜（显示当前系统时间）
  # 注意：已安装 ttf-dejavu 字体，drawtext 可以正常工作
  cmd="$FFMPEG_BIN -re -stream_loop -1 -i \"$file\" -vf \"drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf:text='%{localtime}':fontsize=24:fontcolor=white:x=w-tw-10:y=10\" -c:v libx264 -preset veryfast -tune zerolatency -an -f flv \"$stream_url\""
  echo "FFMPEG_CMD (background): $cmd > \"$log_file\" 2>&1"

  # 实际执行时将 ffmpeg 日志写入独立文件，避免刷屏 docker 日志
  # -an 表示不包含音频流
  # -vf drawtext 在右上角显示当前系统时间（格式由 ffmpeg 自动决定）
  # 使用 fontfile 指定字体路径，确保在 Alpine 中正常工作
  $FFMPEG_BIN -re -stream_loop -1 -i "$file" \
    -vf "drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf:text='%{localtime}':fontsize=24:fontcolor=white:x=w-tw-10:y=10" \
    -c:v libx264 -preset veryfast -tune zerolatency \
    -an \
    -f flv "$stream_url" >"$log_file" 2>&1 &

  pid=$!
  echo "$pid" > "$pid_file"
  echo "推流进程 PID: $pid"
}

find_next_video_file() {
  # 查找目录中第一个符合后缀的视频文件
  local f
  for f in "$VIDEO_DIR"/*; do
    if [[ -f "$f" ]] && is_supported_video_file "$f"; then
      # 已经处理过（成功、失败或正在处理）的文件不再重复处理
      if is_file_in_list "$PROCESSED_LIST" "$f" \
        || is_file_in_list "$FAILED_LIST" "$f" \
        || is_file_in_list "$IN_PROGRESS_LIST" "$f"; then
        continue
      fi

      printf '%s\n' "$f"
      return 0
    fi
  done

  return 1
}

do_stream_file() {
  local file="$1"
  local stream_url log_file cmd

  echo "开始推流文件: $file"

  # -re 表示按原始帧率读文件，实现“模拟实时推流”
  # 可以根据需要调整编码参数
  stream_url=$(build_stream_url_for_file "$file")
  log_file="${FFMPEG_LOG_DIR}/$(basename -- "$file").log"

  # 构建 drawtext 滤镜（显示当前系统时间）
  # 注意：已安装 ttf-dejavu 字体，drawtext 可以正常工作
  cmd="$FFMPEG_BIN -re -stream_loop -1 -i \"$file\" -vf \"drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf:text='%{localtime}':fontsize=24:fontcolor=white:x=w-tw-10:y=10\" -c:v libx264 -preset veryfast -tune zerolatency -an -f flv \"$stream_url\""
  echo "FFMPEG_CMD: $cmd > \"$log_file\" 2>&1"

  # 将 ffmpeg 的 stdout/stderr 重定向到文件中，避免刷屏 docker 日志
  # -an 表示不包含音频流
  # -vf drawtext 在右上角显示当前系统时间（格式由 ffmpeg 自动决定）
  # 使用 fontfile 指定字体路径，确保在 Alpine 中正常工作
  $FFMPEG_BIN -re -stream_loop -1 -i "$file" \
    -vf "drawtext=fontfile=/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf:text='%{localtime}':fontsize=24:fontcolor=white:x=w-tw-10:y=10" \
    -c:v libx264 -preset veryfast -tune zerolatency \
    -an \
    -f flv "$stream_url" >"$log_file" 2>&1
}

process_one_file() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo "文件不存在: $file"
    return 1
  fi

  # 推流（阻塞直到 ffmpeg 退出），如果失败则仅记录状态，不影响主循环
  if ! do_stream_file "$file"; then
    echo "推流失败，记录失败状态并跳过该文件: $file"
    mark_file_in_list "$FAILED_LIST" "$file"
    return 0
  fi

  # 推流成功后记录成功状态，避免重复推流
  echo "推流成功，记录成功状态: $file"
  mark_file_in_list "$PROCESSED_LIST" "$file"
}

run_stream_job_background() {
  # 在后台为单个文件启动一个推流任务：
  #  - 立即标记为 in_progress，避免轮询时重复启动
  #  - 任务结束后根据结果写入 processed 或 failed
  local file="$1"

  if [[ ! -f "$file" ]]; then
    echo "文件不存在: $file"
    return 1
  fi

  mark_file_in_progress "$file"

  (
    if ! do_stream_file "$file"; then
      echo "推流失败（后台任务）: $file"
      if ! increment_retry_and_should_stop "$file"; then
        # 未达到最大重试次数，本次失败仅记录重试次数，不加入 FAILED_LIST
        :
      else
        # 达到最大次数，标记为失败
        mark_file_in_list "$FAILED_LIST" "$file"
      fi
    else
      echo "推流成功（后台任务），记录成功状态: $file"
      mark_file_in_list "$PROCESSED_LIST" "$file"
    fi
    # 无论成功或失败，任务结束时都要从 in_progress 中移除
    remove_file_from_list "$IN_PROGRESS_LIST" "$file"
  ) &
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
      # 使用后台任务推流，可并发处理多个文件
      run_stream_job_background "$next_file"
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


