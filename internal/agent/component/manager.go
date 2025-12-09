package component

import (
	"archive/tar"
	"archive/zip"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/metorial/fleet/cosmos/internal/agent/database"
	log "github.com/sirupsen/logrus"
)

// ProgressReporter is an interface for reporting deployment progress
type ProgressReporter interface {
	ReportProgress(componentName, status, message string)
}

type Manager struct {
	db               *database.AgentDB
	dataDir          string
	progressReporter ProgressReporter
}

func NewManager(db *database.AgentDB, dataDir string) *Manager {
	return &Manager{
		db:      db,
		dataDir: dataDir,
	}
}

func (m *Manager) SetProgressReporter(reporter ProgressReporter) {
	m.progressReporter = reporter
}

func (m *Manager) DeployProgram(component *database.Component) error {
	log.WithField("component", component.Name).Info("Deploying program")

	if component.ContentURL == "" {
		return fmt.Errorf("content_url is required for programs")
	}

	existing, err := m.db.GetComponent(component.Name)
	if err == nil && existing.Hash == component.Hash {
		log.WithField("component", component.Name).Info("Component already deployed with same hash")
		return nil
	}

	filePath, err := m.downloadFile(component.ContentURL, component.Hash)
	if err != nil {
		return fmt.Errorf("download failed: %w", err)
	}
	defer os.Remove(filePath)

	extractDir := filepath.Join(m.dataDir, "programs", component.Name)
	if err := os.MkdirAll(extractDir, 0755); err != nil {
		return fmt.Errorf("failed to create extract directory: %w", err)
	}

	if err := m.extractArchive(filePath, extractDir, component.ContentURLEncoding); err != nil {
		return fmt.Errorf("extraction failed: %w", err)
	}

	executable, err := m.findExecutable(extractDir, component.Name)
	if err != nil {
		return fmt.Errorf("finding executable failed: %w", err)
	}

	component.Executable = executable

	if existing != nil {
		if err := m.StopComponent(component.Name); err != nil {
			log.WithError(err).Warn("Failed to stop old version")
		}
	}

	if err := m.db.UpsertComponent(component); err != nil {
		return fmt.Errorf("failed to save component: %w", err)
	}

	if err := m.StartComponent(component.Name); err != nil {
		return fmt.Errorf("failed to start component: %w", err)
	}

	log.WithField("component", component.Name).Info("Program deployed successfully")
	return nil
}

func (m *Manager) DeployScript(component *database.Component) error {
	if component.Managed {
		log.WithField("component", component.Name).Info("Deploying managed script")
	} else {
		log.WithField("component", component.Name).Info("Deploying unmanaged script")
	}

	if component.Content == "" {
		return fmt.Errorf("content is required for scripts")
	}

	scriptDir := filepath.Join(m.dataDir, "scripts")
	if err := os.MkdirAll(scriptDir, 0755); err != nil {
		return fmt.Errorf("failed to create script directory: %w", err)
	}

	scriptPath := filepath.Join(scriptDir, component.Name+".sh")
	if err := os.WriteFile(scriptPath, []byte(component.Content), 0755); err != nil {
		return fmt.Errorf("failed to write script: %w", err)
	}

	component.Executable = scriptPath

	if err := m.db.UpsertComponent(component); err != nil {
		return fmt.Errorf("failed to save component: %w", err)
	}

	if component.Managed {
		if err := m.StartComponent(component.Name); err != nil {
			return fmt.Errorf("failed to start script: %w", err)
		}
	} else {
		// Execute unmanaged script once immediately
		if err := m.executeUnmanagedScript(component); err != nil {
			return fmt.Errorf("failed to execute unmanaged script: %w", err)
		}
	}

	log.WithField("component", component.Name).Info("Script deployed successfully")
	return nil
}

