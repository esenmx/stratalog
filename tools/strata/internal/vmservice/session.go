package vmservice

import (
	"context"
	"time"

	"github.com/esenmx/stratalog/tools/strata/internal/record"
)

// Item is one record ready to show. Restarted marks the first record of a
// restarted writer: a seq that repeats or goes back in its isolate, or a new
// isolate appearing live after others were seen.
type Item struct {
	Rec       record.Record
	Restarted bool
}

// Dedup tracks every record seen, across connections, by isolate and seq.
//
// A seq seen before with the same time is the same record — history and
// live overlap, in either order, since a history response can be handled
// before live events that preceded it on the wire. A seq seen before with a
// different time is a new writer generation, never dropped.
type Dedup struct {
	isolates map[string]*isolateSeen
}

type isolateSeen struct {
	last int64
	seen map[int64]time.Time // seq → record time, current generation
}

// NewDedup returns an empty tracker.
func NewDedup() *Dedup { return &Dedup{isolates: map[string]*isolateSeen{}} }

// Live records a live record: keep is false for one already seen, and
// restarted marks a new writer generation.
func (d *Dedup) Live(r record.Record) (keep, restarted bool) {
	iso, known := d.isolates[r.IsolateID]
	if !known {
		restarted = len(d.isolates) > 0
		iso = d.track(r.IsolateID)
	} else if at, seen := iso.seen[r.Seq]; seen && at.Equal(r.Time) {
		return false, false
	} else if r.Seq <= iso.last {
		restarted = true
		iso.reset()
	}
	iso.add(r)
	return true, restarted
}

// History records a history record: keep is false for one already seen, and
// restarted marks a writer that restarted while nobody was listening.
func (d *Dedup) History(r record.Record) (keep, restarted bool) {
	iso, known := d.isolates[r.IsolateID]
	if !known {
		iso = d.track(r.IsolateID)
	} else if at, seen := iso.seen[r.Seq]; seen {
		if at.Equal(r.Time) {
			return false, false
		}
		restarted = true
		iso.reset()
	}
	iso.add(r)
	return true, restarted
}

func (d *Dedup) track(isolateID string) *isolateSeen {
	iso := &isolateSeen{seen: map[int64]time.Time{}}
	d.isolates[isolateID] = iso
	return iso
}

func (s *isolateSeen) reset() {
	s.last = 0
	clear(s.seen)
}

func (s *isolateSeen) add(r record.Record) {
	s.seen[r.Seq] = r.Time
	s.last = max(s.last, r.Seq)
}

type historyResult struct {
	recs []record.Record
	err  error
}

// Stream subscribes c to the stratalog stream and emits its records until
// ctx ends or the connection drops, returning why it stopped.
//
// History from every isolate serving [HistoryExtension] is emitted ahead of
// live records: live records arriving while history is in flight are held
// back, never dropped. An isolate without the extension at connect (the app
// still booting) is retried on its first live record.
func Stream(ctx context.Context, c *Client, d *Dedup, emit func(Item)) error {
	if err := c.Listen(ctx); err != nil {
		return err
	}
	isolates, err := c.HistoryIsolates(ctx)
	if err != nil {
		return err
	}

	results := make(chan historyResult)
	stop := make(chan struct{})
	defer close(stop)
	fetched := map[string]bool{}
	inflight := 0
	fetch := func(isolateID string) {
		fetched[isolateID] = true
		inflight++
		go func() {
			recs, err := c.History(ctx, isolateID)
			select {
			case results <- historyResult{recs, err}:
			case <-stop:
			}
		}()
	}
	for _, id := range isolates {
		fetch(id)
	}

	var held []Item
	records := c.Records()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case r, ok := <-records:
			if !ok {
				for _, it := range held {
					emit(it)
				}
				return c.Err()
			}
			if !fetched[r.IsolateID] {
				fetch(r.IsolateID)
			}
			keep, restarted := d.Live(r)
			if !keep {
				continue
			}
			it := Item{Rec: r, Restarted: restarted}
			if inflight > 0 {
				held = append(held, it)
			} else {
				emit(it)
			}
		case h := <-results:
			inflight--
			// A failed fetch only costs history; live records still flow.
			for _, r := range h.recs {
				if keep, restarted := d.History(r); keep {
					emit(Item{Rec: r, Restarted: restarted})
				}
			}
			if inflight == 0 {
				for _, it := range held {
					emit(it)
				}
				held = nil
			}
		}
	}
}
