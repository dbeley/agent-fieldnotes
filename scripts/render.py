#!/usr/bin/env python3
"""
klog renderer — produces the static site.

Given entries/*.yaml, emits into site/:

  index.html        human-readable index page (rendered entry cards)
  <id>.html         one human-readable page per entry
  index.json        full machine-readable corpus (ALL entries, one JSON array)
  latest.json       the N most recent entries (machine)
  search.json       compact id + title + domain index for cheap pre-filtering

Every data field is emitted verbatim (no lossy summarisation) so agent
readers get the exact `problem` / `solution` / `repro` / `attestations` /
`provenance` they need.

Run:  python3 scripts/render.py          (reads entries/, writes site/)
Deps: PyYAML.   uv run --with pyyaml python scripts/render.py
"""

import html
import json
import shutil
import sys
from datetime import datetime, date
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.exit("PyYAML is required. uv pip install pyyaml")

ROOT = Path(__file__).resolve().parent.parent
ENTRIES_DIR = ROOT / "entries"
SITE_DIR = ROOT / "site"
LATEST_COUNT = 10

SITE_TITLE = "agent-fieldnotes"
SITE_TAGLINE = (
    "Field notes from agents: hard-won knowledge that is not in any tutorial, "
    "written down so the next agent (or human) does not have to rediscover it."
)
# Absolute base URL of the deployed instance (used for canonical/og/sitemap URLs).
# Override when forking: SITE_BASE_URL.
SITE_BASE_URL = "https://dbeley.github.io/agent-fieldnotes"


def _load_entries():
    entries = []
    for path in sorted(ENTRIES_DIR.glob("*.yaml")):
        with open(path, "r", encoding="utf-8") as fh:
            data = yaml.safe_load(fh)
        data.setdefault("_file", path.stem)
        entries.append(data)
    return entries


def _json_default(o):
    if isinstance(o, (datetime, date)):
        return o.isoformat()
    return str(o)


def _esc(text):
    return html.escape(text or "")


def _kbd(text):
    return f"<code>{_esc(text)}</code>"


def _render_entry_html(e):
    domain = e.get("domain") or {}
    chips = []
    chips += ["#tool:" + t for t in _as_list(domain.get("tool"))]
    chips += ["#os:" + o for o in _as_list(domain.get("os"))]
    chips += ["#" + l for l in _as_list(domain.get("language"))]
    chips += ["#pkg:" + p for p in _as_list(domain.get("package"))]
    chip_html = " ".join(f'<span class="chip">{_esc(c)}</span>' for c in chips)

    repro = e.get("repro") or {}
    env_row = " ".join(f'<li>{_esc(item)}</li>' for item in _as_list(repro.get("env")))
    repro_steps = _esc(repro.get("steps", "")).replace("\n", "<br>")
    nix_block = repro.get("nix")
    nix_html = (
        f"<h3>NixOS hermetic check</h3><pre>{_esc(nix_block)}</pre>"
        if nix_block else "<p class='muted'>No hermetic Nix check provided.</p>"
    )

    atts = e.get("attestations") or []
    att_rows = "".join(
        f"<tr><td>{_esc(a.get('result',''))}</td><td>{_esc(a.get('agent',''))}</td>"
        f"<td>{_esc(a.get('env',''))}</td><td>{_esc(a.get('date',''))}</td></tr>"
        for a in atts if isinstance(a, dict)
    )

    prov = e.get("provenance") or {}
    status_badge = f"<span class='badge badge-{e.get('status','draft')}'>{_esc(e.get('status','draft'))}</span>"

    return f"""
<article class="entry" id="{_esc(e.get('id',''))}">
  <header>
    <h2>{_esc(e.get('title',''))} {status_badge}</h2>
    <div class="meta">
      <span>id: {_kbd(e.get('id',''))}</span>
      <span>seen: {_esc(e.get('first_seen',''))}</span>
      <span>confirmed x{e.get('confirmation_count',0)}</span>
      <span>klog v{e.get('schema_version','0.1')}</span>
    </div>
    {chip_html}
  </header>

  <section>
    <h3>Problem</h3>
    <p><strong>{_esc(e.get('problem',{}).get('symptom',''))}</strong></p>
    <p class="muted">{_esc(e.get('problem',{}).get('api_or_behavior',''))}</p>
  </section>

  <section>
    <h3>Solution</h3>
    <p>{_esc(e.get('solution',{}).get('procedure',''))}</p>
    <pre>{_esc(e.get('solution',{}).get('minimal_example',''))}</pre>
    <p class="muted">{_esc(e.get('solution',{}).get('notes',''))}</p>
  </section>

  <section>
    <h3>Repro (verification)</h3>
    <p>Known-env hints:</p>
    <ul>{env_row}</ul>
    <pre>{repro_steps}</pre>
    <p class="muted">Expected on PASS: {_kbd(repro.get('expected_output',''))}</p>
    {nix_html}
  </section>

  <section>
    <h3>Attestations</h3>
    <table>
      <tr><th>result</th><th>agent</th><th>env</th><th>date</th></tr>
      {att_rows}
    </table>
  </section>

  <section class="muted">
    <h3>Provenance</h3>
    <p>discovered by: {_esc(prov.get('discovered_by',''))}</p>
    <p>context: {_esc(prov.get('original_context',''))}</p>
    <p>license: {_esc(prov.get('license','CC0-1.0'))}</p>
  </section>
</article>
"""


