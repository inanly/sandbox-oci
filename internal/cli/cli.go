// Package cli implements the deliberately small, kubectl-backed sandbox-oci CLI.
package cli

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"math/rand/v2"
	"os/exec"
	"regexp"
	"strings"
	"time"
)

const Version = "dev"

// HelperSourceSHA is updated with the pinned helper source integration.
const HelperSourceSHA = "unintegrated"

type common struct{ context, namespace, output string }
type runner interface {
	Run(context.Context, []string, []byte) ([]byte, []byte, error)
}
type kubectl struct{}

func (kubectl) Run(ctx context.Context, a []string, in []byte) ([]byte, []byte, error) {
	c := exec.CommandContext(ctx, "kubectl", a...)
	c.Stdin = strings.NewReader(string(in))
	var stdout, stderr strings.Builder
	c.Stdout, c.Stderr = &stdout, &stderr
	e := c.Run()
	return []byte(stdout.String()), []byte(stderr.String()), e
}

func Run(ctx context.Context, args []string, out, errOut io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(errOut, "usage: sandbox-oci <doctor|snapshot|restore|version> [flags]")
		return 2
	}
	if args[0] == "version" {
		fmt.Fprintf(out, "%s helper-source=%s\n", Version, HelperSourceSHA)
		return 0
	}
	r := kubectl{}
	var err error
	switch args[0] {
	case "doctor":
		err = doctor(ctx, r, args[1:], out)
	case "snapshot":
		err = snapshot(ctx, r, args[1:], out)
	case "restore":
		err = restore(ctx, r, args[1:], out)
	default:
		err = fmt.Errorf("unknown command %q", args[0])
	}
	if err != nil {
		fmt.Fprintln(errOut, "sandbox-oci:", err)
		return 1
	}
	return 0
}
func flags(name string, a []string) (*flag.FlagSet, *common) {
	f := flag.NewFlagSet(name, flag.ContinueOnError)
	f.SetOutput(io.Discard)
	c := &common{}
	f.StringVar(&c.context, "context", "", "kube context (required)")
	f.StringVar(&c.namespace, "namespace", "sandbox-oci", "namespace")
	f.StringVar(&c.output, "output", "text", "text or json")
	return f, c
}
func validateCommon(f *flag.FlagSet, c *common) error {
	if f.NArg() != 0 {
		return fmt.Errorf("unexpected positional argument %q", f.Arg(0))
	}
	if c.context == "" {
		return errors.New("--context is required")
	}
	if c.output != "text" && c.output != "json" {
		return errors.New("--output must be text or json")
	}
	return nil
}
func kget(ctx context.Context, r runner, c *common, kind, name string) ([]byte, error) {
	b, stderr, e := r.Run(ctx, []string{"--context", c.context, "-n", c.namespace, "get", kind, name, "-o", "json"}, nil)
	if e != nil {
		return nil, fmt.Errorf("get %s/%s: %w: %s", kind, name, e, stderr)
	}
	return b, nil
}

type pod struct {
	Metadata struct {
		UID               string  `json:"uid"`
		DeletionTimestamp *string `json:"deletionTimestamp"`
	} `json:"metadata"`
	Spec struct {
		NodeName            string            `json:"nodeName"`
		Containers          []container       `json:"containers"`
		InitContainers      []container       `json:"initContainers"`
		EphemeralContainers []container       `json:"ephemeralContainers"`
		Volumes             []json.RawMessage `json:"volumes"`
	} `json:"spec"`
	Status struct {
		Phase             string   `json:"phase"`
		ContainerStatuses []status `json:"containerStatuses"`
	} `json:"status"`
}
type container struct {
	Name           string            `json:"name"`
	Image          string            `json:"image"`
	VolumeMounts   []json.RawMessage `json:"volumeMounts"`
	LivenessProbe  json.RawMessage   `json:"livenessProbe"`
	ReadinessProbe json.RawMessage   `json:"readinessProbe"`
	StartupProbe   json.RawMessage   `json:"startupProbe"`
}
type status struct {
	Name, ContainerID string
	Ready             bool `json:"ready"`
}

