# App Store kit (Kakureneko for iPhone)

Not used: the iPhone app ships only as a TestFlight beta (docs/APP-STORE.md). Kept for reference.

| | |
|---|---|
| `screenshots/` | The six App Store screenshots, 1320 × 2868 (6.9" display), opaque PNG, upload order = file order |
| `app-icon-1024.png` | The App Store icon (a copy of the asset catalog's; Xcode uploads it with the build) |
| `index.html` | The listing preview and every field ready to copy: `python3 -m http.server 4322 --directory marketing/app-store`, then http://localhost:4322/ |
| `source/screens.html` | The screenshot template (`?n=1` … `?n=6`) |
| `render.sh` | Renders `screenshots/` from the template with headless Chrome |

The texts and the reasoning behind them are in `docs/APP-STORE.md`.
