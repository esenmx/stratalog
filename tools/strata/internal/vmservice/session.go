package vmservice

import (
	"context"
	"maps"
	"sync"
	"time"

	"github.com/esenmx/stratalog/tools/strata/internal/record"
)

// Item is one record ready to show. Restarted marks the first record of a new
// app session: a relaunched Dart VM, a replaced "main" isolate (Flutter hot
// restart), or a reset primary writer generation.
type Item struct {
	Rec       record.Record
	Restarted bool
}

// Dedup tracks seen records across connections by VM session, isolate, and seq.
//
// Worker isolates (Isolate.run, compute, Drift background isolates) are tracked
// independently and never trigger false "session restarted" dividers.
type Dedup struct {
	vmStart       int64
	pendingReset  bool
	mainIsolateID string
	hasEmitted    bool
	names         map[string]string
	isolates      map[string]*isolateSeen
}

type isolateSeen struct {
	last     int64
	lastTime time.Time
	seen     map[int64]time.Time
}

const (
	// seenWindow bounds the seqs kept per isolate behind the newest: twice the
	// writer's 1000-record ring, so no history repeat escapes dedup.
	seenWindow  = 2000
	maxIsolates = 128
)

// NewDedup returns an empty session & deduplication tracker.
func NewDedup() *Dedup {
	return &Dedup{
		names:    map[string]string{},
		isolates: map[string]*isolateSeen{},
	}
}

// ObserveVM records the connected VM's identity and isolate names. A changed
// VM StartTime across connections marks the next emitted record as a session
// restart.
func (d *Dedup) ObserveVM(vm VMInfo) {
	if vm.StartTime != 0 {
		if d.vmStart != 0 && vm.StartTime != d.vmStart {
			d.pendingReset = d.hasEmitted
			clear(d.isolates)
			clear(d.names)
			d.mainIsolateID = ""
		}
		d.vmStart = vm.StartTime
	}
	for _, iso := range vm.Isolates {
		if iso.Name != "" {
			d.names[iso.ID] = iso.Name
		}
	}
}

// Live records a live record: keep is false for one already seen, and
// restarted marks a new app session.
func (d *Dedup) Live(r record.Record) (keep, restarted bool) { return d.observe(r) }

// History records a history record, by the same rules as [Dedup.Live].
func (d *Dedup) History(r record.Record) (keep, restarted bool) { return d.observe(r) }

func (d *Dedup) observe(r record.Record) (keep, restarted bool) {
	if r.IsolateName == "" {
		r.IsolateName = d.names[r.IsolateID]
	}
	isMain := r.IsolateName == "" || r.IsolateName == "main"

	if d.pendingReset {
		restarted = true
		d.pendingReset = false
	}

	iso, known := d.isolates[r.IsolateID]
	switch {
	case !known:
		if isMain {
			if d.mainIsolateID != "" && d.mainIsolateID != r.IsolateID && d.hasEmitted {
				restarted = true
			}
			if d.mainIsolateID == "" || restarted {
				d.mainIsolateID = r.IsolateID
			}
		}
		if len(d.isolates) >= maxIsolates {
			d.pruneWorkerIsolates()
		}
		iso = &isolateSeen{seen: map[int64]time.Time{}}
		d.isolates[r.IsolateID] = iso
	default:
		at, seen := iso.seen[r.Seq]
		switch {
		case seen && at.Equal(r.Time):
			return false, false
		case seen, r.Seq < iso.last && r.Time.After(iso.lastTime):
			if isMain && d.hasEmitted {
				restarted = true
			}
			iso.reset()
		}
	}
	iso.add(r)
	d.hasEmitted = true
	return true, restarted
}

func (d *Dedup) pruneWorkerIsolates() {
	for id := range d.isolates {
		if id != d.mainIsolateID {
			delete(d.isolates, id)
			if len(d.isolates) < maxIsolates/2 {
				return
			}
		}
	}
}

func (s *isolateSeen) reset() {
	s.last, s.lastTime = 0, time.Time{}
	clear(s.seen)
}

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