func preflight(p pod, name string) (container, status, error) {
	if p.Metadata.DeletionTimestamp != nil {
		return container{}, status{}, errors.New("source pod is deleting")
	}
	if p.Status.Phase != "Running" {
		return container{}, status{}, fmt.Errorf("source pod is %s, want Running", p.Status.Phase)
	}
	if len(p.Spec.Containers) != 1 {
		return container{}, status{}, errors.New("source pod must have exactly one container")
	}
	if len(p.Spec.InitContainers) > 0 || len(p.Spec.EphemeralContainers) > 0 {
		return container{}, status{}, errors.New("init and ephemeral containers are unsupported")
	}
	if len(p.Spec.Volumes) > 0 || len(p.Spec.Containers[0].VolumeMounts) > 0 {
		return container{}, status{}, errors.New("volumes and volume mounts are unsupported")
	}
	c := p.Spec.Containers[0]
	if len(c.LivenessProbe) > 0 || len(c.ReadinessProbe) > 0 || len(c.StartupProbe) > 0 {
		return container{}, status{}, errors.New("probes are unsupported for snapshot sources")
	}
	if name != "" && c.Name != name {
		return container{}, status{}, fmt.Errorf("container %q not found", name)
	}
	for _, s := range p.Status.ContainerStatuses {
		if s.Name == c.Name {
			if !s.Ready {
				return container{}, status{}, errors.New("source container is not Ready")
			}
			if !strings.HasPrefix(s.ContainerID, "containerd://") {
				return container{}, status{}, errors.New("source container ID is not containerd://")
			}
			return c, s, nil
		}
	}
	return container{}, status{}, errors.New("source container status missing")
}
func nodeOK(ctx context.Context, r runner, c *common, node string) error {
	b, e := kget(ctx, r, c, "node", node)
	if e != nil {
		return e
	}
	var n struct {
		Status struct {
			NodeInfo struct{ OperatingSystem, Architecture, ContainerRuntimeVersion string } `json:"nodeInfo"`
		} `json:"status"`
	}
	if json.Unmarshal(b, &n) != nil {
		return errors.New("invalid node JSON")
	}
	x := n.Status.NodeInfo
	if x.OperatingSystem != "linux" || x.Architecture != "amd64" || !strings.HasPrefix(x.ContainerRuntimeVersion, "containerd://") {
		return fmt.Errorf("node %s must be linux/amd64 with containerd", node)
	}
	return nil
}
func doctor(ctx context.Context, r runner, a []string, out io.Writer) error {
	f, c := flags("doctor", a)
	if err := f.Parse(a); err != nil {
		return err
	}
	if err := validateCommon(f, c); err != nil {
		return err
	}
	if _, _, e := r.Run(ctx, []string{"--context", c.context, "version", "-o", "json"}, nil); e != nil {
		return fmt.Errorf("kubectl version: %w", e)
	}
	b, _, e := r.Run(ctx, []string{"--context", c.context, "get", "nodes", "-o", "json"}, nil)
	if e != nil {
		return e
	}
	var x struct {
		Items []struct {
			Metadata struct {
				Name string `json:"name"`
			} `json:"metadata"`
		} `json:"items"`
	}
	if json.Unmarshal(b, &x) != nil {
		return errors.New("invalid node list")
	}
	if len(x.Items) == 0 {
		return errors.New("no nodes")
	}
	for _, n := range x.Items {
		if e := nodeOK(ctx, r, c, n.Metadata.Name); e != nil {
			return e
		}
	}
	for _, q := range [][]string{{"get", "pods"}, {"get", "nodes"}, {"create", "jobs"}, {"get", "serviceaccounts"}, {"create", "serviceaccounts"}} {
		args := []string{"--context", c.context, "auth", "can-i", q[0], q[1], "-n", c.namespace}
		ans, _, err := r.Run(ctx, args, nil)
		if err != nil || strings.TrimSpace(string(ans)) != "yes" {
			return fmt.Errorf("required RBAC %s %s denied or unavailable", q[0], q[1])
		}
	}
	return emit(out, c.output, map[string]any{"ok": true, "nodes": len(x.Items)})
}

