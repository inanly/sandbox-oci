//go:build !faulttest

package main

import "context"

func pauseTestGate(context.Context) error { return nil }
