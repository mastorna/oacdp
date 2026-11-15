# 0001: Move the site build from webgen 0.5.10 to Jekyll

- Status: accepted
- Date: 2026-11-15

## Problem

The site is built with webgen 0.5.10 (released 2009). It no longer runs on
current Ruby:

- On Ruby 3.4, `webgen render` fails with
  "wrong number of arguments (given 1, expected 0)".
- On Ruby 3.3 it also hit the removal of `File.exists?`, a YAML parse error on
  `add: [**/robots.txt]` in `config.yaml`, and text-encoding errors.

So the site cannot currently be rebuilt from source.

The source is simple: 25 `src/*.page` files are plain HTML with a YAML front
matter block (`title:`). Only `src/default.template` is webgen-specific, and it
uses just four webgen tags: `{lang:}`, `{title:}`,
`{relocatable: style/oacdp.css}` and `<webgen:block name='content' />`.

## Options

- **A. Patch webgen 0.5.10** to run on Ruby 3.4. Several separate breakages,
  in unmaintained code, and more will appear with each Ruby release.
- **B. Upgrade to webgen 1.x.** Maintained, but a different configuration
  and template format, so it is a migration anyway, onto a tool with a small
  user base.
- **C. Move to Jekyll 4.x.** Widely used and maintained. Its page format
  (HTML + YAML front matter) already matches our pages, so only the layout
  template needs converting.

## Decision

Option C, as a faithful port: same page URLs, same content, same look. No
redesign, no new features, no dependency upgrades beyond what Jekyll needs.
The source stays in `src/` and output stays in `out/`.

## Consequences

- Build with `bundle install` then `bundle exec jekyll build`.
- `src/*.page` are renamed to `src/*.html` (contents unchanged);
  `src/default.template` becomes `src/_layouts/default.html`.
- `config.yaml`, `Rakefile`, `ext/` and the webgen notes in `scripts/` are
  no longer used by the build; whether to remove them is a separate decision.
  Update: `config.yaml`, `Rakefile`, `ext/` and the tracked `*~` editor
  backups were removed on the `live-sync` branch.
- The live site has content newer than this repo (e.g. `progref.html`,
  `progref61.html`, `type1.html`, a 2014 `type1part.html`). This port does not
  change that; it only replaces the build tool.

## Reversal

All work is on the `jekyll-port` branch. To reverse, discard the branch;
`master` is untouched.