func snapshot(ctx context.Context, r runner, a []string, out io.Writer) error {
	f, c := flags("snapshot", a)
	podName := f.String("pod", "", "source pod")
	cn := f.String("container", "", "container")
	image := f.String("image", "", "push target")
	helper := f.String("helper-image", "", "digest pinned helper image")
	quiesced := f.Bool("source-quiesced", false, "source is quiesced")
	sourceRegistryInsecure := f.Bool("source-registry-insecure", false, "skip TLS certificate verification and allow HTTP fallback when resolving the source image registry")
	targetRegistryInsecure := f.Bool("target-registry-insecure", false, "skip TLS certificate verification and allow HTTP fallback when pushing to the target image registry")
	timeout := f.Duration("timeout", 10*time.Minute, "timeout")
	if e := f.Parse(a); e != nil {
		return e
	}
	if e := validateCommon(f, c); e != nil {
		return e
	}
	if *podName == "" || *cn == "" || *image == "" || !*quiesced {
		return errors.New("--pod, --container, --image and --source-quiesced are required")
	}
	if !digestRef(*helper) {
		return errors.New("--helper-image must be pinned with @sha256 digest")
	}
	if *timeout <= 0 {
		return errors.New("--timeout must be positive")
	}
	ctx, cancel := context.WithTimeout(ctx, *timeout)
	defer cancel()
	b, e := kget(ctx, r, c, "pod", *podName)
	if e != nil {
		return e
	}
	var p pod
	if json.Unmarshal(b, &p) != nil {
		return errors.New("invalid pod JSON")
	}
	_, s, e := preflight(p, *cn)
	if e != nil {
		return e
	}
	if p.Metadata.UID == "" || p.Spec.NodeName == "" {
		return errors.New("source pod must have UID and nodeName")
	}
	originalUID := p.Metadata.UID
	if e = nodeOK(ctx, r, c, p.Spec.NodeName); e != nil {
		return e
	}
	if e = ensureHelperSA(ctx, r, c); e != nil {
		return e
	}
	job := "sandbox-oci-snapshot-" + fmt.Sprintf("%08x", rand.Uint32())
	id := strings.TrimPrefix(s.ContainerID, "containerd://")
	jobObj := helperJob(helperJobConfig{
		name: job, helper: *helper, node: p.Spec.NodeName, timeout: *timeout,
		uid: p.Metadata.UID, id: id, podName: *podName, namespace: c.namespace,
		container: *cn, image: *image,
		sourceRegistryInsecure: *sourceRegistryInsecure,
		targetRegistryInsecure: *targetRegistryInsecure,
	})
	body, _ := json.Marshal(jobObj)
	if _, stderr, e := r.Run(ctx, []string{"--context", c.context, "-n", c.namespace, "create", "-f", "-"}, body); e != nil {
		return fmt.Errorf("create helper job: %w: %s", e, stderr)
	}
	start := time.Now()
	result, e := waitHelper(ctx, r, c, job, *timeout)
	if e != nil {
		return fmt.Errorf("helper Job %s: %w", job, e)
	}
	if e := validateHelperResult(result, originalUID, id, *cn, *image); e != nil {
		return e
	}
	b, e = kget(ctx, r, c, "pod", *podName)
	if e != nil {
		return e
	}
	if json.Unmarshal(b, &p) != nil {
		return errors.New("invalid source pod JSON after snapshot")
	}
	_, after, e := preflight(p, *cn)
	if e != nil {
		return e
	}
	if p.Metadata.UID != originalUID || strings.TrimPrefix(after.ContainerID, "containerd://") != id {
		return errors.New("source container changed during snapshot")
	}
	return emit(out, c.output, map[string]any{"image": *image, "digest": result.Containers[0].Digest, "sourcePodUID": originalUID, "sourceContainerID": id, "node": p.Spec.NodeName, "job": job, "elapsedSeconds": int(time.Since(start).Seconds())})
}

type helperResult struct {
	Containers        []struct{ Name, Image, Digest string } `json:"containers"`
	SourcePodUID      string                                 `json:"sourcePodUID"`
	SourceContainerID string                                 `json:"sourceContainerID"`
}

func validateHelperResult(r helperResult, uid, id, name, image string) error {
	if r.SourcePodUID != uid || r.SourceContainerID != id {
		return errors.New("helper result source identity mismatch")
	}
	if len(r.Containers) != 1 || r.Containers[0].Name != name || r.Containers[0].Image != image || !sha256(r.Containers[0].Digest) {
		return errors.New("malformed helper result")
	}
	return nil
}