// Snapshot fetches buffered history across every isolate serving
// [HistoryExtension], merges them chronologically while preserving per-isolate
// sequence order, and returns the deduplicated items without subscribing to the
// live stream.
func Snapshot(ctx context.Context, c *Client) ([]Item, error) {
	vm, err := c.InspectVM(ctx)
	if err != nil {
		return nil, err
	}
	d := NewDedup()
	d.ObserveVM(vm)

	type batch struct {
		id   string
		recs []record.Record
	}
	var wg sync.WaitGroup
	ch := make(chan batch, len(vm.Isolates))
	var order []string
	for _, iso := range vm.Isolates {
		if !iso.HasHistory {
			continue
		}
		order = append(order, iso.ID)
		wg.Add(1)
		go func(iso IsolateInfo) {
			defer wg.Done()
			fctx, cancel := context.WithTimeout(ctx, historyTimeout)
			defer cancel()
			recs, _ := c.History(fctx, iso.ID, iso.Name)
			ch <- batch{id: iso.ID, recs: recs}
		}(iso)
	}
	wg.Wait()
	close(ch)

	byIso := map[string][]record.Record{}
	for b := range ch {
		byIso[b.id] = b.recs
	}
	merged := mergeIsolateSlices(order, byIso)
	out := make([]Item, 0, len(merged))
	for _, r := range merged {
		if keep, restarted := d.History(r); keep {
			out = append(out, Item{Rec: r, Restarted: restarted})
		}
	}
	return out, nil
}

type histResult struct {
	isoID   string
	initial bool
	recs    []record.Record
}

