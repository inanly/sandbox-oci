//go:build faulttest

package main

import (
	"context"
	"fmt"
	"os"
)

// This gate is absent from the normal helper binary.
func pauseTestGate(ctx context.Context) error {
	if os.Getenv("SANDBOX_OCI_TEST_PAUSE_GATE") != "true" {
		return nil
	}
	fmt.Fprintln(os.Stderr, "TEST_GATE_PAUSED")
	<-ctx.Done()
	return ctx.Err()
}
