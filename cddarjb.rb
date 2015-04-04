#!/usr/bin/env ruby

require 'logger'
require 'set'
require 'stringio'
require 'yaml'

require 'eldr'
require 'json'
require 'rack'

module CDDARJB
  VERSION = '0.5.1'

  @@config = Hash.new
  def self.config; @@config; end
  def self.config=(obj); @@config = obj; end
  def self.log(level, msg); @@config[:logger].send(level, msg) if @@config[:logger]; end

  def self.fire!
    logger = if @@config[:log_opts]
      log_path = File.expand_path(@@config[:log_opts][:path])
      log_file = File.open(log_path, 'a')
      log_file.sync = true
      Logger.new(log_file, *@@config[:log_opts][:rotate])
    else
      Logger.new(STDOUT)
    end
    logger.level = Logger::INFO
    logger.formatter = if @@config[:no_stamp]
      lambda {|s,d,p,m| "#{s.ljust(5)} | #{m}\n" }
    else
      lambda {|s,d,p,m| "#{Time.now.strftime('%Y-%m-%d %H:%M:%S.%3N')} | #{s.ljust(5)} | #{m}\n" }
    end
    @@config[:logger] = logger

    if @@config[:background]
      STDOUT.reopen(log_file)
      STDERR.reopen(log_file)
    end

    if @@config[:standalone]
      self.log :info, 'Starting Standalone...'
      app = Rack::Builder.new do
        map '/backend' do run BackendApp.new end
        map '/' do run FrontendApp.new end
      end.to_app
      Rack::Handler::Thin.run(app, @@config[:httpd_opts])
    else
      self.log :info, 'Starting Backend...'
      Rack::Handler::Thin.run(BackendApp.new, @@config[:httpd_opts])
    end
  end

  class Error < StandardError
    @@counter = 0
    @@mutex = Mutex.new

    def call(env)
      id = "##{@@mutex.synchronize { @@counter += 1 }}"
      klass = self.class.to_s.split('::').last
      msg = "#{id} #{klass}"
      msg += ": #{to_s}" unless to_s.empty?

      CDDARJB.log :error, msg

      env['my-status'] = id
      Response.new(msg, 500)
    end
  end

  class NoTypeError < Error; end
  class NoIDError < Error; end
  class BadRegexpError < Error; end

  class NotReadyError < Error; end
  class SecurityError < Error; end
  class UpdateError < Error; end

  class BlobStore
    ID_KEYS = [:id, :ident, :result, :name, :description]

    def initialize(path)
      @path = path
      @ready = true
      @logs = Array.new
      parse!
    end

    def ready?; @ready; end
    def types; @data.keys; end
    def id_keys; ID_KEYS.map(&:to_s).join(', '); end
    def logs; @logs.map(&:string); end

    def search(str)
      begin
        regexp = /#{str}/i
      rescue RegexpError => e
        raise BadRegexpError.new("Malformed regexp: #{e.to_s}.")
      end
      @strings.keys.select{|k| k.match(regexp) }\
      .map {|i| {id: i, types: @strings[i].to_a } }
    end

    def get(type, id)
      raise NoTypeError.new("Type #{type} not found.") unless @data.has_key? type
      @data[type][id] or raise NoIDError.new("Path #{type}/#{id} not found.")
    end

    def types_for(id)
      return nil unless @ready
      @strings[id]
    end

    def parse!(msg = nil)
      return false unless @ready

      @ready = false
      @data = Hash.new
      @strings = Hash.new

      Thread.new do
        CDDARJB.log :info, 'BlobStore update initiated'

        log_start
        log "Update info: #{msg}" if msg
        log "ID keys considered: #{id_keys}\n\n"

        count = 0
        Dir.glob(File.join(@path, '**', '*.json')).each do |path|
          begin
            fname = File.basename(path)
            data = File.open(path).read
            skipped_type = skipped_id = 0

            JSON.parse(data, symbolize_names: true).each do |obj|
              unless obj.has_key? :type
                skipped_type += 1
                next
              end

              key = ID_KEYS.map{|k| obj.has_key?(k) ? k : nil}.compact

              if key.empty?
                skipped_id += 1
                next
              end

              key = key.first
              type = obj[:type]
              id = obj[key]

              unless id.is_a? String
                skipped_id += 1
                next
              end

              @data[type] ||= Hash.new
              @data[type][id] ||= Array.new
              @data[type][id].push(obj)

              count += 1

              @strings[id] ||= Set.new
              @strings[id].add(type)
            end

            if skipped_type > 0 || skipped_id > 0
              log "#{fname} - Blobs without reasonable type, id: #{skipped_type}, #{skipped_id}"
            end
          rescue RuntimeError => e
            log "RuntimeError: #{e.to_s}"
          end
        end

        log "\nLoaded: #{count} blobs, #{@data.length} types, #{@strings.length} unique serach strings."
        log_finish

        CDDARJB.log :info, 'BlobStore update finished'
        @ready = true
      end
    end

    private

    def log_start
      @logs.pop if @logs.length == 3
      @logs.unshift(StringIO.new)
      log "Parse started at #{Time.now}"
    end

    def log_finish
      log "Parse finished at #{Time.now}"
    end

    def log(msg)
      @logs.first.puts msg
    end
  end

  class Cache < Hash
    def initialize(size)
      @size = size
      @hit = @miss = 0
      @mutex = Mutex.new
      @keys = Array.new
    end

    def stats; {size: @size, hit: @hit, miss: @miss}; end

    def clear!
      @mutex.synchronize do
        @hit = @miss = 0
        @keys.clear
        clear
      end
    end

    def [](key)
      @mutex.synchronize do
        unless has_key? key
          @miss += 1
          return nil
        end

        @hit += 1
        @keys.delete(key)
        @keys.unshift(key)
        super
      end
    end

    def []=(key, value)
      @mutex.synchronize do
        if @keys.length == @size
          last = @keys.pop
          delete(last)
        end

        @keys.unshift(key)
        super
      end
    end
  end

  class Logging
    def initialize(app, prefix)
      @app = app
      @prefix = prefix
    end

    def call(env)
      start = Time.now
      status, header, body = @app.call(env)
      log(env, status, header, start)
      [status, header, body]
    end

    private

    def log(env, status, header, start)
      msg = '%s | %s %s %s %s%s %s %s %s %0.4f' % [
        @prefix,
        env['my-status'] || 'OK',
        env['HTTP_X_FORWARDED_FOR'] || env["REMOTE_ADDR"] || "-",
        env['REQUEST_METHOD'],
        env['PATH_INFO'],
        env['QUERY_STRING'].empty? ? '' : '?'+env['QUERY_STRING'],
        env['HTTP_VERSION'],
        status.to_s[0..3],
        header['Content-Length'] || '-',
        Time.now - start]
      CDDARJB.log :info, msg
    end
  end

  class Response
    attr_accessor :status, :headers, :body

    def initialize(body, status = 200, header = {})
      @status = status
      @header = {'Content-Type' => 'application/json'}.merge(header)
      if status == 200
        @body = {success: true, data: body}.to_json
      else
        @status = 200
        @body = {success: false, error: body}.to_json
      end
    end

    def to_a
      [@status, @header, [@body]]
    end

    alias_method :to_ary, :to_a
  end

  class BackendApp < Eldr::App
    use Logging, 'B'
    use Rack::ContentLength

    def initialize
      @db = BlobStore.new(File.expand_path(CDDARJB.config[:path]))
      @cache = Cache.new(100)
      super
    end

    def use_cache(&blk)
      key = env['PATH_INFO']
      if cached = @cache[key]
        env['my-status'] = 'CH'
        return cached
      else
        @cache[key] = blk.call
      end
    end

    def auto_link(blob)
      keys = blob.scan(/"(\S+)",?$/).map(&:first).uniq
      reps = keys.map do |k|
        next nil unless types = @db.types_for(k)
        links = types.to_a.map {|t| "<a onclick=\"show('#{t}', '#{k}')\">#{t}</a>" }.join(', ')
        "<span class=\"types\">#{links}</span>"
      end

      keys.each_with_index do |k, i|
        next unless reps[i]
        blob.gsub!(/"#{k}"/, "\"#{k}\" #{reps[i]}")
      end

      blob
    end

    before do raise NotReadyError.new('Database update in progress.') unless @db.ready? end

    post '/update' do
      raise SecurityError.new('Sorry.') unless params['pass'] == CDDARJB.config[:password]
      raise UpdateError unless @db.parse!(params['msg'])
      @cache.clear!
      Response.new('Update started.')
    end

    get '/status' do Response.new({logs: @db.logs, version: VERSION, cache: @cache.stats}) end

    get '/types' do Response.new(@db.types) end

    get '/search/:query' do use_cache { Response.new(@db.search(params['query'])) } end

    get '/blobs/:type/:id' do
      use_cache do
        blobs = @db.get(params['type'], params['id'])
        blobs.map! {|b| auto_link(JSON.pretty_generate(b)) }
        Response.new(blobs)
      end
    end
  end

  class FrontendApp < Eldr::App
    use Logging, 'F'
    use Rack::ContentLength
    use Rack::Static, urls: ['/'], root: 'public', index: 'index.html'
  end
end

unless ARGV.length == 1
  STDERR.puts "Usage: #{$PROGRAM_NAME} config.yaml"
  exit(2)
end

STDOUT.sync = STDERR.sync = true

begin
  CDDARJB.config = File.open(ARGV.first) {|f| YAML.load(f.read) }
  if CDDARJB.config[:background]
    pid = fork { CDDARJB.fire! }
    if CDDARJB.config[:pid_file]
      pid_path = File.expand_path(CDDARJB.config[:pid_file])
      File.open(pid_path, 'w') {|f| f.puts pid }
    end
    Process.detach(pid)
  else
    CDDARJB.fire!
  end
rescue StandardError => e
  STDERR.puts "Startup error: #{e.to_s} at #{e.backtrace.first}."
  STDERR.puts 'Sorry.'
  exit(3)
end
