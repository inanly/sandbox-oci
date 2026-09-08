// sandbox-oci's small lifecycle adapter uses OpenSandbox's imagecommitter library.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	ic "github.com/alibaba/OpenSandbox/sandbox-k8s/pkg/imagecommitter"
	containerd "github.com/containerd/containerd"
	"github.com/containerd/containerd/errdefs"
	"github.com/containerd/containerd/leases"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx, os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		_ = os.WriteFile("/dev/termination-log", []byte(err.Error()), 0644)
		os.Exit(1)
	}
}

func run(ctx context.Context, args []string) (retErr error) {
	recoverOnly := len(args) > 0 && args[0] == "unpause"
	if recoverOnly {
		args = args[1:]
	}
	if len(args) != 3 {
		return errors.New("usage: helper [unpause] POD NAMESPACE CONTAINER:IMAGE")
	}
	parts := strings.SplitN(args[2], ":", 2)
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		return errors.New("expected CONTAINER:IMAGE")
	}
	expected, uid := os.Getenv("EXPECTED_CONTAINER_ID"), os.Getenv("SOURCE_POD_UID")
	if expected == "" || uid == "" {
		return errors.New("source UID and expected container ID are required")
	}
	client, err := containerd.New("/run/containerd/containerd.sock", containerd.WithDefaultNamespace("k8s.io"))
	if err != nil {
		return err
	}
	defer client.Close()
	runtime := ic.NewContainerdRuntime(client)
	source, err := runtime.Resolve(ctx, ic.ContainerSelector{PodName: args[0], PodNamespace: args[1], PodUID: uid, ContainerName: parts[0]})
	if err != nil {
		return err
	}
	if source.ID != expected {
		return fmt.Errorf("stale source: expected %s, found %s", expected, source.ID)
	}
	lock := leases.Lease{ID: "sandbox-oci-" + source.ID}
	if recoverOnly {
		if err := runtime.Resume(ctx, source); err != nil {
			return err
		}
		state, err := runtime.Status(ctx, source)
		if err != nil || state != ic.TaskStateRunning {
			return fmt.Errorf("recovery did not restore a running source: %s (%v)", state, err)
		}
		// Operator recovery is explicit; a crashed helper can leave this lock behind.
		if err := client.LeasesService().Delete(ctx, lock); err != nil && !errdefs.IsNotFound(err) {
			return err
		}
		return nil
	}
	if source.State != ic.TaskStateRunning || source.Snapshotter != "overlayfs" {
		return fmt.Errorf("unsupported source: state=%s snapshotter=%s", source.State, source.Snapshotter)
	}
	if _, err := client.LeasesService().Create(ctx, leases.WithID(lock.ID)); err != nil {
		return fmt.Errorf("capture lock (active helper or recovery required): %w", err)
	}
	defer func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		state, err := runtime.Status(cleanup, source)
		if err == nil && state == ic.TaskStateRunning {
			_ = client.LeasesService().Delete(cleanup, lock)
		}
	}()
	fmt.Fprintf(os.Stderr, "source=%s uid=%s snapshotter=%s\n", source.ID, uid, source.Snapshotter)
	prep, err := runtime.Exec(ctx, source, ic.ExecRequest{Args: []string{"sync"}})
	if err != nil {
		return fmt.Errorf("sync: %w", err)
	}
	if prep.ExitCode != 0 {
		return fmt.Errorf("sync exit %d", prep.ExitCode)
	}
	resumed := false
	defer func() {
		if !resumed {
			cleanup, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer cancel()
			if err := runtime.Resume(cleanup, source); err != nil {
				retErr = errors.Join(retErr, fmt.Errorf("SOURCE MAY REMAIN PAUSED (%s): %w", source.ID, err))
			}
		}
	}()
	// Register recovery before the RPC: an interrupted response does not prove the
	// daemon failed to pause. The per-container lease excludes our other helpers.
	pauseCtx, pauseCancel := context.WithTimeout(context.Background(), 30*time.Second)
	handle, err := runtime.Pause(pauseCtx, source)
	pauseCancel()
	if err != nil {
		return fmt.Errorf("pause outcome uncertain; recovery attempted: %w", err)
	}
	if !handle.PausedByUs {
		// A successful RPC confirms we did not pause it. Respect external state.
		resumed = true
		return errors.New("source changed state before pause; no snapshot made")
	}
	if err := pauseTestGate(ctx); err != nil {
		return err
	}
	builder := ic.NewContainerdImageBuilder(client, nil, func(string) bool { return os.Getenv("SOURCE_IMAGE_REGISTRY_INSECURE") == "true" })
	image, err := builder.Commit(ctx, source, parts[1])
	if err != nil {
		return fmt.Errorf("build: %w", err)
	}
	cleanup, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	err = runtime.Resume(cleanup, source)
	cancel()
	if err != nil {
		return fmt.Errorf("resume before push: %w", err)
	}
	resumed = true
	state, err := runtime.Status(ctx, source)
	if err != nil || state != ic.TaskStateRunning {
		return fmt.Errorf("source not running after capture: %s (%v)", state, err)
	}
	pusher := ic.NewContainerdImagePusher(client, nil, func(string) bool { return os.Getenv("SNAPSHOT_REGISTRY_INSECURE") == "true" })
	descriptor, err := pusher.Push(ctx, image)
	if err != nil {
		return fmt.Errorf("push: %w", err)
	}
	if descriptor.Digest == "" {
		return errors.New("push returned empty digest")
	}
	result := struct {
		Containers        []ic.ContainerResult `json:"containers"`
		SourcePodUID      string               `json:"sourcePodUID"`
		SourceContainerID string               `json:"sourceContainerID"`
	}{[]ic.ContainerResult{{Name: source.Name, Image: parts[1], Digest: descriptor.Digest.String()}}, uid, source.ID}
	data, err := json.Marshal(result)
	if err != nil {
		return err
	}
	if err = os.WriteFile("/dev/termination-log", data, 0644); err != nil {
		return err
	}
	fmt.Println(string(data))
	return nil
}