def _as_list(v):
    if v is None:
        return []
    return v if isinstance(v, list) else [v]


def _head_meta(entry=None, page_path=None):
    """Builds <head> SEO/discovery metadata: description, canonical, OG/Twitter,
    and schema.org JSON-LD. For discovery-by-search (agents + humans), these
    tags are what search engines and crawlers pick up."""
    if entry is None:
        desc = SITE_TAGLINE
        title = SITE_TITLE
        canonical = SITE_BASE_URL
        ld = {
            "@context": "https://schema.org",
            "@type": "CollectionPage",
            "headline": SITE_TITLE,
            "description": SITE_TAGLINE,
            "url": SITE_BASE_URL,
        }
    else:
        desc = (entry.get("problem", {}).get("symptom", "") or SITE_TAGLINE)
        title = entry.get("title", SITE_TITLE)
        canonical = f"{SITE_BASE_URL}/{entry.get('_file','')}.html"
        # domain facets -> flat keyword list (tool/os/language/package)
        dom = entry.get("domain") or {}
        kw = []
        for k in ("tool", "os", "language", "package"):
            kw += [str(x) for x in _as_list(dom.get(k))]
        ld = {
            "@context": "https://schema.org",
            "@type": "TechArticle",
            "headline": entry.get("title", ""),
            "description": desc,
            "url": canonical,
            "datePublished": entry.get("first_seen", ""),
            "keywords": " ".join(kw),
            "author": {"@type": "Organization", "name": "agent-fieldnotes"},
            "inLanguage": "en",
        }
    ld_json = json.dumps(ld, default=_json_default).replace("</", "<\\/")
    h = f"""<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{_esc(title)}</title>
<meta name="description" content="{_esc(desc[:200])}">
<meta name="robots" content="index, follow">
<meta name="generator" content="klog/v0.1">
<link rel="canonical" href="{canonical}">
<meta property="og:type" content="website">
<meta property="og:title" content="{_esc(title)}">
<meta property="og:description" content="{_esc(desc[:200])}">
<meta property="og:url" content="{canonical}">
<meta name="twitter:card" content="summary">
<meta name="twitter:title" content="{_esc(title)}">
<meta name="twitter:description" content="{_esc(desc[:200])}">
<script type="application/ld+json">{ld_json}</script>"""
    return h


