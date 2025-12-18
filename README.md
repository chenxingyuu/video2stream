## video2stream

一个简单的“目录 → 推流”工具：  
监听指定目录中的视频文件，一旦发现有可用的视频，就通过 `ffmpeg` 向流媒体服务器（如 ZLMediaKit）进行模拟实时推流。

主要用途：
- **本地开发 / 调试**：自动把目录里的测试视频推到你的流媒体服务器。
- **离线文件回放**：通过 RTMP/RTSP/HTTP-FLV/HLS 等协议对录制文件进行“伪直播”。

---

## 功能说明

- **目录监听**：监控一个目录下的视频文件。
- **自动推流**：发现新文件或文件内容更新后，自动用 `ffmpeg` 推流。
- **并发推流**：支持同时推流多个视频文件，每个文件使用独立的 ffmpeg 进程。
- **失败重试**：推流失败时自动重试，支持配置最大重试次数或无限重试。
- **状态管理**：使用文件记录推流状态（成功/失败/进行中），不移动源视频文件。
- **HTTP API 控制**：提供 RESTful API 用于启动、停止、重启推流服务。
- **事件模式（fswatch）**：
  - 有 `fswatch` 时使用事件驱动监听。
  - 同一个文件多次修改时，**会先停止旧的推流进程，再启动新的推流**，保证同一文件只存在一个推流。
- **轮询模式**：
  - 没有 `fswatch` 时，按固定间隔轮询目录。
  - 使用状态文件记录处理结果，源文件保留在原目录。

核心组件：
- **推流脚本**：`stream_watcher.sh`（监听目录并推流）
- **HTTP API 服务**：`main.go`（Go + Gin，管理推流脚本生命周期）
- **容器镜像**：`registry.cn-hangzhou.aliyuncs.com/video2stream/video2stream:...`

---

## 快速开始（Docker Compose）

项目内已提供 `docker-compose.yml`，默认会同时启动：
- 一个 **ZLMediaKit** 流媒体服务。
- 一个 **video2stream-watcher** 目录监听 + 推流容器。

### 1. 启动服务

在项目根目录执行：

```bash
docker compose up -d
```

启动后包含：

- `zlmediakit`
  - RTMP：`1935`
  - RTSP：`554`
  - Web/API：`8000`（映射容器内 80 端口）
  - HTTP-FLV / HLS：`8080`
- `video2stream-watcher`
  - 挂载宿主机目录：`./videos` → 容器内 `/app/videos`
  - HTTP API：`8081`（用于控制推流服务）
  - **容器启动后会自动启动推流脚本**（可通过 `AUTO_START=false` 禁用）

### 2. 放入测试视频

将测试视频复制到项目根目录下的 `videos/` 目录：

```bash
mkdir -p videos
cp /path/to/test.mp4 ./videos/
```

监听脚本会自动检测到新文件并开始推流。

### 3. 播放推流

在本机上可以用以下地址播放（以默认 ZLMediaKit 配置为例），假设你放入的文件名为 `test.mp4`：

**流名规则**：使用文件名（去掉扩展名），空白字符会被替换为 `-`

- RTMP：`rtmp://127.0.0.1:1935/live/test`
- HTTP-FLV：`http://127.0.0.1:8080/live/test.live.flv`
- HLS：`http://127.0.0.1:8080/live/test/hls.m3u8`

例如文件名为 `雪糕桶 违规摆放.mp4`，流名会是 `雪糕桶-违规摆放`。

可用 VLC、ffplay 或浏览器（配合前端播放器）进行播放。

### 4. HTTP API 控制（可选）

容器启动后，推流脚本会自动运行。你也可以通过 HTTP API 手动控制：

```bash
# 查看推流服务状态
curl http://127.0.0.1:8081/api/stream/status

# 停止推流服务
curl -X POST http://127.0.0.1:8081/api/stream/stop

# 启动推流服务
curl -X POST http://127.0.0.1:8081/api/stream/start

# 重启推流服务
curl -X POST http://127.0.0.1:8081/api/stream/restart
```

