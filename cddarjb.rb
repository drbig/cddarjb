#!/usr/bin/env ruby

require 'logger'
require 'set'
require 'stringio'
require 'yaml'

require 'eldr'
require 'json'
require 'rack'

# We will get weird errors
Thread.abort_on_exception = true

module CDDARJB
  VERSION = '0.7.4'

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

  class NotFoundError < Error; end
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
      @data = Hash.new
      @strings = Hash.new
      @other = Hash.new
      parse!
    end

    def ready?; @ready; end
    def types; @data.keys; end
    def id_keys; ID_KEYS.map(&:to_s).join(', '); end
    def other_keys; CDDARJB.config[:other_keys]; end
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
      raise NotFoundError.new("Type #{type} not found.") unless @data.has_key? type
      @data[type][id] or raise NotFoundError.new("Path #{type}/#{id} not found.")
    end

    def types_for(id)
      @strings[id]
    end

    def other_for(id)
      @other[id]
    end

    def parse!(msg = nil)
      return false unless @ready

      @ready = false
      @data.clear
      @strings.clear
      @other.clear

      Thread.new do
        CDDARJB.log :info, 'BlobStore update initiated'

        log_start
        log "Update info: #{msg}" if msg
        log "ID keys considered: #{id_keys}\n"
        log "Other keys considered: #{other_keys.join(', ')}\n\n" if other_keys

        count = 0
        files  = Dir.glob(File.join(@path, %w{json ** *.json}))
        files += Dir.glob(File.join(@path, %w{mods ** *.json}))
        files.delete_if {|e| File.basename(e) == 'modinfo.json' }
        files.each do |path|
          begin
            fname = File.basename(path)
            data = File.read(path)
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
              @data[type][id].push({blob: obj, source: rel_path(path)})

              count += 1

              @strings[id] ||= Set.new
              @strings[id].add(type)

              other_keys.each do |k|
                k = k.to_sym
                if obj.has_key? k
                  [obj[k]].flatten.each do |e|
                    t = k.to_s
                    @other[e] ||= Hash.new
                    @other[e][t] ||= Hash.new
                    @other[e][t][id] ||= Set.new
                    @other[e][t][id].add(type)
                  end
                end
              end
            end

            if skipped_type > 0 || skipped_id > 0
              log "#{fname} - Blobs without reasonable type, id: #{skipped_type}, #{skipped_id}"
            end
          rescue StandardError => e
            log "#{fname} - Error: #{e.to_s}"
          end
        end

        log "\nLoaded: #{count} blobs, #{@data.length} types, #{@other.length} other keys, #{@strings.length} unique serach strings."
        log_finish

        CDDARJB.log :info, 'BlobStore update finished'
        @ready = true
      end

      true
    end

    private

    def rel_path(path)
      path.slice(@path.length, path.length) || '???'
    end

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
      @header = {'Content-Type' => 'application/json',
                 'Access-Control-Allow-Origin' => '*'}.merge(header)
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
      super
    end

    def auto_link(blob)
      keys = blob.scan(/"(\S+)",?$/).map(&:first).uniq
      reps = keys.map do |k|
        out = String.new
        if types = @db.types_for(k)
          links = types.to_a.map{|t| "<a onclick=\"show('#{t}', '#{k}')\">#{t}</a>" }.join(', ')
          out += "<span class=\"types\">#{links}</span>"
        end
        if other = @db.other_for(k)
          links = other.keys.map{|e| "<a onclick=\"list('#{e}', '#{k}')\">#{e}</a>" }.join(', ')
          out += "<span class=\"other\">#{links}</span>"
        end
        out.empty? ? nil : out
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
      Response.new('Update started.')
    end

    get '/status' do Response.new({logs: @db.logs, version: VERSION}) end

    get '/types' do Response.new(@db.types) end

    get '/search/:query' do Response.new(@db.search(params['query'])) end

    get '/list/:type/:id' do
      types = @db.other_for(params['id'])
      raise NotFoundError.new("Other #{params['id']} not found.") unless types
      data = types[params['type']].each_pair.map{|id, ts| {id: id, types: ts.to_a} }
      Response.new(data)
    end

    get '/blobs/:type/:id' do
      blobs = @db.get(params['type'], params['id']).map do |b|
        {blob: auto_link(JSON.pretty_generate(b[:blob])), source: b[:source]}
      end
      Response.new(blobs)
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
  msg = "Runtime error: #{e.to_s} at #{e.backtrace.first}."
  STDERR.puts msg
  STDERR.puts 'Sorry.'
  CDDARJB.log :fatal, msg
  exit(3)
end
