# shrinkit docs

The site at https://noxend.github.io/shrinkit/, built with [Fumadocs](https://fumadocs.dev) as a
static export. The pages are in `content/docs/`, one file each, in the order `content/docs/meta.json`
gives. The videos are in `public/videos/`.

```bash
cd docs
npm ci
npm run dev    # http://localhost:3000/shrinkit/
npm run build  # the site in out/
```

`.github/workflows/docs.yml` builds it on every pull request that changes `docs/`, and publishes it
when a release is published, so the site describes the version Homebrew installs.