---

## 环境变量与配置

所有关键配置都可以通过环境变量控制，既可在宿主机运行脚本时传入，也可在 Docker / Compose 中配置。

### 目录监听脚本（stream_watcher.sh）

支持的环境变量：

- **`VIDEO_DIR`**
  - 说明：要监听的视频目录。
  - 默认（容器内）：`/app/videos`
  - 示例：
    ```bash
    VIDEO_DIR=/data/videos ./stream_watcher.sh
    ```

- **`RTMP_URL`**
  - 说明：推流基础地址（不含流名），实际推流地址为 `RTMP_URL/{文件名去掉扩展名}`。
  - 默认：`rtmp://zlmediakit:1935/live`  
    （在 docker-compose 中指向 `zlmediakit` 服务）
  - 流名生成规则：
    - 使用文件名（`basename`），去掉扩展名
    - 将所有空白字符替换为 `-`
    - 例如：`test.mp4` → `test`，`雪糕桶 违规摆放.mp4` → `雪糕桶-违规摆放`
  - 示例（推到外部 ZLMediaKit）：
    ```bash
    RTMP_URL=rtmp://192.168.1.10:1935/live ./stream_watcher.sh
    ```

- **`FFMPEG_BIN`**
  - 说明：`ffmpeg` 可执行文件路径。
  - 默认：`ffmpeg`

- **`POLL_INTERVAL`**
  - 说明：轮询模式下的轮询间隔（秒）。
  - 默认：`5`

- **`VIDEO_EXTENSIONS`**
  - 说明：支持的视频后缀（小写，逗号分隔）。
  - 默认：`mp4,flv,mkv,mov,avi`
  - 示例：
    ```bash
    VIDEO_EXTENSIONS=mp4,flv ./stream_watcher.sh
    ```

- **`RETRY_MAX_ATTEMPTS`**
  - 说明：推流失败时的最大重试次数。
  - 默认：`3`
  - 特殊值：
    - `<= 0`：表示无限重试，永远不会标记为失败
  - 示例（无限重试）：
    ```bash
    RETRY_MAX_ATTEMPTS=0 ./stream_watcher.sh
    ```

- **`PID_DIR`**
  - 说明：事件模式下记录每个文件推流 PID 的目录。
  - 默认：`$VIDEO_DIR/.pids`

### HTTP API 服务（main.go）

支持的环境变量：

- **`HTTP_PORT`**
  - 说明：HTTP API 服务监听端口。
  - 默认：`8081`

- **`WATCHER_SCRIPT`**
  - 说明：推流脚本路径。
  - 默认：`./stream_watcher.sh`

- **`AUTO_START`**
  - 说明：容器启动时是否自动启动推流脚本。
  - 默认：`true`（自动启动）
  - 设置为 `false` 可禁用自动启动，需手动调用 API 启动

### docker-compose 中的配置

`docker-compose.yml` 里 `video2stream-watcher` 服务示例：

```yaml
services:
  video2stream-watcher:
    build:
      context: .
      dockerfile: Dockerfile
    ports:
      - "8081:8081"   # HTTP API 端口
    environment:
      - VIDEO_DIR=/app/videos
      - RTMP_URL=rtmp://zlmediakit:1935/live
      - POLL_INTERVAL=5
      - HTTP_PORT=8081
      # 可选：自定义支持的视频后缀（逗号分隔）
      # - VIDEO_EXTENSIONS=mp4,flv,mkv,mov,avi
      # 可选：失败重试次数（<=0 表示无限重试）
      # - RETRY_MAX_ATTEMPTS=0
      # 可选：禁用自动启动推流脚本
      # - AUTO_START=false
    volumes:
      - ./videos:/app/videos
```

你可以根据自己的 ZLMediaKit 配置修改 `RTMP_URL`，例如改成其他 app 名、带鉴权参数等。

---

## 在宿主机直接运行脚本（非 Docker）

