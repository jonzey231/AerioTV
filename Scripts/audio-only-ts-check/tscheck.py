#!/usr/bin/env python3
"""Audio-only TS segment checker (AAC ADTS focus).

Usage:
  tscheck.py seg_00000.ts seg_00001.ts ...      (files in playback order)
  tscheck.py --dir <AudioOnlyDump/<channel>/<ts>>  (all seg_*.ts sorted)
  tscheck.py --cut-adts <in.ts> <outdir> [secs]  (ADTS-aligned cut like TSHLSRemuxer)

Reports per segment: PAT/PMT (version, PCR PID, streams), PCR presence,
whether the first audio PES starts on an ADTS sync, PES lengths, ADTS
header fields, CC gaps, and PTS continuity: each PES PTS is compared with
the running sample count (frames * 1024 / sr) carried across segment joins.
"""
import sys, os, glob

TICKS = 90000

def packets(data):
    for i in range(0, len(data) - 187, 188):
        p = data[i:i+188]
        if p[0] != 0x47:
            yield None, i
        else:
            yield p, i

def payload_off(p):
    afc = (p[3] >> 4) & 3
    if not (afc & 1): return None
    off = 4
    if afc & 2: off += 1 + p[4]
    return off if off < 188 else None

def pcr_of(p):
    afc = (p[3] >> 4) & 3
    if (afc & 2) and p[4] >= 7 and (p[5] & 0x10):
        b = p[6:12]
        base = (b[0] << 25) | (b[1] << 17) | (b[2] << 9) | (b[3] << 1) | (b[4] >> 7)
        return base / TICKS
    return None

def parse_pts(b):
    return (((b[0] >> 1) & 7) << 30 | b[1] << 22 | (b[2] >> 1) << 15 | b[3] << 7 | b[4] >> 1)

def parse_psi(p):
    off = payload_off(p)
    if off is None: return None
    off += 1 + p[off]
    return p[off:]

def parse_pmt(sec):
    if not sec or sec[0] != 0x02: return None
    slen = ((sec[1] & 0x0F) << 8) | sec[2]
    ver = (sec[5] >> 1) & 0x1F
    pcr = ((sec[8] & 0x1F) << 8) | sec[9]
    pil = ((sec[10] & 0x0F) << 8) | sec[11]
    o = 12 + pil; end = 3 + slen - 4
    streams = []
    while o + 5 <= end:
        t = sec[o]; pid = ((sec[o+1] & 0x1F) << 8) | sec[o+2]
        il = ((sec[o+3] & 0x0F) << 8) | sec[o+4]
        streams.append((pid, t)); o += 5 + il
    return dict(version=ver, pcr_pid=pcr, streams=streams, raw=bytes(sec[:3+slen]).hex())

def adts_frames(es):
    out = []; i = 0
    while i + 7 <= len(es):
        if es[i] == 0xFF and (es[i+1] & 0xF6) == 0xF0:
            prot_absent = es[i+1] & 1
            profile = (es[i+2] >> 6) + 1
            sfi = (es[i+2] >> 2) & 0xF
            ch = ((es[i+2] & 1) << 2) | (es[i+3] >> 6)
            flen = ((es[i+3] & 3) << 11) | (es[i+4] << 3) | (es[i+5] >> 5)
            rdb = (es[i+6] & 3) + 1
            if flen < 7: break
            out.append(dict(off=i, profile=profile, sfi=sfi, ch=ch, flen=flen, blocks=rdb,
                            truncated=i + flen > len(es)))
            i += flen
        else:
            out.append(dict(off=i, junk=True)); break
    return out

SR = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

JITTER_MS = float(os.environ.get('JITTER_MS', '1.0'))

