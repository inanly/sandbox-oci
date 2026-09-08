package cli

import (
	"context"
	"encoding/json"
	"io"
	"strings"
	"testing"
	"time"
)

func validPod() pod {
	var p pod
	p.Status.Phase = "Running"
	p.Spec.Containers = []container{{Name: "app"}}
	p.Status.ContainerStatuses = []status{{Name: "app", Ready: true, ContainerID: "containerd://abc"}}
	return p
}

func TestHelperJobRecoveryBudgetAndRegistryPolicy(t *testing.T) {
	job := helperJob(helperJobConfig{name: "snapshot-x", helper: "helper@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", node: "node-a", timeout: 10 * time.Minute, uid: "uid", id: "container", podName: "source", namespace: "ns", container: "app", image: "registry/run"})
	spec := job["spec"].(map[string]any)
	if got := spec["activeDeadlineSeconds"].(int64); got != 600 {
		t.Fatalf("active deadline = %d, want 600", got)
	}
	podSpec := spec["template"].(map[string]any)["spec"].(map[string]any)
	if got := podSpec["terminationGracePeriodSeconds"].(int); got != 90 {
		t.Fatalf("termination grace = %d, want 90", got)
	}
	container := podSpec["containers"].([]any)[0].(map[string]any)
	env := map[string]string{}
	for _, raw := range container["env"].([]any) {
		item := raw.(map[string]string)
		env[item["name"]] = item["value"]
	}
	if env["SNAPSHOT_REGISTRY_INSECURE"] != "false" || env["SOURCE_IMAGE_REGISTRY_INSECURE"] != "false" {
		t.Fatalf("unexpected registry insecurity policy: %#v", env)
	}
}

type snapshotRunner struct{ created []byte }

func (r *snapshotRunner) Run(_ context.Context, args []string, in []byte) ([]byte, []byte, error) {
	joined := strings.Join(args, " ")
	switch {
	case strings.Contains(joined, "get pod source"):
		return []byte(`{"metadata":{"uid":"uid"},"spec":{"nodeName":"node-a","containers":[{"name":"app"}]},"status":{"phase":"Running","containerStatuses":[{"name":"app","containerID":"containerd://container","ready":true}]}}`), nil, nil
	case strings.Contains(joined, "get node node-a"):
		return []byte(`{"status":{"nodeInfo":{"operatingSystem":"linux","architecture":"amd64","containerRuntimeVersion":"containerd://1.7"}}}`), nil, nil
	case strings.Contains(joined, "get serviceaccount sandbox-oci-helper"):
		return nil, nil, nil
	case strings.Contains(joined, "create -f -"):
		r.created = append([]byte(nil), in...)
		return nil, nil, nil
	case strings.Contains(joined, "get pods -l job-name="):
		message, _ := json.Marshal(map[string]any{
			"containers":        []map[string]string{{"Name": "app", "Image": "registry/run", "Digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}},
			"sourcePodUID":      "uid",
			"sourceContainerID": "container",
		})
		body, _ := json.Marshal(map[string]any{"items": []any{map[string]any{"status": map[string]any{"containerStatuses": []any{map[string]any{"name": "helper", "state": map[string]any{"terminated": map[string]any{"exitCode": 0, "message": string(message)}}}}}}}})
		return body, nil, nil
	default:
		return nil, nil, nil
	}
}

func TestSnapshotRegistryFlagsAreIndependent(t *testing.T) {
	d := "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	for _, tc := range []struct {
		name, source, target string
		flags                []string
	}{
		{name: "defaults false", source: "false", target: "false"},
		{name: "source true", source: "true", target: "false", flags: []string{"--source-registry-insecure"}},
		{name: "target true", source: "false", target: "true", flags: []string{"--target-registry-insecure"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := &snapshotRunner{}
			a := []string{"--context", "test", "--pod", "source", "--container", "app", "--image", "registry/run", "--helper-image", "helper@" + d, "--source-quiesced"}
			a = append(a, tc.flags...)
			if err := snapshot(context.Background(), r, a, io.Discard); err != nil {
				t.Fatalf("snapshot: %v", err)
			}
			var job map[string]any
			if err := json.Unmarshal(r.created, &job); err != nil {
				t.Fatalf("decode created Job: %v", err)
			}
			container := job["spec"].(map[string]any)["template"].(map[string]any)["spec"].(map[string]any)["containers"].([]any)[0].(map[string]any)
			env := map[string]string{}
			for _, raw := range container["env"].([]any) {
				item := raw.(map[string]any)
				env[item["name"].(string)] = item["value"].(string)
			}
			if env["SOURCE_IMAGE_REGISTRY_INSECURE"] != tc.source || env["SNAPSHOT_REGISTRY_INSECURE"] != tc.target {
				t.Fatalf("registry env = %#v, want source=%s target=%s", env, tc.source, tc.target)
			}
		})
	}
}

func TestPreflightRejectsUnsafeSources(t *testing.T) {
	cases := []struct {
		name   string
		change func(*pod)
	}{
		{"volume", func(p *pod) { p.Spec.Volumes = []json.RawMessage{json.RawMessage(`{}`)} }},
		{"multiple containers", func(p *pod) { p.Spec.Containers = append(p.Spec.Containers, container{Name: "second"}) }},
		{"deleting", func(p *pod) { x := "now"; p.Metadata.DeletionTimestamp = &x }},
		{"probe", func(p *pod) { p.Spec.Containers[0].LivenessProbe = json.RawMessage(`{}`) }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			p := validPod()
			tc.change(&p)
			if _, _, e := preflight(p, "app"); e == nil {
				t.Fatal("preflight accepted unsafe source")
			}
		})
	}
}
func TestDigestValidation(t *testing.T) {
	d := "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	if !sha256(d) || !digestRef("registry.local/x@"+d) {
		t.Fatal("valid digest rejected")
	}
	if sha256("sha256:bad") || digestRef("registry.local/x:latest") {
		t.Fatal("invalid digest accepted")
	}
}
func TestMalformedHelperResult(t *testing.T) {
	var r helperResult
	if json.Unmarshal([]byte(`{"containers":"bad"}`), &r) == nil {
		t.Fatal("malformed helper result decoded")
	}
}

func TestHelperResultRequiresExactIdentity(t *testing.T) {
	d := "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	r := helperResult{SourcePodUID: "uid", SourceContainerID: "id"}
	r.Containers = append(r.Containers, struct{ Name, Image, Digest string }{"app", "registry/x:run", d})
	if err := validateHelperResult(r, "uid", "id", "app", "registry/x:run"); err != nil {
		t.Fatalf("valid helper result: %v", err)
	}
	if err := validateHelperResult(r, "other", "id", "app", "registry/x:run"); err == nil {
		t.Fatal("mismatched pod UID accepted")
	}
	if err := validateHelperResult(r, "uid", "id", "app", "registry/x:other"); err == nil {
		t.Fatal("mismatched image accepted")
	}
}