func (m *Manager) executeUnmanagedScript(component *database.Component) error {
	env, err := m.db.GetEnvMap(component)
	if err != nil {
		return fmt.Errorf("failed to get environment: %w", err)
	}

	args, err := m.db.GetArgsSlice(component)
	if err != nil {
		return fmt.Errorf("failed to get args: %w", err)
	}

	hostScriptPath := filepath.Join("/opt/cosmos-agent/scripts", component.Name+".sh")

	// Use nsenter to enter host namespaces and execute the script
	// -t 1 = target PID 1 (init/systemd on host)
	// -m = mount namespace
	// -u = UTS namespace
	// -i = IPC namespace
	// -n = network namespace
	// -p = PID namespace
	// We use bash -c to set the working directory since -w flag may not be available
	scriptCmd := fmt.Sprintf("cd /home/ubuntu && bash %s", hostScriptPath)
	if len(args) > 0 {
		for _, arg := range args {
			scriptCmd += fmt.Sprintf(" %s", arg)
		}
	}

	nsenterArgs := []string{
		"-t", "1",
		"-m", "-u", "-i", "-n", "-p",
		"--",
		"bash", "-c", scriptCmd,
	}

	cmd := exec.Command("nsenter", nsenterArgs...)

	envVars := []string{
		"PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
		"HOME=/root",
		"USER=root",
	}
	for k, v := range env {
		envVars = append(envVars, fmt.Sprintf("%s=%s", k, v))
	}
	cmd.Env = envVars

	logDir := filepath.Join(m.dataDir, "logs")
	os.MkdirAll(logDir, 0755)

	logFilePath := filepath.Join(logDir, component.Name+".log")
	logFile, err := os.OpenFile(
		logFilePath,
		os.O_CREATE|os.O_WRONLY|os.O_APPEND,
		0644,
	)
	if err != nil {
		return fmt.Errorf("failed to open log file: %w", err)
	}
	defer logFile.Close()

	cmd.Stdout = logFile
	cmd.Stderr = logFile

	log.WithField("component", component.Name).Info("Executing unmanaged script")

	// Start the process
	if err := cmd.Start(); err != nil {
		log.WithError(err).WithField("component", component.Name).Error("Failed to start unmanaged script")
		return fmt.Errorf("failed to start script: %w", err)
	}

	// Monitor the process and tail logs
	done := make(chan error, 1)
	go func() {
		done <- cmd.Wait()
	}()

	// Tail the log file periodically while process is running
	ticker := time.NewTicker(3 * time.Second)
	defer ticker.Stop()

	var lastOffset int64 = 0

	for {
		select {
		case err := <-done:
			// Process completed, read final output
			ticker.Stop()
			finalOutput, _ := m.readLogTail(logFilePath, lastOffset)
			if finalOutput != "" {
				log.WithFields(log.Fields{
					"component": component.Name,
					"output":    finalOutput,
				}).Info("Script final output")
			}

			if err != nil {
				log.WithError(err).WithField("component", component.Name).Warn("Unmanaged script execution failed")
				return fmt.Errorf("script execution failed: %w", err)
			}

			log.WithField("component", component.Name).Info("Unmanaged script executed successfully")
			return nil

		case <-ticker.C:
			// Read incremental output
			output, newOffset := m.readLogTail(logFilePath, lastOffset)
			if output != "" {
				log.WithFields(log.Fields{
					"component": component.Name,
					"output":    output,
				}).Info("Script output")

				// Report progress to controller if reporter is set
				if m.progressReporter != nil {
					m.progressReporter.ReportProgress(
						component.Name,
						"running",
						fmt.Sprintf("Output: %s", output),
					)
				}

				lastOffset = newOffset
			}
		}
	}
}

// readLogTail reads new content from a log file starting at the given offset
func (m *Manager) readLogTail(filePath string, offset int64) (string, int64) {
	file, err := os.Open(filePath)
	if err != nil {
		return "", offset
	}
	defer file.Close()

	// Seek to the last known offset
	if _, err := file.Seek(offset, 0); err != nil {
		return "", offset
	}

	// Read new content (limit to 4KB per read to avoid huge messages)
	buf := make([]byte, 4096)
	n, err := file.Read(buf)
	if err != nil && err != io.EOF {
		return "", offset
	}

	newOffset := offset + int64(n)
	if n > 0 {
		return string(buf[:n]), newOffset
	}

	return "", offset
}

