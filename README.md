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
- **事件模式（fswatch）**：
  - 有 `fswatch` 时使用事件驱动监听。
  - 同一个文件多次修改时，**会先停止旧的推流进程，再启动新的推流**，保证同一文件只存在一个推流。
- **轮询模式**：
  - 没有 `fswatch` 时，按固定间隔轮询目录。
  - 推完一个文件后会移动到 `processed` 目录，避免重复推流。

核心脚本：`stream_watcher.sh`  
容器镜像：`registry.cn-hangzhou.aliyuncs.com/video2stream/video2stream:...`

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

### 2. 放入测试视频

将测试视频复制到项目根目录下的 `videos/` 目录：

```bash
mkdir -p videos
cp /path/to/test.mp4 ./videos/
```

监听脚本会自动检测到新文件并开始推流。

### 3. 播放推流

在本机上可以用以下地址播放（以默认 ZLMediaKit 配置为例），假设你放入的文件为 `/path/to/test.mp4`（相对挂载点）：

- RTMP：`rtmp://127.0.0.1:1935/live/path-to-test.mp4`
- HTTP-FLV：`http://127.0.0.1:8080/live/path-to-test.mp4.live.flv`
- HLS：`http://127.0.0.1:8080/live/path-to-test.mp4/hls.m3u8`

可用 VLC、ffplay 或浏览器（配合前端播放器）进行播放。

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
  - 说明：推流基础地址（不含流名），实际推流地址为 `RTMP_URL/{路径归一化文件名}`。
  - 默认：`rtmp://zlmediakit:1935/live`  
    （在 docker-compose 中指向 `zlmediakit` 服务）
  - “路径归一化文件名”规则：
    - 去掉路径前导 `/`
    - 将路径分隔符 `/` 替换为 `-`
    - 保留扩展名
    - 例如：`/foo/bar/video.mp4` → `foo-bar-video.mp4`
  - 示例（推到外部 ZLMediaKit，且以“路径归一化文件名”为 key）：
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

- **`PID_DIR`**
  - 说明：事件模式下记录每个文件推流 PID 的目录。
  - 默认：`$VIDEO_DIR/.pids`

### docker-compose 中的配置

`docker-compose.yml` 里 `video2stream-watcher` 服务示例：

```yaml
services:
  video2stream-watcher:
    build:
      context: .
      dockerfile: Dockerfile
    environment:
      - VIDEO_DIR=/app/videos
      - RTMP_URL=rtmp://zlmediakit:1935/live
      - POLL_INTERVAL=5
      # - VIDEO_EXTENSIONS=mp4,flv,mkv,mov,avi
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
- 无 `fswatch`：使用轮询模式，推完的文件会移动到 `processed` 目录。

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

## 注意事项 / TODO

- 当前推流命令简单使用：`ffmpeg -re -stream_loop -1 -i input -c copy -f flv RTMP_URL`，如果有转码需求（例如统一分辨率、码率、编码格式），可以在脚本中进一步调整参数。
- 如果你希望支持多路不同地址的推流、按文件名动态决定推流目标、或者增加 HTTP 管理接口，可以在现有脚本基础上再扩展逻辑。


