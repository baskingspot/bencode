# bencode: Bencode in Zig: an incremental reader, a value tree, and a writer. `just --list` shows the recipes.
# AGENTS.md holds the working conventions.

[private]
default:
    @just --list

[doc("Unit tests: the module and the guide's examples, one line per test binary via testingx")]
[group("test")]
test:
    zig build test --summary all

[doc("Lint Zig, Nix, Markdown, the workflows, and this justfile: ziglint, the shared ast-grep rules, zig fmt, nix fmt, oxfmt, actionlint, zizmor, and just --fmt")]
[group("lint")]
lint:
    ziglint
    baskingspot-lint src
    zig fmt --check src docs/examples build.zig build.zig.zon
    nix fmt -- --ci
    oxfmt --check README.md AGENTS.md CHANGELOG.md docs/content docs/config.toml .github .oxfmtrc.jsonc
    actionlint
    zizmor .
    just --fmt --check

[doc("Format everything lint checks")]
[group("lint")]
fmt:
    zig fmt src docs/examples build.zig build.zig.zon
    nix fmt
    oxfmt README.md AGENTS.md CHANGELOG.md docs/content docs/config.toml .github .oxfmtrc.jsonc
    just --fmt

[doc("Everything CI runs: the tests, lint, and the site build")]
[group("ci")]
ci: test lint doc

[doc("Build the site into zig-out/site/bencode/: the guide (Zola, from docs/) and the API reference (docgen JSON, rendered by the theme's api.html) under api/. The router in baskingspot/site serves /bencode/... from it")]
[group("docs")]
doc: api
    baskingspot-docs build bencode

[doc("Edit the guide with live reload (http://127.0.0.1:1111), API reference included")]
[group("docs")]
guide: api
    baskingspot-docs serve bencode

# The API reference data. docgen comes from the baskingspot flake's docs shell,
# so this is not a Zig build dependency.
[private]
api:
    docgen --root src/root.zig --title bencode --repo-url https://github.com/baskingspot/bencode --rev main --format json --out docs/data

[doc("Deploy the rendered docs to Cloudflare as an assets-only Worker (config in wrangler.jsonc). Needs CLOUDFLARE_API_TOKEN in the environment, plus CLOUDFLARE_ACCOUNT_ID if the token can see more than one account")]
[group("docs")]
doc-deploy: doc
    wrangler deploy