func (m *Manager) StartComponent(name string) error {
	component, err := m.db.GetComponent(name)
	if err != nil {
		return fmt.Errorf("component not found: %w", err)
	}

	status, _ := m.db.GetComponentStatus(name)
	if status.Status == "running" && m.IsProcessRunning(status.PID) {
		log.WithField("component", name).Info("Component already running")
		return nil
	}

	env, err := m.db.GetEnvMap(component)
	if err != nil {
		return fmt.Errorf("failed to get environment: %w", err)
	}

	args, err := m.db.GetArgsSlice(component)
	if err != nil {
		return fmt.Errorf("failed to get args: %w", err)
	}

	cmd := exec.Command(component.Executable, args...)

	envVars := os.Environ()
	for k, v := range env {
		envVars = append(envVars, fmt.Sprintf("%s=%s", k, v))
	}
	cmd.Env = envVars
	cmd.Dir = filepath.Dir(component.Executable)

	logDir := filepath.Join(m.dataDir, "logs")
	os.MkdirAll(logDir, 0755)

	logFile, err := os.OpenFile(
		filepath.Join(logDir, name+".log"),
		os.O_CREATE|os.O_WRONLY|os.O_APPEND,
		0644,
	)
	if err != nil {
		return fmt.Errorf("failed to open log file: %w", err)
	}

	cmd.Stdout = logFile
	cmd.Stderr = logFile

	if err := cmd.Start(); err != nil {
		logFile.Close()
		return fmt.Errorf("failed to start process: %w", err)
	}

	now := time.Now()
	status.Status = "running"
	status.PID = cmd.Process.Pid
	status.LastStartedAt = &now
	status.LastCheckedAt = time.Now()
	status.Message = "Process started successfully"

	if err := m.db.UpsertComponentStatus(status); err != nil {
		return fmt.Errorf("failed to update status: %w", err)
	}

	go m.monitorProcess(name, cmd, logFile)

	log.WithFields(log.Fields{
		"component": name,
		"pid":       cmd.Process.Pid,
	}).Info("Component started")

	return nil
}

func (m *Manager) StopComponent(name string) error {
	status, err := m.db.GetComponentStatus(name)
	if err != nil {
		return err
	}

	if status.Status != "running" {
		return nil
	}

	if !m.IsProcessRunning(status.PID) {
		status.Status = "stopped"
		m.db.UpsertComponentStatus(status)
		return nil
	}

	process, err := os.FindProcess(status.PID)
	if err != nil {
		return fmt.Errorf("failed to find process: %w", err)
	}

	if err := process.Signal(syscall.SIGTERM); err != nil {
		return fmt.Errorf("failed to send SIGTERM: %w", err)
	}

	timeout := time.After(10 * time.Second)
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-timeout:
			log.WithField("component", name).Warn("Process did not stop gracefully, sending SIGKILL")
			process.Kill()
			status.Status = "stopped"
			status.Message = "Forcefully killed after timeout"
			m.db.UpsertComponentStatus(status)
			return nil
		case <-ticker.C:
			if !m.IsProcessRunning(status.PID) {
				status.Status = "stopped"
				status.Message = "Stopped gracefully"
				m.db.UpsertComponentStatus(status)
				log.WithField("component", name).Info("Component stopped")
				return nil
			}
		}
	}
}

func (m *Manager) RestartComponent(name string) error {
	log.WithField("component", name).Info("Restarting component")

	status, _ := m.db.GetComponentStatus(name)
	status.RestartCount++
	m.db.UpsertComponentStatus(status)

	if err := m.StopComponent(name); err != nil {
		log.WithError(err).Warn("Failed to stop component, continuing with start")
	}

	time.Sleep(1 * time.Second)

	return m.StartComponent(name)
}

func (m *Manager) RemoveComponent(name string) error {
	log.WithField("component", name).Info("Removing component")

	if err := m.StopComponent(name); err != nil {
		log.WithError(err).Warn("Failed to stop component")
	}

	component, err := m.db.GetComponent(name)
	if err == nil {
		if strings.HasPrefix(component.Executable, filepath.Join(m.dataDir, "programs")) {
			programDir := filepath.Dir(component.Executable)
			os.RemoveAll(programDir)
		} else if strings.HasPrefix(component.Executable, filepath.Join(m.dataDir, "scripts")) {
			os.Remove(component.Executable)
		}
	}

	if err := m.db.DeleteComponent(name); err != nil {
		return fmt.Errorf("failed to delete component from database: %w", err)
	}

	log.WithField("component", name).Info("Component removed")
	return nil
}

func (m *Manager) IsProcessRunning(pid int) bool {
	if pid <= 0 {
		return false
	}

	process, err := os.FindProcess(pid)
	if err != nil {
		return false
	}

	err = process.Signal(syscall.Signal(0))
	return err == nil
}

func (m *Manager) monitorProcess(name string, cmd *exec.Cmd, logFile *os.File) {
	defer logFile.Close()

	err := cmd.Wait()

	status, _ := m.db.GetComponentStatus(name)
	status.Status = "stopped"
	status.LastCheckedAt = time.Now()

	if err != nil {
		status.Message = fmt.Sprintf("Process exited with error: %v", err)
		log.WithFields(log.Fields{
			"component": name,
			"error":     err,
		}).Warn("Component process exited with error")
	} else {
		status.Message = "Process exited normally"
		log.WithField("component", name).Info("Component process exited")
	}

	m.db.UpsertComponentStatus(status)
}

