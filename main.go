package main

import (
	"net/http"
	"os"
	"os/exec"
	"sync"
	"syscall"

	"github.com/gin-gonic/gin"
)

// StreamManager 负责管理 stream_watcher.sh 的生命周期
type StreamManager struct {
	mu  sync.Mutex
	cmd *exec.Cmd
}

func NewStreamManager() *StreamManager {
	return &StreamManager{}
}

func (m *StreamManager) isRunning() bool {
	if m.cmd == nil || m.cmd.Process == nil {
		return false
	}
	// 向进程发送 0 信号，检测是否存活（类 Unix 平台）
	err := m.cmd.Process.Signal(syscall.Signal(0))
	return err == nil
}

func (m *StreamManager) Start() error {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.isRunning() {
		return nil
	}

	watcherPath := os.Getenv("WATCHER_SCRIPT")
	if watcherPath == "" {
		// 默认使用当前目录下的脚本
		watcherPath = "./stream_watcher.sh"
	}

	cmd := exec.Command(watcherPath) // #nosec G204
	// 继承当前进程环境变量，支持我们之前在 Docker / shell 中通过 env 配置行为
	cmd.Env = os.Environ()

	// 将 watcher 的输出直接继承当前进程（方便本地调试），
	// 如果不想输出到 stdout/stderr，也可以这里改成写入文件。
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	if err := cmd.Start(); err != nil {
		return err
	}

	m.cmd = cmd

	// 后台等待进程结束，结束后清理状态
	go func() {
		_ = cmd.Wait()
		m.mu.Lock()
		defer m.mu.Unlock()
		// 只有在当前 cmd 仍然是我们跟踪的那个时才清空，避免与重新启动竞争
		if m.cmd == cmd {
			m.cmd = nil
		}
	}()

	return nil
}

func (m *StreamManager) Stop() error {
	m.mu.Lock()
	defer m.mu.Unlock()

	if m.cmd == nil || m.cmd.Process == nil {
		return nil
	}

	// 优雅停止，发送 SIGTERM
	if err := m.cmd.Process.Signal(syscall.SIGTERM); err != nil {
		return err
	}

	return nil
}

func (m *StreamManager) Restart() error {
	if err := m.Stop(); err != nil {
		return err
	}
	return m.Start()
}

func main() {
	manager := NewStreamManager()

	// 容器启动时自动启动 stream_watcher.sh（可通过环境变量 AUTO_START=false 禁用）
	autoStart := os.Getenv("AUTO_START")
	if autoStart != "false" {
		if err := manager.Start(); err != nil {
			// 启动失败时记录错误，但不退出（HTTP 服务仍可启动，用户可通过 API 手动启动）
			_, _ = os.Stderr.WriteString("警告：自动启动 stream_watcher.sh 失败: " + err.Error() + "\n")
		} else {
			_, _ = os.Stdout.WriteString("已自动启动 stream_watcher.sh\n")
		}
	}

	// Gin 默认在非 RELEASE 模式下会输出 debug 日志；
	// 这里使用 ReleaseMode，避免多余输出。
	gin.SetMode(gin.ReleaseMode)
	r := gin.Default()

	api := r.Group("/api/stream")
	{
		api.POST("/start", func(c *gin.Context) {
			if manager.isRunning() {
				c.JSON(http.StatusOK, gin.H{
					"status":  "running",
					"message": "stream watcher 已在运行",
				})
				return
			}

			if err := manager.Start(); err != nil {
				c.JSON(http.StatusInternalServerError, gin.H{
					"status": "error",
					"error":  err.Error(),
				})
				return
			}

			c.JSON(http.StatusOK, gin.H{
				"status":  "started",
				"message": "stream watcher 已启动",
			})
		})

		api.POST("/stop", func(c *gin.Context) {
			if !manager.isRunning() {
				c.JSON(http.StatusOK, gin.H{
					"status":  "stopped",
					"message": "stream watcher 当前未运行",
				})
				return
			}

			if err := manager.Stop(); err != nil {
				c.JSON(http.StatusInternalServerError, gin.H{
					"status": "error",
					"error":  err.Error(),
				})
				return
			}

			c.JSON(http.StatusOK, gin.H{
				"status":  "stopping",
				"message": "已发送停止信号，稍后将退出",
			})
		})

		api.POST("/restart", func(c *gin.Context) {
			if err := manager.Restart(); err != nil {
				c.JSON(http.StatusInternalServerError, gin.H{
					"status": "error",
					"error":  err.Error(),
				})
				return
			}

			c.JSON(http.StatusOK, gin.H{
				"status":  "restarted",
				"message": "stream watcher 已重启",
			})
		})

		api.GET("/status", func(c *gin.Context) {
			running := manager.isRunning()
			c.JSON(http.StatusOK, gin.H{
				"running": running,
			})
		})
	}

	port := os.Getenv("HTTP_PORT")
	if port == "" {
		port = "8081"
	}

	_ = r.Run(":" + port)
}