func waitHelper(ctx context.Context, r runner, c *common, job string, timeout time.Duration) (helperResult, error) {
	until := time.Now().Add(timeout)
	for time.Now().Before(until) {
		b, _, e := r.Run(ctx, []string{"--context", c.context, "-n", c.namespace, "get", "pods", "-l", "job-name=" + job, "-o", "json"}, nil)
		if e != nil {
			return helperResult{}, e
		}
		var raw struct {
			Items []struct {
				Status struct {
					ContainerStatuses []struct {
						Name  string `json:"name"`
						State struct {
							Terminated *struct {
								ExitCode int    `json:"exitCode"`
								Message  string `json:"message"`
							} `json:"terminated"`
						} `json:"state"`
					} `json:"containerStatuses"`
				} `json:"status"`
			} `json:"items"`
		}
		if json.Unmarshal(b, &raw) != nil {
			return helperResult{}, errors.New("invalid helper pod JSON")
		}
		for _, p := range raw.Items {
			for _, q := range p.Status.ContainerStatuses {
				if q.Name == "helper" && q.State.Terminated != nil {
					if q.State.Terminated.ExitCode != 0 {
						return helperResult{}, fmt.Errorf("helper exited %d: %s", q.State.Terminated.ExitCode, q.State.Terminated.Message)
					}
					var z helperResult
					if json.Unmarshal([]byte(q.State.Terminated.Message), &z) != nil {
						return helperResult{}, errors.New("helper returned invalid JSON")
					}
					return z, nil
				}
			}
		}
		select {
		case <-ctx.Done():
			return helperResult{}, ctx.Err()
		case <-time.After(time.Second):
		}
	}
	return helperResult{}, errors.New("timed out; Job retained for helper recovery")
}

type helperJobConfig struct {
	name, helper, node                             string
	timeout                                        time.Duration
	uid, id, podName, namespace, container         string
	image                                          string
	sourceRegistryInsecure, targetRegistryInsecure bool
}

func helperJob(c helperJobConfig) map[string]any {
	labels := map[string]string{"io.sandbox-oci.lab": "true"}
	return map[string]any{"apiVersion": "batch/v1", "kind": "Job", "metadata": map[string]any{"name": c.name, "labels": labels}, "spec": map[string]any{"backoffLimit": 0, "activeDeadlineSeconds": int64(c.timeout.Seconds()), "template": map[string]any{"metadata": map[string]any{"labels": labels}, "spec": map[string]any{"serviceAccountName": "sandbox-oci-helper", "automountServiceAccountToken": false, "nodeName": c.node, "restartPolicy": "Never", "terminationGracePeriodSeconds": 90, "containers": []any{map[string]any{"name": "helper", "image": c.helper, "securityContext": map[string]any{"privileged": true}, "args": []string{c.podName, c.namespace, c.container + ":" + c.image}, "env": []any{env("SOURCE_POD_UID", c.uid), env("EXPECTED_CONTAINER_ID", c.id), env("CONTAINERD_NAMESPACE", "k8s.io"), env("SNAPSHOT_REGISTRY_INSECURE", fmt.Sprint(c.targetRegistryInsecure)), env("SOURCE_IMAGE_REGISTRY_INSECURE", fmt.Sprint(c.sourceRegistryInsecure))}, "volumeMounts": []any{mount("containerd-socket", "/run/containerd/containerd.sock"), mount("containerd-state", "/var/lib/containerd")}}}, "volumes": []any{hostVol("containerd-socket", "/run/containerd/containerd.sock", "Socket"), hostVol("containerd-state", "/var/lib/containerd", "Directory")}}}}}
}
func env(n, v string) map[string]string   { return map[string]string{"name": n, "value": v} }
func mount(n, p string) map[string]string { return map[string]string{"name": n, "mountPath": p} }
func hostVol(n, p, t string) map[string]any {
	return map[string]any{"name": n, "hostPath": map[string]string{"path": p, "type": t}}
}