def analyze(files):
    state = dict(expect_pts=None, cc={}, sr=None, last_pmt=None, total_frames=0)
    issues = 0
    for seg_i, f in enumerate(files):
        data = open(f, 'rb').read()
        pmt_pid = None; pmts = []; pcrs = []; pes_list = []; cur = None
        sync_errs = 0; cc_gaps = []; audio_pid = None
        for p, off in packets(data):
            if p is None: sync_errs += 1; continue
            pid = ((p[1] & 0x1F) << 8) | p[2]; pusi = bool(p[1] & 0x40)
            pc = pcr_of(p)
            if pc is not None: pcrs.append((pid, pc))
            afc = (p[3] >> 4) & 3; cc = p[3] & 0xF
            if pid == 0 and pusi:
                sec = parse_psi(p)
                if sec and sec[0] == 0 and len(sec) >= 12:
                    pmt_pid = ((sec[10] & 0x1F) << 8) | sec[11]
                continue
            if pid == pmt_pid and pusi:
                m = parse_pmt(parse_psi(p))
                if m:
                    pmts.append(m)
                    for spid, t in m['streams']:
                        if t in (0x0F, 0x11, 0x81, 0x87, 0x03, 0x04) and audio_pid is None:
                            audio_pid = spid
                continue
            if pid != audio_pid or audio_pid is None: continue
            if afc & 1:
                prev = state['cc'].get(pid)
                if prev is not None and cc != (prev + 1) & 0xF and cc != prev:
                    cc_gaps.append((len(pes_list), prev, cc))
                state['cc'][pid] = cc
            po = payload_off(p)
            if po is None: continue
            if pusi:
                if cur: pes_list.append(cur)
                pl = p[po:]
                if pl[:3] != b'\x00\x00\x01':
                    cur = dict(bad=True, es=bytearray(), pts=None, declared=0); continue
                declared = (pl[4] << 8) | pl[5]
                hl = pl[8]; pts = None
                if pl[7] & 0x80: pts = parse_pts(pl[9:14]) / TICKS
                cur = dict(pts=pts, declared=declared, es=bytearray(pl[9+hl:]), hdrlen=9+hl,
                           first_in_seg=not pes_list)
            else:
                if cur is None:
                    cur = dict(orphan=True, es=bytearray(), pts=None, declared=0)
                cur['es'] += p[po:]
        if cur: pes_list.append(cur)

        print(f"== seg {seg_i} {os.path.basename(f)} bytes={len(data)} sync_errs={sync_errs}")
        if not pmts:
            print("   !! no PMT"); issues += 1
        else:
            m = pmts[0]
            print(f"   PMT v{m['version']} pcr_pid={m['pcr_pid']} streams={[(s, hex(t)) for s, t in m['streams']]} count={len(pmts)}")
            if state['last_pmt'] and state['last_pmt'] != m['raw']:
                print(f"   !! PMT bytes differ from the previous segment: {state['last_pmt']} -> {m['raw']}"); issues += 1
            state['last_pmt'] = m['raw']
            if m['pcr_pid'] not in [p for p, _ in pcrs]:
                print(f"   !! no PCR on the PMT's PCR PID {m['pcr_pid']} (PCRs seen: {sorted(set(p for p, _ in pcrs))})"); issues += 1
        if pcrs:
            print(f"   PCR n={len(pcrs)} first={pcrs[0][1]:.3f} last={pcrs[-1][1]:.3f}")
        for g in cc_gaps:
            print(f"   !! CC gap before PES #{g[0]}: {g[1]} -> {g[2]}"); issues += 1
        seg_frames = 0; first_pts = last_end = None
        for k, pes in enumerate(pes_list):
            if pes.get('orphan'):
                print(f"   !! PES #{k}: continuation without a PES start ({len(pes['es'])} B)"); issues += 1; continue
            if pes.get('bad'):
                print(f"   !! PES #{k}: PUSI without a PES start code"); issues += 1; continue
            if pes['declared']:
                got = pes['hdrlen'] - 6 + len(pes['es'])
                # TS stuffing can only trail via adaptation, payload size should match exactly
                if got < pes['declared']:
                    print(f"   !! PES #{k}: truncated, declared {pes['declared']} got {got}"); issues += 1
            fr = adts_frames(pes['es'])
            if k == 0 and (not fr or fr[0].get('junk') or fr[0]['off'] != 0):
                print(f"   !! first PES does not start on an ADTS sync"); issues += 1
            good = [x for x in fr if not x.get('junk')]
            for x in fr:
                if x.get('junk'):
                    print(f"   !! PES #{k}: non-ADTS bytes at offset {x['off']}"); issues += 1
                elif x['truncated']:
                    print(f"   !! PES #{k}: ADTS frame truncated (len {x['flen']})"); issues += 1
            if good:
                g0 = good[0]
                sr = SR[g0['sfi']] if g0['sfi'] < len(SR) else 0
                if state['sr'] is None:
                    state['sr'] = sr
                    print(f"   ADTS profile={g0['profile']} sr={sr} ch={g0['ch']} blocks={g0['blocks']} frames/PES={len(good)}")
                for x in good:
                    if (SR[x['sfi']], x['ch'], x['profile']) != (state['sr'], g0['ch'], g0['profile']):
                        print(f"   !! PES #{k}: ADTS header change {x}"); issues += 1
            nsamples = sum(x['blocks'] for x in good) * 1024
            pts = pes['pts']
            if pts is not None:
                if first_pts is None: first_pts = pts
                exp = state['expect_pts']
                if exp is not None:
                    d = pts - exp
                    state.setdefault('jit', []).append(d)
                    if abs(d) > JITTER_MS / 1000:
                        state.setdefault('jumps', []).append((pts, d))
                        where = "at the segment join" if k == 0 else f"PES #{k}"
                        print(f"   !! PTS drift {where}: pts={pts:.6f} expected {exp:.6f} (delta {d*1000:+.3f} ms = {d*state['sr']:+.1f} samples)"); issues += 1
                if state['sr']:
                    state['expect_pts'] = pts + nsamples / state['sr']
                    last_end = state['expect_pts']
            elif state['expect_pts'] is not None and state['sr']:
                state['expect_pts'] += nsamples / state['sr']
            seg_frames += len(good)
        state['total_frames'] += seg_frames
        if first_pts is not None:
            state.setdefault('first', first_pts); state['last_end'] = last_end
            print(f"   PES={len(pes_list)} frames={seg_frames} start_pts={first_pts:.6f} end_pts={last_end:.6f} dur={last_end-first_pts:.4f}")
    jit = state.get('jit', [])
    if jit:
        small = [abs(x) for x in jit if abs(x) <= JITTER_MS / 1000]
        print(f"PTS vs sample clock: {len(jit)} PES checked, {len(small)} within +-{JITTER_MS} ms (max {max(small)*1000 if small else 0:.3f} ms, source PTS rounding)")
        for t, d in state.get('jumps', []):
            print(f"   JUMP at pts {t:.3f}: {d*1000:+.3f} ms ({d*(state['sr'] or 1):+.1f} samples)")
        if 'first' in state and state['sr']:
            span = state['last_end'] - state['first']; samp = state['total_frames'] * 1024 / state['sr']
            print(f"   PTS span {span:.4f} s vs decoded samples {samp:.4f} s: PTS runs ahead by {(span-samp)*1000:+.2f} ms ({(span-samp)/samp*1e6:+.0f} ppm)")
    print(f"TOTAL segments={len(files)} frames={state['total_frames']} issues={issues}")
    return issues

