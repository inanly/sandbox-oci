//go:build ignore

// licensecollector writes third-party Go module attribution files for the helper image.
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

type module struct {
	Path    string  `json:"path"`
	Version string  `json:"version"`
	Sum     string  `json:"sum"`
	Dir     string  `json:"dir"`
	Main    bool    `json:"main,omitempty"`
	Replace *module `json:"replace,omitempty"`
}

type packageInfo struct {
	Module *module
}

type collectedModule struct {
	Path    string   `json:"path"`
	Version string   `json:"version"`
	Sum     string   `json:"sum"`
	Dir     string   `json:"dir"`
	Replace *module  `json:"replace,omitempty"`
	Files   []string `json:"files"`
}

type manifest struct {
	Modules []collectedModule `json:"modules"`
}

func main() {
	output := flag.String("output", "/licenses", "directory for copied attribution files and manifest.json")
	flag.Parse()
	if flag.NArg() != 0 {
		fatalf("unexpected positional argument %q", flag.Arg(0))
	}
	if err := collect(*output); err != nil {
		fatalf("%v", err)
	}
}

func collect(output string) error {
	mods, err := listedModules()
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Join(output, "modules"), 0o755); err != nil {
		return fmt.Errorf("create output directory: %w", err)
	}
	result := manifest{Modules: make([]collectedModule, 0, len(mods))}
	for _, mod := range mods {
		files, err := copyAttributions(output, mod)
		if err != nil {
			return err
		}
		result.Modules = append(result.Modules, collectedModule{
			Path: mod.Path, Version: mod.Version, Sum: mod.Sum, Dir: resolvedModule(mod).Dir,
			Replace: mod.Replace, Files: files,
		})
	}
	data, err := json.MarshalIndent(result, "", "  ")
	if err != nil {
		return fmt.Errorf("encode manifest: %w", err)
	}
	if err := os.WriteFile(filepath.Join(output, "manifest.json"), append(data, '\n'), 0o644); err != nil {
		return fmt.Errorf("write manifest: %w", err)
	}
	return nil
}

func listedModules() ([]module, error) {
	tags := os.Getenv("BUILD_TAGS")
	args := []string{"list", "-deps", "-json", "-tags=" + tags, "./cmd/sandbox-oci-helper"}
	cmd := exec.Command("go", args...)
	stdout, stderr, err := run(cmd)
	if err != nil {
		return nil, fmt.Errorf("go %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(string(stderr)))
	}
	dec := json.NewDecoder(bytes.NewReader(stdout))
	byKey := map[string]module{}
	for {
		var pkg packageInfo
		err := dec.Decode(&pkg)
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("decode go list output: %w", err)
		}
		if pkg.Module == nil || pkg.Module.Main {
			continue
		}
		effective := resolvedModule(*pkg.Module)
		if effective.Path == "" || effective.Version == "" || effective.Dir == "" {
			return nil, fmt.Errorf("unsupported resolved module without path, version, and source directory: %#v", effective)
		}
		key := effective.Path + "@" + effective.Version
		byKey[key] = effective
	}
	mods := make([]module, 0, len(byKey))
	for _, mod := range byKey {
		mods = append(mods, mod)
	}
	sort.Slice(mods, func(i, j int) bool {
		return mods[i].Path+"@"+mods[i].Version < mods[j].Path+"@"+mods[j].Version
	})
	return mods, nil
}

func resolvedModule(mod module) module {
	for mod.Replace != nil {
		mod = *mod.Replace
	}
	return mod
}

func copyAttributions(output string, mod module) ([]string, error) {
	source := resolvedModule(mod).Dir
	destination := filepath.Join(output, "modules", filepath.FromSlash(mod.Path)+"@"+mod.Version)
	var copied []string
	licenseFound := false
	err := filepath.WalkDir(source, func(path string, entry os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.IsDir() {
			return nil
		}
		if entry.Type()&os.ModeSymlink != 0 {
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() || !attributionName(entry.Name()) {
			return nil
		}
		rel, err := filepath.Rel(source, path)
		if err != nil {
			return err
		}
		target := filepath.Join(destination, rel)
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return err
		}
		if err := copyFile(path, target); err != nil {
			return err
		}
		copied = append(copied, filepath.ToSlash(rel))
		if licenseName(entry.Name()) {
			licenseFound = true
		}
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("collect attribution files for %s@%s: %w", mod.Path, mod.Version, err)
	}
	if !licenseFound {
		return nil, fmt.Errorf("module %s@%s has no LICENSE, LICENCE, or COPYING file", mod.Path, mod.Version)
	}
	sort.Strings(copied)
	return copied, nil
}

func attributionName(name string) bool {
	name = strings.ToUpper(name)
	return strings.HasPrefix(name, "LICENSE") || strings.HasPrefix(name, "LICENCE") ||
		strings.HasPrefix(name, "NOTICE") || strings.HasPrefix(name, "COPYING") ||
		strings.HasPrefix(name, "COPYRIGHT") || strings.HasPrefix(name, "PATENTS") ||
		strings.HasPrefix(name, "AUTHORS")
}

func licenseName(name string) bool {
	name = strings.ToUpper(name)
	return strings.HasPrefix(name, "LICENSE") || strings.HasPrefix(name, "LICENCE") || strings.HasPrefix(name, "COPYING")
}

func copyFile(source, target string) error {
	in, err := os.Open(source)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	_, copyErr := io.Copy(out, in)
	closeErr := out.Close()
	if copyErr != nil {
		return copyErr
	}
	return closeErr
}

func run(cmd *exec.Cmd) ([]byte, []byte, error) {
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	err := cmd.Run()
	return stdout.Bytes(), stderr.Bytes(), err
}

func fatalf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "licensecollector: "+format+"\n", args...)
	os.Exit(1)
}
