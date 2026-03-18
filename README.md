# Finch

A fast, private front-end for X (Twitter). Fork of [Nitter](https://github.com/zedeus/nitter) with additional features: Following, Lists, local collections, article rendering, and a completely revamped UI.

## Features

- **Privacy-first** — no JavaScript required from X, no tracking
- **Following & Lists** — manage your own Following and Lists via recovery key
- **Local collections** — save and organize posts locally
- **Article rendering** — read X articles without leaving Finch
- **Export** — JSON, Markdown, TXT, and RSS feeds
- **Revamped UI** — OKLCH color system, improved accessibility, responsive design
- **Accessibility** — keyboard navigation, focus indicators, screen reader support, reduced-motion
- **Performance** — lazy HLS loading, infinite scroll with pagination, optimized assets

## UI Improvements (Latest)

Our recent UI overhaul includes:

- **Design System** — OKLCH color tokens, 4pt spacing grid, ease-out-quart transitions
- **Typography** — System font stack, 16px minimum, proper line heights
- **Accessibility** — Skip-to-content link, focus-visible rings, ARIA labels, 44px touch targets
- **UX Writing** — Simplified copy following impeccable.style guidelines
- **Simplified Controls** — Export options collapsed into `<details>`, cleaner search filters
- **Better Empty States** — Concise messaging throughout
- **Interactions** — Roving tabindex on tabs, lazy HLS (saves 412KB), double-submit prevention

## Requirements

- [Nim](https://nim-lang.org/) >= 2.0.0
- [Redis](https://redis.io/) (for caching)
- libsass (for SCSS compilation via Nim)
- An X session cookie (see [Session Setup](#session-setup))

## Quick Start

```bash
# Install Nim (if not installed)
curl https://nim-lang.org/choosenim/init.sh -sSf | bash
source ~/.profile  # or restart terminal

# Clone
git clone https://github.com/KEYURBODAR/finch.git
cd finch

# Install dependencies
nimble install -y

# Build assets
nimble scss
nimble md

# Configure
cp nitter.example.conf nitter.conf
# Edit nitter.conf — set hostname, port, Redis connection, etc.

# Build
nimble build -d:release

# Run Redis (in another terminal)
redis-server

# Start Finch
./nitter
```

Open `http://localhost:8080` (or whatever port you configured).

## Session Setup

Finch requires X session cookies to fetch data. Use the session tools:

```bash
# Install Python dependencies
pip install -r tools/requirements.txt

# Browser-based (recommended)
python3 tools/create_session_browser.py

# Or via curl
python3 tools/create_session_curl.py
```

Sessions are stored in Redis. See `nitter.example.conf` for configuration.

## Docker

```bash
# Build
docker build -t finch .

# Run
docker run -d \
  -p 8080:8080 \
  -v $(pwd)/nitter.conf:/src/nitter.conf:ro \
  --name finch \
  finch
```

Or use docker-compose:

```bash
docker-compose up -d
```

Edit `docker-compose.yml` and `nitter.conf` before running.

## Development

```bash
# Rebuild CSS after SCSS changes
nimble scss

# Rebuild about page after markdown changes
nimble md

# Run tests (requires Python + pytest)
pip install -r tests/requirements.txt
nimble test

# Build in debug mode
nimble build
```

### Project Structure

```
src/
├── nitter.nim          # Main entry point
├── routes/             # HTTP route handlers
│   ├── timeline.nim    # Profile timelines
│   ├── status.nim      # Individual posts
│   ├── search.nim      # Search functionality
│   ├── local.nim       # Following/Lists/Collections
│   └── ...
├── views/              # Nim/Karax HTML templates
│   ├── general.nim     # Layout, navbar, head
│   ├── tweet.nim       # Tweet rendering
│   ├── profile.nim     # Profile pages
│   ├── actions.nim     # Export controls
│   └── ...
├── sass/               # SCSS source files
│   ├── index.scss      # Main entry point
│   ├── include/        # Variables, mixins
│   ├── tweet/          # Tweet-specific styles
│   └── ...
├── experimental/       # Experimental GraphQL parsers
├── types.nim           # Core data structures
├── parser.nim          # HTML parsing
├── api.nim             # X API client
└── *.nim               # Other core modules
public/
├── css/
│   ├── style.css       # Compiled CSS (generated)
│   └── fontello.css    # Icon fonts
├── js/
│   ├── interactions.js # Focus management, reduced-motion
│   ├── localActions.js # Checkbox selection, export UX
│   ├── infiniteScroll.js
│   ├── hlsPlayback.js  # Lazy HLS loading
│   └── ...
├── fonts/              # Fontello icon fonts
└── ...                 # Static assets
tools/                  # Build & session utilities
tests/                  # Python integration tests
```

## Configuration

Copy `nitter.example.conf` to `nitter.conf` and edit:

| Setting | Description | Default |
|---------|-------------|---------|
| `address` | Listen address | `0.0.0.0` |
| `port` | Listen port | `8080` |
| `title` | Instance name | `Finch` |
| `hostname` | Public hostname | `localhost` |
| `staticDir` | Static assets dir | `./public` |
| `redisHost` | Redis host | `localhost` |
| `redisPort` | Redis port | `6379` |
| `redisPassword` | Redis password | (empty) |
| `hmacKey` | HMAC signing key | (random) |

See `nitter.example.conf` for all options including rate limits, caching, and media proxying.

## Architecture

Finch is built on:

- **Nim** — Compiled systems language, fast and memory-efficient
- **Jester** — Web framework with async HTTP
- **Karax** — VDOM library for server-side HTML generation
- **Redis** — Caching layer for tweets, profiles, and media
- **SCSS** — CSS with variables, mixins, and modular partials

Data flow:
1. User requests a profile/timeline/post
2. Jester route handler receives request
3. Check Redis cache
4. If miss, fetch from X API using session cookies
5. Parse HTML response (X doesn't offer a public API)
6. Store in Redis with TTL
7. Render Nim/Karax view template
8. Return HTML to user

## Contributing

This is a personal fork with opinionated UI changes. If you find bugs or have suggestions, open an issue.

For the upstream Nitter project, see [zedeus/nitter](https://github.com/zedeus/nitter).

## License

AGPL-3.0 — see [LICENSE](LICENSE).

Original Nitter by [@zedeus](https://github.com/zedeus). Finch fork and UI improvements by [@KEYURBODAR](https://github.com/KEYURBODAR).
