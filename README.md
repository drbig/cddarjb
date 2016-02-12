# CDDA RJB

The [Cataclysm: Dark Days Ahead](http://en.cataclysmdda.com/) Raw JSON Browser.

Contrary to the [other](http://cdda-trunk.estilofusion.com/) item browser:

 - It has only two assumptions about the JSON files and therefore should be hard to break
 - It tries to load as much JSON as possible (e.g. mapgen data, mods...)
 - It presents raw JSON blobs with automatic cross-links where possible
 - It can be live-updated; easy to integrate with git hooks
 - Its code is short and simple
 - It has minimal dependencies, you can deploy it on pretty much anything; fully standalone
 - It has stable memory footprint (~240 MB VIRT on Linux, running for months)

Requirements:

 - Ruby 2.1.0 *minimum*
 - A dozen Gems at most

No memcached, SQL databases, dedicated web servers and so on...

### Basic deployment guide for non-Rubists

This is example procedure that was tested on Ubuntu 14.04.2 LTS. It's not the shortest way to get it running, but should be easiest and sanest in the long run. It assumes you have installed at least `curl`, `git` and `build-essential` packages. It also assumes you have a copy of CDDA's JSON files handy.

```bash
$ gpg --keyserver hkp://keys.gnupg.net --recv-keys 409B6B1796C275462A1703113804BB82D39DC0E3
$ curl -sSL https://get.rvm.io | bash -s stable --ruby
$ git clone https://github.com/drbig/cddarjb.git
$ cd cddarjb
$ rvm gemset create cddarjb
$ rvm gemset use cddarjb
$ bundle install
$ cp all.yaml your-config.yaml
$ $EDITOR your-config.yaml
$ # adjust "var backend = '...';" to point to the proper URL for your deployment
$ $EDITOR public/index.html
$ ./cddarjb.rb your-config.yaml
```

What we did above:

 1. Installed [RVM](https://rvm.io/), modern [Ruby](https://www.ruby-lang.org/en/), [RubyGems](https://rubygems.org/) and [Bundler](http://bundler.io/) in one go
 2. Installed CDDARJB and all its dependencies
 3. Created and edited our config
 4. Started the App

### Updating the blob store

The included `update-blobstore.rb` script is the simplest way to update your copy of CDDA's repo and trigger the blob store update (if needed, and including version information). Feel free to add it to your `crontab`.

App-wise the update is initiated via a POST request to `/update` with valid password in `pass`. You can also add a free-form message in `msg` (intended to show the version information in the status log).

### JSON Assumptions

A worthwhile blob has to have:

 1. 'type' key
 2. Some 'id'-like key

## Contributing

Follow the usual GitHub workflow:

 1. Fork the repository
 2. Make a new branch for your changes
 3. Work (and remember to commit with decent messages)
 4. Push your feature branch to your origin
 5. Make a Pull Request on GitHub

## Licensing

Standard two-clause BSD license, see LICENSE.txt for details.

Copyright (c) 2015 - 2016 Piotr S. Staszewski