如果你本地已安装 `ffmpeg`（可选安装 `fswatch`），也可以直接运行脚本：

```bash
chmod +x stream_watcher.sh

VIDEO_DIR=/absolute/path/to/videos \
RTMP_URL=rtmp://你的ZLM_IP:1935/live \
POLL_INTERVAL=3 \
VIDEO_EXTENSIONS=mp4,flv \
./stream_watcher.sh
```

行为与容器内一致：

- 有 `fswatch`：使用事件模式，文件更新会重启该文件的推流（先杀旧，再启新）。
- 无 `fswatch`：使用轮询模式，使用状态文件记录处理结果，源文件保留在原目录。

### 状态文件说明

推流脚本会在 `VIDEO_DIR/.state/` 目录下维护以下状态文件：

- `processed.list`：已成功推流的文件列表（绝对路径）
- `failed.list`：已达到最大重试次数、放弃推流的文件列表（绝对路径）
- `in_progress.list`：当前正在推流中的文件列表（绝对路径）
- `retry.list`：记录每个文件的失败次数（格式：`<path>|<count>`）
- `ffmpeg_logs/`：每个文件的 ffmpeg 详细日志（避免刷屏 Docker 日志）

**注意**：源视频文件不会被移动或删除，始终保留在 `VIDEO_DIR` 中。

---

## CI / 镜像构建

项目在 `.github/workflows/` 下包含两个 GitHub Actions Workflow：

- **`docker-build-push-main.yml`**
  - 触发条件：推送到 `main` 分支。
  - 行为：构建并推送最新镜像到阿里云 ACR：
    - `registry.cn-hangzhou.aliyuncs.com/video2stream/video2stream:latest`
    - `registry.cn-hangzhou.aliyuncs.com/video2stream/video2stream:${GITHUB_SHA}`

- **`docker-build-push-tag.yml`**
  - 触发条件：推送任意 tag。
  - 行为：构建并推送带 tag 与 commit SHA 的镜像：
    - `registry.cn-hangzhou.aliyuncs.com/video2stream/video2stream:${TAG}`
    - `registry.cn-hangzhou.aliyuncs.com/video2stream/video2stream:${GITHUB_SHA}`

需要在仓库 Secrets 中配置：

- `ACR_USERNAME`
- `ACR_PASSWORD`

---

## 技术细节

### 推流编码参数

当前使用 H.264 + AAC 编码推流：

```bash
ffmpeg -re -stream_loop -1 -i input.mp4 \
  -c:v libx264 -preset veryfast -tune zerolatency \
  -c:a aac -ar 44100 -ac 2 -b:a 128k \
  -f flv rtmp://host/live/stream
```

- **视频编码**：`libx264`，`veryfast` 预设，`zerolatency` 调优（适合推流）
- **音频编码**：`aac`，44.1kHz，双声道，128kbps

如果需要调整码率、分辨率、帧率等参数，可以修改 `stream_watcher.sh` 中的 `do_stream_file()` 和 `start_stream_background()` 函数。

### 并发推流

- 轮询模式下，每个视频文件使用独立的后台 ffmpeg 进程推流
- 支持同时推流多个文件，互不干扰
- 每个文件的推流状态独立管理

### 失败重试机制

- 推流失败时，会自动记录失败次数
- 未达到最大重试次数时，会在后续轮询中自动重试
- 达到最大重试次数后，才会标记为失败（除非 `RETRY_MAX_ATTEMPTS <= 0`，表示无限重试）

## 注意事项

- **ZLMediaKit 配置**：如果推流频繁失败（Broken pipe），请检查 ZLMediaKit 的 `streamNoneReaderDelayMS` 配置，建议设置为较大的值或配合 `on_stream_none_reader` 回调处理。
- **文件稳定性**：如果文件正在写入（如 `cp` 大文件），建议等写入完成后再放入目录，避免推流时文件不完整。
- **日志查看**：ffmpeg 的详细日志保存在 `VIDEO_DIR/.state/ffmpeg_logs/` 目录下，按文件名命名。


