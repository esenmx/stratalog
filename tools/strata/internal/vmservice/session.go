package vmservice

import (
	"context"
	"maps"
	"time"

	"github.com/esenmx/stratalog/tools/strata/internal/record"
)

// Item is one record ready to show. Restarted marks the first record of a
// restarted writer: a new writer generation in its isolate, or a new isolate
// after others were seen.
type Item struct {
	Rec       record.Record
	Restarted bool
}

// Dedup tracks every record seen, across connections, by isolate and seq.
//
// A seq seen before with the same time is the same record — history and
// live overlap in either order. A new writer generation (configureLogging
// run again, or a hot restart in the same isolate) restarts seq at 1 with
// newer times: a seq seen before with a different time, or an unseen seq
// below the newest but timed after it. An unseen older seq timed before the
// newest is just an older record — one the ring evicted before a history
// snapshot — and is kept as-is.
type Dedup struct {
	isolates map[string]*isolateSeen
}

type isolateSeen struct {
	last     int64
	lastTime time.Time           // time of the record at last
	seen     map[int64]time.Time // seq → record time, current generation
}

// NewDedup returns an empty tracker.
func NewDedup() *Dedup { return &Dedup{isolates: map[string]*isolateSeen{}} }

// Live records a live record: keep is false for one already seen, and
// restarted marks a new writer generation.
func (d *Dedup) Live(r record.Record) (keep, restarted bool) { return d.observe(r) }

// History records a history record, by the same rules as [Dedup.Live].
func (d *Dedup) History(r record.Record) (keep, restarted bool) { return d.observe(r) }

func (d *Dedup) observe(r record.Record) (keep, restarted bool) {
	iso, known := d.isolates[r.IsolateID]
	switch {
	case !known:
		restarted = len(d.isolates) > 0
		iso = &isolateSeen{seen: map[int64]time.Time{}}
		d.isolates[r.IsolateID] = iso
	default:
		at, seen := iso.seen[r.Seq]
		switch {
		case seen && at.Equal(r.Time):
			return false, false
		case seen, r.Seq < iso.last && r.Time.After(iso.lastTime):
			restarted = true
			iso.reset()
		}
	}
	iso.add(r)
	return true, restarted
}

func (s *isolateSeen) reset() {
	s.last, s.lastTime = 0, time.Time{}
	clear(s.seen)
}

// seenWindow bounds the seqs kept per isolate behind the newest: twice the
// writer's 1000-record ring, so no history repeat escapes dedup.
const seenWindow = 2000

func (s *isolateSeen) add(r record.Record) {
	s.seen[r.Seq] = r.Time
	if r.Seq > s.last {
		s.last, s.lastTime = r.Seq, r.Time
	}
	if len(s.seen) > 2*seenWindow {
		maps.DeleteFunc(s.seen, func(seq int64, _ time.Time) bool { return seq <= s.last-seenWindow })
	}
}

// historyTimeout bounds one history fetch; a paused isolate never replies.
var historyTimeout = 5 * time.Second

// Stream subscribes c to the stratalog stream and emits its records until
// ctx ends or the connection drops, returning why it stopped.
//
// History from every isolate serving [HistoryExtension] is emitted ahead of
// live records: live records arriving while history is in flight are held
// back, never dropped. An isolate without the extension at connect (the app
// still booting) is retried on its first live record. A fetch that fails or
// outlives [historyTimeout] only costs that isolate's history.
func Stream(ctx context.Context, c *Client, d *Dedup, emit func(Item)) error {
	if err := c.Listen(ctx); err != nil {
		return err
	}
	isolates, err := c.HistoryIsolates(ctx)
	if err != nil {
		return err
	}

	results := make(chan []record.Record)
	stop := make(chan struct{})
	defer close(stop)
	fetched := map[string]bool{}
	inflight := 0
	fetch := func(isolateID string) {
		fetched[isolateID] = true
		inflight++
		go func() {
			fctx, cancel := context.WithTimeout(ctx, historyTimeout)
			defer cancel()
			recs, _ := c.History(fctx, isolateID)
			select {
			case results <- recs:
			case <-stop:
			}
		}()
	}
	for _, id := range isolates {
		fetch(id)
	}

	// Records go through Dedup only when emitted, in emit order: judged on
	// arrival, a held seq would be emitted after newer history records.
	var held, history []record.Record
	live := func(r record.Record) {
		if keep, restarted := d.Live(r); keep {
			emit(Item{Rec: r, Restarted: restarted})
		}
	}
	flush := func() {
		// Held records older than their isolate's oldest history record were
		// evicted from the ring before the snapshot: they come first.
		oldest := map[string]time.Time{}
		for _, r := range history {
			if t, ok := oldest[r.IsolateID]; !ok || r.Time.Before(t) {
				oldest[r.IsolateID] = r.Time
			}
		}
		var after []record.Record
		for _, r := range held {
			if t, ok := oldest[r.IsolateID]; ok && r.Time.Before(t) {
				live(r)
			} else {
				after = append(after, r)
			}
		}
		for _, r := range history {
			if keep, restarted := d.History(r); keep {
				emit(Item{Rec: r, Restarted: restarted})
			}
		}
		for _, r := range after {
			live(r)
		}
		held, history = nil, nil
	}

	records := c.Records()
	for {
		// After a drop, in-flight fetches still finish (their replies may
		// have arrived just before it) before the final flush.
		if records == nil && inflight == 0 {
			flush()
			return c.Err()
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case r, ok := <-records:
			if !ok {
				records = nil
				continue
			}
			if !fetched[r.IsolateID] {
				fetch(r.IsolateID)
			}
			if inflight > 0 {
				held = append(held, r)
			} else {
				live(r)
			}
		case recs := <-results:
			inflight--
			history = append(history, recs...)
			if inflight == 0 {
				flush()
			}
		}
	}
}