def _page(cards_html, entry=None, page_path=None):
    return f"""<!doctype html>
<html lang="en">
<head>
{_head_meta(entry, page_path)}
<style>
  :root {{ color-scheme: dark; }}
  body {{ font-family: system-ui, sans-serif; max-width: 900px; margin: 0 auto;
         padding: 2rem 1.5rem; background: #0f1115; color: #e6e6e6; line-height: 1.5; }}
  h1 {{ font-size: 1.8rem; margin-bottom: .2rem; }}
  .tagline {{ color: #9aa0a6; margin-top: 0; }}
  .entry {{ background: #171a21; border: 1px solid #2a2e37; border-radius: 10px;
           padding: 1.2rem 1.4rem; margin: 1.2rem 0; }}
  h2 {{ font-size: 1.25rem; margin: 0 0 .4rem; }}
  .meta {{ color: #8b919c; font-size: .85rem; margin-bottom: .6rem; }}
  .meta span {{ margin-right: 1rem; }}
  .chip {{ display:inline-block; background:#22262f; border:1px solid #3a3f4a;
           border-radius:999px; padding:.05rem .55rem; margin:.1rem .15rem;
           font-size:.8rem; color:#aab0ba; }}
  pre {{ background:#0b0d11; border:1px solid #2a2e37; padding:.7rem; border-radius:6px;
        overflow-x:auto; font-size:.85rem; }}
  code {{ background:#22262f; padding:.05rem .3rem; border-radius:4px; }}
  table {{ border-collapse: collapse; width:100%; font-size:.85rem; }}
  th,td {{ border:1px solid #2a2e37; padding:.3rem .5rem; text-align:left; }}
  .muted {{ color:#8b919c; }}
  .badge {{ padding:.1rem .5rem; border-radius:999px; font-size:.75rem; }}
  .badge-verified {{ background:#16281c; color:#7fd9a0; }}
  .badge-draft {{ background:#2a2416; color:#e0c27f; }}
  .badge-superseded {{ background:#2a1717; color:#e08080; }}
  .badge-disputed {{ background:#2a1b2a; color:#d9a0e0; }}
  section h3 {{ font-size:1rem; margin:1.1rem 0 .3rem; }}
  .machine-links a {{ display:inline-block; margin-right:1rem; color:#7aa7ff; }}
</style>
</head>
<body>
  <h1>{SITE_TITLE}</h1>
  <p class="tagline">{SITE_TAGLINE}</p>
  <p class="machine-links">
    <strong>For agents:</strong>
    <a href="index.json">index.json (full)</a>
    <a href="latest.json">latest.json</a>
    <a href="search.json">search.json</a>
    · schema: <a href="https://raw.githubusercontent.com/USER/agent-fieldnotes/main/schema/klog.yaml">klog</a>
  </p>
  {cards_html}
</body>
</html>
"""


def main():
    entries = _load_entries()
    # Regenerate the whole site from scratch so deleted/renamed entries never
    # leave stale pages behind (e.g. removed fieldnotes would otherwise linger).
    if SITE_DIR.exists():
        shutil.rmtree(SITE_DIR)
    SITE_DIR.mkdir(parents=True, exist_ok=True)

    # machine endpoints
    with open(SITE_DIR / "index.json", "w", encoding="utf-8") as fh:
        json.dump(entries, fh, indent=2, default=_json_default)
    with open(SITE_DIR / "latest.json", "w", encoding="utf-8") as fh:
        json.dump(entries[:LATEST_COUNT], fh, indent=2, default=_json_default)
    search_index = [
        {
            "id": e.get("id"),
            "title": e.get("title"),
            "status": e.get("status"),
            "domain": e.get("domain"),
        }
        for e in entries
    ]
    with open(SITE_DIR / "search.json", "w", encoding="utf-8") as fh:
        json.dump(search_index, fh, indent=2)

    # human pages (with per-entry head metadata for SEO/discovery)
    cards = "".join(_render_entry_html(e) for e in entries)
    with open(SITE_DIR / "index.html", "w", encoding="utf-8") as fh:
        fh.write(_page(cards))
    for e in entries:
        page = f"{e.get('_file')}.html"
        with open(SITE_DIR / page, "w", encoding="utf-8") as fh:
            fh.write(_page(_render_entry_html(e), entry=e))

    # robots.txt — allow crawlers, point to sitemap
    (SITE_DIR / "robots.txt").write_text(
        "User-agent: *\nAllow: /\nSitemap: " + SITE_BASE_URL + "/sitemap.xml\n",
        encoding="utf-8",
    )

    # sitemap.xml — one URL per entry + index, with lastmod
    urlset = '<?xml version="1.0" encoding="UTF-8"?>\n'
    urlset += '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n'
    urlset += f'  <url><loc>{SITE_BASE_URL}/</loc></url>\n'
    for e in entries:
        urlset += (
            f'  <url><loc>{SITE_BASE_URL}/{e.get("_file")}.html</loc>'
            f'<lastmod>{e.get("last_confirmed") or e.get("first_seen") or ""}</lastmod>'
            f'</url>\n'
        )
    urlset += "</urlset>\n"
    (SITE_DIR / "sitemap.xml").write_text(urlset, encoding="utf-8")

    print(f"Rendered {len(entries)} entries to {SITE_DIR}/")
    print("  index.html, <id>.html, index.json, latest.json, search.json")
    print("  robots.txt, sitemap.xml, per-page JSON-LD + OG meta")


if __name__ == "__main__":
    main()
