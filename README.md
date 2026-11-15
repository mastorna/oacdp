# OACDP: Obsolete Air Cooled Documentation Project

1. About
1. Dependencies
1. Building
1. Viewing
1. Developing
1. License

## About:

The Obsolete Air Cooled Documentation Project is focused on providing access to
hard to find, out of print resources for air cooled automobile enthusiasts.  This 
repository is the source for building the site.  It uses Jekyll, a ruby
static site generator.  (It originally used webgen 0.5.10, which no longer
runs on current Ruby; see docs/decisions/0001-move-build-to-jekyll.md.)

## Dependencies


  + [Ruby](https://www.ruby-lang.org) 3.x (tested with 3.4) and [Bundler](https://bundler.io)
  + [Jekyll](https://jekyllrb.com) 4.x (installed by Bundler from the Gemfile)
  + [GNU tar w/ bzip2 support](http://www.gnu.org/software/tar/)
  + [the oacdp overlay](http://oacdp/mirroring.html)
  + [git](http://git-scm.com)

## Building

First fetch the oacdp source:

	git clone https://github.com/elliottjohnson/oacdp.git oacdp
	cd oacdp

Install Jekyll and its dependencies (once):

	bundle install

Then use Jekyll to render the site from src/ into out/:

	bundle exec jekyll build

Then extract the overlay to install the content (the scanned documents
are not kept in git):

	tar -xvvjpf /the/path/to/your/oacdp-overlay.tar.bz2

The overlay folders inside out/ (5054part/, pdfs/, zips/, ...) are listed
under `keep_files` in _config.yml, so rebuilding does not delete them.

## Viewing

Use a web browser to open the "oacdp/out/index.html" file.  I've used only 
relative url's within the site to keep things locally viewable.

Or run a local preview server, which rebuilds when files in src/ change:

	bundle exec jekyll serve --host 0.0.0.0 --port 4000

and browse to http://localhost:4000/index.html.  In a GitHub Codespace,
open the PORTS tab and click the globe icon next to port 4000.

## Deploying

If you wish to deploy from source you can execute the publish.sh
script found in the scripts/ directory in the root of your checkout.
Make sure you supply a writeable, webviewable directory on your
local machine.

	scripts/publish.sh /path/to/a/writable/webdir/oacdp      

## Developing

I highly recommend setting up a github account, but it's not a requirement. 
[Email](http://oacdp.org/contact.html) if you are interested in commiting.

## License

The work being done is under the GNUv3.0 license.  See the file LICENSE in
the base of this repository for more information.

