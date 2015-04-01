#!/usr/bin/env ruby

require 'httparty'

def url
  url = 'http://'
  if @config.has_key? :httpd_opts
    url += @config[:httpd_opts][:Host] || 'localhost'
    url += @config[:httpd_opts][:Port] ? ':'+@config[:httpd_opts][:Port].to_s : ':8080'
  else
    url += 'localhost:8080'
  end
  url += '/backend' if @config[:standalone]
  url + '/update'
end

unless ARGV.length == 1
  STDERR.puts "Usage: #{$PROGRAM_NAME} config.yaml"
  exit(2)
end

begin
  @config = File.open(ARGV.first) {|f| YAML.load(f.read) }
  Dir.chdir(File.expand_path(@config[:path]))
  pull = `git pull #{@config[:git_pull]} 2>&1`
  unless pull.match(/Already up-to-date/)
    version = `git describe --tags --always --dirty`
    resp = HTTParty.post(url, body: {pass: @config[:password], msg: version})
    unless resp.code == 200
      STDERR.puts "Update hook returned: #{resp}"
      exit(4)
    end
  end
rescue StandardError => e
  STDERR.puts "Runtime error: #{e.to_s} at #{e.backtrace.first}."
  STDERR.puts 'Sorry.'
  exit(3)
end