def cut_adts(src, outdir, secs=2.0):
    """Cut like TSHLSRemuxer's audio-only arm: each segment = PAT+PMT then the
    audio PID's packets, cut on a PES start that begins on an ADTS sync once
    PTS - start >= secs. Whole PES only (held until the next PES start)."""
    data = open(src, 'rb').read()
    os.makedirs(outdir, exist_ok=True)
    pat = pmt = None; pmt_pid = audio = None
    seg = bytearray(); held = []; start = None; n = 0; segs = []
    def write(seg):
        nonlocal n
        path = os.path.join(outdir, f"seg_{n:05d}.ts"); open(path, 'wb').write(seg); segs.append(path); n += 1
    for p, _ in packets(data):
        if p is None: continue
        pid = ((p[1] & 0x1F) << 8) | p[2]; pusi = bool(p[1] & 0x40)
        if pid == 0:
            if pat is None:
                pat = p; sec = parse_psi(p); pmt_pid = ((sec[10] & 0x1F) << 8) | sec[11]
            continue
        if pid == pmt_pid:
            if pmt is None:
                pmt = p; m = parse_pmt(parse_psi(p)); audio = m['streams'][0][0]
            continue
        if pid != audio: continue
        if pusi:
            po = payload_off(p); pl = p[po:]
            pts = parse_pts(pl[9:14]) / TICKS if pl[7] & 0x80 else None
            es = pl[9+pl[8]:]
            onsync = len(es) >= 2 and es[0] == 0xFF and (es[1] & 0xF6) == 0xF0
            for h in held: seg += h
            held = [p]
            if pts is not None and onsync:
                if start is None or pts - start >= secs:
                    if start is not None: write(seg)
                    seg = bytearray(pat + pmt); start = pts
        elif held:
            held.append(p)
    for h in held: seg += h
    if start is not None and len(seg) > 376: write(seg)
    return segs

if __name__ == '__main__':
    a = sys.argv[1:]
    if not a: print(__doc__); sys.exit(2)
    if a[0] == '--cut-adts':
        segs = cut_adts(a[1], a[2], float(a[3]) if len(a) > 3 else 2.0)
        print(f"wrote {len(segs)} segments to {a[2]}"); sys.exit(0)
    if a[0] == '--dir':
        files = sorted(glob.glob(os.path.join(a[1], 'seg_*.ts')))
    else:
        files = a
    sys.exit(1 if analyze(files) else 0)
