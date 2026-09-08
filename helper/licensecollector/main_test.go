//go:build ignore

package main

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestCopyAttributionsRejectsNoticeOnlyModule(t *testing.T) {
	source := t.TempDir()
	if err := os.WriteFile(filepath.Join(source, "NOTICE"), []byte("notice only"), 0o644); err != nil {
		t.Fatal(err)
	}
	err := func() error {
		_, err := copyAttributions(t.TempDir(), module{Path: "example.com/notice", Version: "v1.0.0", Dir: source})
		return err
	}()
	if err == nil || !strings.Contains(err.Error(), "no LICENSE, LICENCE, or COPYING") {
		t.Fatalf("notice-only module error = %v", err)
	}
}

func TestCopyAttributionsCopiesNestedFilesAndPreservesContents(t *testing.T) {
	source := t.TempDir()
	nested := filepath.Join(source, "third_party", "component")
	if err := os.MkdirAll(nested, 0o755); err != nil {
		t.Fatal(err)
	}
	files := map[string]string{
		"LICENSE": "root license\n",
		filepath.Join("third_party", "component", "NOTICE.md"): "nested notice\n",
		filepath.Join("third_party", "component", "README.md"): "not attribution\n",
	}
	for name, contents := range files {
		if err := os.WriteFile(filepath.Join(source, name), []byte(contents), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	output := t.TempDir()
	mod := module{Path: "example.com/acme/component", Version: "v1.2.3", Dir: source}
	copied, err := copyAttributions(output, mod)
	if err != nil {
		t.Fatalf("copyAttributions: %v", err)
	}
	want := []string{"LICENSE", "third_party/component/NOTICE.md"}
	if !reflect.DeepEqual(copied, want) {
		t.Fatalf("copied = %#v, want %#v", copied, want)
	}
	destination := filepath.Join(output, "modules", "example.com", "acme", "component@v1.2.3")
	for name, contents := range map[string]string{
		"LICENSE": "root license\n",
		filepath.Join("third_party", "component", "NOTICE.md"): "nested notice\n",
	} {
		got, err := os.ReadFile(filepath.Join(destination, name))
		if err != nil || string(got) != contents {
			t.Fatalf("copied %s = %q, %v", name, got, err)
		}
	}
	if _, err := os.Stat(filepath.Join(destination, "third_party", "component", "README.md")); !os.IsNotExist(err) {
		t.Fatalf("unrelated file stat error = %v, want not exist", err)
	}
}

func TestResolvedModuleUsesFinalReplacement(t *testing.T) {
	final := module{Path: "example.com/final", Version: "v1.3.0", Dir: "/module-cache/final"}
	middle := module{Path: "example.com/middle", Version: "v1.2.0", Replace: &final}
	initial := module{Path: "example.com/initial", Version: "v1.1.0", Replace: &middle}
	if got := resolvedModule(initial); !reflect.DeepEqual(got, final) {
		t.Fatalf("resolved module = %#v, want %#v", got, final)
	}
}
