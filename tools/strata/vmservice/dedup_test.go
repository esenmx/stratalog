package vmservice

import (
	"fmt"
	"testing"
)

func TestDedupPrunesWorkerIsolatesButKeepsMain(t *testing.T) {
	d := NewDedup()
	d.Live(rec("isolates/main", "main", 0, 1))
	// Every compute() / Isolate.run call is a new isolate.
	for i := range 3 * maxIsolates {
		if keep, restarted := d.Live(rec(fmt.Sprintf("isolates/w%d", i), "worker", 0, 1)); !keep || restarted {
			t.Fatalf("worker %d: keep %v restarted %v, want true false", i, keep, restarted)
		}
	}
	if len(d.isolates) > maxIsolates {
		t.Errorf("tracking %d isolates, want at most %d", len(d.isolates), maxIsolates)
	}
	if keep, restarted := d.Live(rec("isolates/main", "main", 0, 1)); keep || restarted {
		t.Errorf("main's repeat after pruning: keep %v restarted %v, want false false", keep, restarted)
	}
}