// Stream subscribes c to the stratalog stream and emits its records until
// ctx ends or the connection drops, returning why it stopped.
//
// Initial history across isolates is merged chronologically ahead of live
// records. If a new isolate appears later on the live stream, only that
// isolate's live records are held while its history is queried — already-synced
// isolates keep streaming without interruption.
func Stream(ctx context.Context, c *Client, d *Dedup, emit func(Item)) error {
	if err := c.Listen(ctx); err != nil {
		return err
	}
	vm, err := c.InspectVM(ctx)
	if err != nil {
		return err
	}
	d.ObserveVM(vm)

	isoNames := map[string]string{}
	for _, iso := range vm.Isolates {
		if iso.Name != "" {
			isoNames[iso.ID] = iso.Name
		}
	}

	results := make(chan histResult)
	stop := make(chan struct{})
	defer close(stop)

	fetched := map[string]bool{}
	pendingIso := map[string]bool{}
	inflight := 0
	initInflight := 0
	var initOrder []string

	fetch := func(isoID, isoName string, initial bool) {
		fetched[isoID] = true
		pendingIso[isoID] = true
		inflight++
		if initial {
			initInflight++
			initOrder = append(initOrder, isoID)
		}
		go func() {
			fctx, cancel := context.WithTimeout(ctx, historyTimeout)
			defer cancel()
			recs, _ := c.History(fctx, isoID, isoName)
			select {
			case results <- histResult{isoID: isoID, initial: initial, recs: recs}:
			case <-stop:
			}
		}()
	}

	for _, iso := range vm.Isolates {
		if iso.HasHistory {
			fetch(iso.ID, iso.Name, true)
		}
	}

	initHist := map[string][]record.Record{}
	heldByIso := map[string][]record.Record{}

	stamp := func(r record.Record) record.Record {
		if r.IsolateName == "" {
			r.IsolateName = isoNames[r.IsolateID]
		} else if isoNames[r.IsolateID] == "" {
			isoNames[r.IsolateID] = r.IsolateName
		}
		return r
	}

	emitRecord := func(r record.Record, isHist bool) {
		r = stamp(r)
		var keep, restarted bool
		if isHist {
			keep, restarted = d.History(r)
		} else {
			keep, restarted = d.Live(r)
		}
		if keep {
			emit(Item{Rec: r, Restarted: restarted})
		}
	}

	flushIsolate := func(isoID string, hist []record.Record) {
		before, after := splitHeld(heldByIso[isoID], hist)
		delete(heldByIso, isoID)
		for _, r := range before {
			emitRecord(r, false)
		}
		for _, r := range hist {
			emitRecord(r, true)
		}
		for _, r := range after {
			emitRecord(r, false)
		}
	}

	flushInitial := func() {
		// Combine each initial isolate's (before + hist + after) stream in
		// exact per-isolate sequence order, then k-way merge chronologically.
		streams := map[string][]record.Record{}
		order := append([]string(nil), initOrder...)
		for isoID, held := range heldByIso {
			if pendingIso[isoID] {
				continue // late isolate still fetching its own history
			}
			if _, inInit := initHist[isoID]; !inInit {
				order = append(order, isoID)
			}
			_ = held
		}
		for _, isoID := range order {
			hist := initHist[isoID]
			before, after := splitHeld(heldByIso[isoID], hist)
			delete(heldByIso, isoID)
			combined := make([]record.Record, 0, len(before)+len(hist)+len(after))
			combined = append(combined, before...)
			combined = append(combined, hist...)
			combined = append(combined, after...)
			streams[isoID] = combined
		}
		clear(initHist)
		for _, r := range mergeIsolateSlices(order, streams) {
			emitRecord(r, true)
		}
	}

	records := c.Records()
	for {
		if records == nil && inflight == 0 {
			if len(initHist) > 0 {
				flushInitial()
			}
			for isoID := range heldByIso {
				flushIsolate(isoID, nil)
			}
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
			r = stamp(r)
			if !fetched[r.IsolateID] {
				fetch(r.IsolateID, r.IsolateName, false)
			}
			if initInflight > 0 || pendingIso[r.IsolateID] {
				heldByIso[r.IsolateID] = append(heldByIso[r.IsolateID], r)
			} else {
				emitRecord(r, false)
			}
		case res := <-results:
			inflight--
			delete(pendingIso, res.isoID)
			if res.initial {
				initInflight--
				initHist[res.isoID] = res.recs
				if initInflight == 0 {
					flushInitial()
				}
			} else if initInflight > 0 {
				// Late isolate finished before initial batch; fold into initial flush.
				initOrder = append(initOrder, res.isoID)
				initHist[res.isoID] = res.recs
			} else {
				flushIsolate(res.isoID, res.recs)
			}
		}
	}
}

// splitHeld partitions held live records for one isolate around its history
// snapshot: records evicted from the ring before the snapshot (older Seq in
// the same generation, or strictly older Time) precede hist; the rest follow.
func splitHeld(held, hist []record.Record) (before, after []record.Record) {
	if len(held) == 0 {
		return nil, nil
	}
	if len(hist) == 0 {
		return nil, held
	}
	oldest := hist[0]
	for _, r := range held {
		sameGenEvicted := r.Seq < oldest.Seq && !r.Time.After(oldest.Time)
		if sameGenEvicted || r.Time.Before(oldest.Time) {
			before = append(before, r)
		} else {
			after = append(after, r)
		}
	}
	return before, after
}

// mergeIsolateSlices performs a chronological k-way merge across per-isolate
// slices, preserving every isolate's internal sequence order even when
// timestamps collide or step backwards.
func mergeIsolateSlices(order []string, byIso map[string][]record.Record) []record.Record {
	total := 0
	for _, id := range order {
		total += len(byIso[id])
	}
	if total == 0 {
		return nil
	}
	heads := make([]int, len(order))
	out := make([]record.Record, 0, total)
	for len(out) < total {
		best := -1
		var bestTime time.Time
		for i, id := range order {
			s := byIso[id]
			if heads[i] >= len(s) {
				continue
			}
			t := s[heads[i]].Time
			if best < 0 || t.Before(bestTime) {
				best = i
				bestTime = t
			}
		}
		out = append(out, byIso[order[best]][heads[best]])
		heads[best]++
	}
	return out
}