func ensureHelperSA(ctx context.Context, r runner, c *common) error {
	b, stderr, err := r.Run(ctx, []string{"--context", c.context, "-n", c.namespace, "get", "serviceaccount", "sandbox-oci-helper", "--ignore-not-found", "-o", "json"}, nil)
	if err != nil {
		return fmt.Errorf("get helper ServiceAccount: %w: %s", err, stderr)
	}
	if len(strings.TrimSpace(string(b))) != 0 {
		var existing struct {
			Metadata struct {
				Labels map[string]string `json:"labels"`
			} `json:"metadata"`
		}
		if json.Unmarshal(b, &existing) != nil {
			return errors.New("invalid helper ServiceAccount JSON")
		}
		if existing.Metadata.Labels["io.sandbox-oci.lab"] != "true" {
			return errors.New("existing sandbox-oci-helper ServiceAccount is not owned by sandbox-oci")
		}
		return nil
	}
	sa := []byte(`{"apiVersion":"v1","kind":"ServiceAccount","metadata":{"name":"sandbox-oci-helper","labels":{"io.sandbox-oci.lab":"true"}},"automountServiceAccountToken":false}`)
	_, stderr, err = r.Run(ctx, []string{"--context", c.context, "-n", c.namespace, "create", "-f", "-"}, sa)
	if err != nil {
		return fmt.Errorf("create helper ServiceAccount: %w: %s", err, stderr)
	}
	return nil
}

func restore(ctx context.Context, r runner, a []string, out io.Writer) error {
	f, c := flags("restore", a)
	image := f.String("image", "", "image digest reference")
	name := f.String("pod", "", "new pod name")
	timeout := f.Duration("timeout", 10*time.Minute, "timeout")
	command := f.String("command", "", "JSON command array")
	args := f.String("args", "", "JSON argument array")
	workingDir := f.String("working-dir", "", "container working directory")
	if e := f.Parse(a); e != nil {
		return e
	}
	if e := validateCommon(f, c); e != nil {
		return e
	}
	if *name == "" || !digestRef(*image) {
		return errors.New("--image must be a digest-pinned reference and --pod is required")
	}
	if *timeout <= 0 {
		return errors.New("--timeout must be positive")
	}
	var cmd, argv []string
	if *command != "" && json.Unmarshal([]byte(*command), &cmd) != nil {
		return errors.New("--command must be a JSON string array")
	}
	if *args != "" && json.Unmarshal([]byte(*args), &argv) != nil {
		return errors.New("--args must be a JSON string array")
	}
	cont := map[string]any{"name": "sandbox", "image": *image, "imagePullPolicy": "Always"}
	if *command != "" {
		cont["command"] = cmd
	}
	if *args != "" {
		cont["args"] = argv
	}
	if *workingDir != "" {
		cont["workingDir"] = *workingDir
	}
	obj := map[string]any{"apiVersion": "v1", "kind": "Pod", "metadata": map[string]any{"name": *name, "labels": map[string]string{"io.sandbox-oci.lab": "true"}}, "spec": map[string]any{"automountServiceAccountToken": false, "restartPolicy": "Never", "containers": []any{cont}}}
	b, _ := json.Marshal(obj)
	if _, stderr, e := r.Run(ctx, []string{"--context", c.context, "-n", c.namespace, "create", "-f", "-"}, b); e != nil {
		return fmt.Errorf("create restore pod: %w: %s", e, stderr)
	}
	wctx, cancel := context.WithTimeout(ctx, *timeout)
	defer cancel()
	if _, stderr, e := r.Run(wctx, []string{"--context", c.context, "-n", c.namespace, "wait", "--for=condition=Ready", "pod/" + *name, "--timeout=" + timeout.String()}, nil); e != nil {
		return fmt.Errorf("wait for restored pod: %w: %s", e, stderr)
	}
	return emit(out, c.output, map[string]string{"pod": *name, "image": *image})
}

var digestRE = regexp.MustCompile(`^sha256:[a-f0-9]{64}$`)

func sha256(s string) bool    { return digestRE.MatchString(s) }
func digestRef(s string) bool { i := strings.LastIndex(s, "@sha256:"); return i > 0 && sha256(s[i+1:]) }
func emit(w io.Writer, format string, v any) error {
	if format == "json" {
		b, e := json.Marshal(v)
		if e != nil {
			return e
		}
		_, e = fmt.Fprintln(w, string(b))
		return e
	}
	_, e := fmt.Fprintln(w, v)
	return e
}