func (m *Manager) downloadFile(url, expectedHash string) (string, error) {
	log.WithField("url", url).Info("Downloading file")

	tmpFile, err := os.CreateTemp("", "cosmos-download-*")
	if err != nil {
		return "", fmt.Errorf("failed to create temp file: %w", err)
	}
	defer tmpFile.Close()

	resp, err := http.Get(url)
	if err != nil {
		os.Remove(tmpFile.Name())
		return "", fmt.Errorf("failed to download: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		os.Remove(tmpFile.Name())
		return "", fmt.Errorf("download failed with status: %d", resp.StatusCode)
	}

	hasher := sha256.New()
	writer := io.MultiWriter(tmpFile, hasher)

	if _, err := io.Copy(writer, resp.Body); err != nil {
		os.Remove(tmpFile.Name())
		return "", fmt.Errorf("failed to save file: %w", err)
	}

	actualHash := hex.EncodeToString(hasher.Sum(nil))
	if actualHash != expectedHash {
		os.Remove(tmpFile.Name())
		return "", fmt.Errorf("hash mismatch: expected %s, got %s", expectedHash, actualHash)
	}

	log.WithField("hash", actualHash).Info("File downloaded and verified")
	return tmpFile.Name(), nil
}

func (m *Manager) extractArchive(filePath, destDir, encoding string) error {
	log.WithFields(log.Fields{
		"file":     filePath,
		"dest":     destDir,
		"encoding": encoding,
	}).Info("Extracting archive")

	switch encoding {
	case "tar.gz", "tgz":
		return m.extractTarGz(filePath, destDir)
	case "zip":
		return m.extractZip(filePath, destDir)
	case "plain", "":
		baseName := filepath.Base(filePath)
		destPath := filepath.Join(destDir, baseName)
		return os.Rename(filePath, destPath)
	default:
		return fmt.Errorf("unsupported encoding: %s", encoding)
	}
}

func (m *Manager) extractTarGz(filePath, destDir string) error {
	file, err := os.Open(filePath)
	if err != nil {
		return err
	}
	defer file.Close()

	gzr, err := gzip.NewReader(file)
	if err != nil {
		return err
	}
	defer gzr.Close()

	tr := tar.NewReader(gzr)

	for {
		header, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}

		target := filepath.Join(destDir, header.Name)

		if !strings.HasPrefix(target, filepath.Clean(destDir)+string(os.PathSeparator)) {
			return fmt.Errorf("illegal file path: %s", header.Name)
		}

		switch header.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(target, 0755); err != nil {
				return err
			}
		case tar.TypeReg:
			if err := os.MkdirAll(filepath.Dir(target), 0755); err != nil {
				return err
			}

			outFile, err := os.OpenFile(target, os.O_CREATE|os.O_RDWR, os.FileMode(header.Mode))
			if err != nil {
				return err
			}

			if _, err := io.Copy(outFile, tr); err != nil {
				outFile.Close()
				return err
			}
			outFile.Close()
		}
	}

	return nil
}

func (m *Manager) extractZip(filePath, destDir string) error {
	r, err := zip.OpenReader(filePath)
	if err != nil {
		return err
	}
	defer r.Close()

	for _, f := range r.File {
		target := filepath.Join(destDir, f.Name)

		if !strings.HasPrefix(target, filepath.Clean(destDir)+string(os.PathSeparator)) {
			return fmt.Errorf("illegal file path: %s", f.Name)
		}

		if f.FileInfo().IsDir() {
			os.MkdirAll(target, 0755)
			continue
		}

		if err := os.MkdirAll(filepath.Dir(target), 0755); err != nil {
			return err
		}

		outFile, err := os.OpenFile(target, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, f.Mode())
		if err != nil {
			return err
		}

		rc, err := f.Open()
		if err != nil {
			outFile.Close()
			return err
		}

		_, err = io.Copy(outFile, rc)
		outFile.Close()
		rc.Close()

		if err != nil {
			return err
		}
	}

	return nil
}

func (m *Manager) findExecutable(dir, componentName string) (string, error) {
	var executable string

	err := filepath.Walk(dir, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}

		if info.IsDir() {
			return nil
		}

		if info.Mode()&0111 != 0 {
			if executable == "" || filepath.Base(path) == componentName {
				executable = path
				if filepath.Base(path) == componentName {
					return filepath.SkipDir
				}
			}
		}

		return nil
	})

	if err != nil {
		return "", err
	}

	if executable == "" {
		return "", fmt.Errorf("no executable found in %s", dir)
	}

	return executable, nil
}
