#!/usr/bin/env python
"""WER 계산: wer.py <ref.tsv> <hyp.tsv>   (각 줄: <id>\t<text>, hyp는 <id>\t<secs>\t<text> 도 허용)"""
import sys, re, jiwer
def norm(s):
    s = s.lower()
    s = re.sub(r"[^a-z0-9' ]+", " ", s)
    s = re.sub(r"\b(\d+)\b", lambda m: m.group(1), s)
    return re.sub(r"\s+", " ", s).strip()
def load(p, hyp=False):
    d = {}
    for line in open(p, encoding="utf-8"):
        parts = line.rstrip("\n").split("\t")
        if len(parts) < 2: continue
        key = parts[0].split('error.')[-1].rsplit('.', 1)[0]
        d[key] = parts[-1]
    return d
ref, hyp = load(sys.argv[1]), load(sys.argv[2], True)
keys = [k for k in ref if k in hyp]
R = [norm(ref[k]) for k in keys]; H = [norm(hyp[k]) for k in keys]
m = jiwer.process_words(R, H)
print(f"files={len(keys)} WER={m.wer*100:.2f}% (sub={m.substitutions} del={m.deletions} ins={m.insertions} / ref_words={sum(len(r.split()) for r in R)})")
