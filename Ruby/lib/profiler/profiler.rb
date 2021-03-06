require 'json'
require 'timeout'
require 'thread'
require 'ruby-debug'

module Rack

	class MiniProfiler

		VERSION = 'rZlycOOTnzxZvxTmFuOEV0dSmu4P5m5bLrCtwJHVXPA='.freeze
		@@instance = nil

		def self.instance
			@@instance
		end

		def self.generate_id
			rand(36**20).to_s(36)
		end

		# Structs holding Page loading data
		# PageStruct
		#   ClientTimings: ClientTimerStruct
		#   Root: RequestTimer
		#     :has_many RequestTimer children
		#     :has_many SqlTimer children
		class ClientTimerStruct
			def initialize(env)
				@attributes = {}
			end

			def to_json(*a)
				::JSON.generate(@attributes, *a)
			end

			def init_from_form_data(env, page_struct)
				timings = []
				clientTimes, clientPerf, baseTime = nil 
				form = env['rack.request.form_hash']

				clientPerf = form['clientPerformance'] if form 
				clientTimes = clientPerf['timing'] if clientPerf 

				baseTime = clientTimes['navigationStart'].to_i if clientTimes
				return unless clientTimes && baseTime 

				clientTimes.keys.find_all{|k| k =~ /Start$/ }.each do |k|
					start = clientTimes[k].to_i - baseTime 
					finish = clientTimes[k.sub(/Start$/, "End")].to_i - baseTime
					duration = 0 
					duration = finish - start if finish > start 
					name = k.sub(/Start$/, "").split(/(?=[A-Z])/).map{|s| s.capitalize}.join(' ')
					timings.push({"Name" => name, "Start" => start, "Duration" => duration}) if start >= 0
				end

				clientTimes.keys.find_all{|k| !(k =~ /(End|Start)$/)}.each do |k|
					timings.push("Name" => k, "Start" => clientTimes[k].to_i - baseTime, "Duration" => -1)
				end

				@attributes.merge!({
					"RedirectCount" => env['rack.request.form_hash']['clientPerformance']['navigation']['redirectCount'],
					"Timings" => timings
				})
			end
		end

		class SqlTimerStruct
			def initialize(query, duration_ms, page)
				@attributes = {
					"ExecuteType" => 3, # TODO
					"FormattedCommandString" => query,
					"StackTraceSnippet" => Kernel.caller.join("\n"), # TODO
					"StartMilliseconds" => (Time.now.to_f * 1000).to_i - page['Started'],
					"DurationMilliseconds" => duration_ms,
					"FirstFetchDurationMilliseconds" => 0,
					"Parameters" => nil,
					"ParentTimingId" => nil,
					"IsDuplicate" => false
				}
			end

			def to_json(*a)
				::JSON.generate(@attributes, *a)
			end

			def []=(name, val)
				@attributes[name] = val
			end

			def [](name)
				@attributes[name]
			end
		end

		class RequestTimerStruct
			def self.createRoot(name, page)
				rt = RequestTimerStruct.new(name, page)
				rt["IsRoot"]= true
				rt
			end

			def initialize(name, page)
				@attributes = {
					"Id" => MiniProfiler.generate_id,
					"Name" => name,
					"DurationMilliseconds" => 0,
					"DurationWithoutChildrenMilliseconds"=> 0,
					"StartMilliseconds" => (Time.now.to_f * 1000).to_i - page['Started'],
					"ParentTimingId" => nil,
					"Children" => [],
					"HasChildren"=> false,
					"KeyValues" => nil,
					"HasSqlTimings"=> false,
					"HasDuplicateSqlTimings"=> false,
					"SqlTimings" => [],
					"SqlTimingsDurationMilliseconds"=> 0,
					"IsTrivial"=> false,
					"IsRoot"=> false,
					"Depth"=> 0,
					"ExecutedReaders"=> 0,
					"ExecutedScalars"=> 0,
					"ExecutedNonQueries"=> 0				
				}
				@children_duration = 0
			end
			
			def [](name)
				@attributes[name]
			end

			def []=(name, value)
				@attributes[name] = value
				self
			end

			def to_json(*a)
				::JSON.generate(@attributes, *a)
			end

			def add_child(request_timer)
				@attributes['Children'].push(request_timer)
				@attributes['HasChildren'] = true
				request_timer['ParentTimingId'] = @attributes['Id']
				request_timer['Depth'] = @attributes['Depth'] + 1
				@children_duration += request_timer['DurationMilliseconds']
			end

			def add_sql(query, elapsed_ms, page)
				timer = SqlTimerStruct.new(query, elapsed_ms, page)
				timer['ParentTimingId'] = @attributes['Id']
				@attributes['SqlTimings'].push(timer)
				@attributes['HasSqlTimings'] = true
				@attributes['SqlTimingsDurationMilliseconds'] += elapsed_ms
			end

			def record_time(milliseconds)
				@attributes['DurationMilliseconds'] = milliseconds
				@attributes['DurationWithoutChildrenMilliseconds'] = milliseconds - @children_duration
 			end			
		end

		# MiniProfiles page, part of 
		class PageStruct
			def initialize(env)
				@attributes = {
					"Id" => MiniProfiler.generate_id,
					"Name" => env['PATH_INFO'],
					"Started" => (Time.now.to_f * 1000).to_i,
					"MachineName" => env['SERVER_NAME'],
					"Level" => 0,
					"User" => "unknown user",
					"HasUserViewed" => false,
					"ClientTimings" => ClientTimerStruct.new(env),
					"DurationMilliseconds" => 0,
					"HasTrivialTimings" => true,
					"HasAllTrivialTimigs" => false,
					"TrivialDurationThresholdMilliseconds" => 2,
					"Head" => nil,
					"DurationMillisecondsInSql" => 0,
					"HasSqlTimings" => true,
					"HasDuplicateSqlTimings" => false,
					"ExecutedReaders" => 0,
					"ExecutedScalars" => 0,
					"ExecutedNonQueries" => 0
				}
				name = "#{env['REQUEST_METHOD']} http://#{env['SERVER_NAME']}:#{env['SERVER_PORT']}#{env['SCRIPT_NAME']}#{env['PATH_INFO']}"
				@attributes['Root'] = RequestTimerStruct.createRoot(name, self)
			end

			def [](name)
				@attributes[name]
			end

			def []=(name, val)
				@attributes[name] = val
			end

			def to_json(*a)
				attribs = @attributes.merge( {
					"Started" => '/Date(%d)/' % @attributes['Started'], 
          "DurationMilliseconds" => @attributes['Root']['DurationMilliseconds']
					})
				
				::JSON.generate(attribs, *a)
			end
		end

		# inserts additional text at the end of the body
		class BodyAddProxy
			def initialize(body, additional_text)
				@body = body
				@additional_text = additional_text
			end

			def respond_to?(*args)
				super or @body.respond_to?(*args)
			end

			def method_missing(*args, &block)
				@body.__send__(*args, &block)
			end

			def each(&block)
				@body.each(&block)
				yield @additional_text
				self
			end
		end

		#
		# options:
		# :auto_inject - should script be automatically injected on every html page (not xhr)
		# :

		def initialize(app, options={})
			@@instance = self
			@options = {
				:auto_inject => true,	# automatically inject on every html page
				:base_url_path => "/mini-profiler-resources",
				:authorize_cb => lambda {|env| return true;} # callback returns true if this request is authorized to profile
			}.merge(options)
			@app = app
			@options[:base_url_path] += "/" unless @options[:base_url_path].end_with? "/"
			@timer_struct_cache = {}
			@timer_struct_lock = Mutex.new
		end

		def serve_results(env)
			request = Rack::Request.new(env)
			page_struct = get_from_timer_cache(request['id'])
			return [404, {}, ["No such result #{request['id']}"]] unless page_struct
			unless page_struct['HasUserViewed']
				page_struct['ClientTimings'].init_from_form_data(env, page_struct)
				page_struct["HasUserViewed"] = true
			end
			[200, { 'Content-Type' => 'application/json'}, [page_struct.to_json]]
		end

		def serve_html(env)
			file_name = env['PATH_INFO'][(@options[:base_url_path].length)..1000]
			return serve_results(env) if file_name.eql?('results')
			full_path = ::File.expand_path("../html/#{file_name}", ::File.dirname(__FILE__))
			return [404, {}, ["Not found"]] unless ::File.exists? full_path
			f = Rack::File.new nil
			f.path = full_path
			f.cache_control = "max-age:86400"
			f.serving env
		end

		def add_to_timer_cache(page_struct)
			@timer_struct_lock.synchronize {
				@timer_struct_cache[page_struct['Id']] = page_struct
			}
		end

		def get_from_timer_cache(id)
			@timer_struct_lock.synchronize {
				@timer_struct_cache[id]
			}
		end

		EXPIRE_TIMER_CACHE = 3600 * 24 # expire cache in seconds

		def cleanup_cache
			puts "Cleaning up cache"
			expire_older_than = ((Time.now.to_f - MiniProfiler::EXPIRE_TIMER_CACHE) * 1000).to_i
			@timer_struct_lock.synchronize {
				@timer_struct_cache.delete_if { |k, v| v['Root']['StartMilliseconds'] < expire_older_than }
			}
		end

		# clean up the cache every hour
		Thread.new do
			while true do
				MiniProfiler.instance.cleanup_cache if MiniProfiler.instance
				sleep(3600)
			end
		end

    def self.current
      Thread.current['profiler.mini.private']
    end

    def self.current=(c)
      # we use TLS cause we need access to this from sql blocks and code blocks that have no access to env
 			Thread.current['profiler.mini.private'] = c
    end
   
    def current
      MiniProfiler.current
    end

    def current=(c)
      MiniProfiler.current=c
    end

		def call(env)
			status = headers = body = nil

			# only profile if authorized
			return @app.call(env) unless @options[:authorize_cb].call(env)

			# handle all /mini-profiler requests here
			return serve_html(env) if env['PATH_INFO'].start_with? @options[:base_url_path]

			# profiling the request
			self.current = {}
			current['inject_js'] = @options[:auto_inject] && (!env['HTTP_X_REQUESTED_WITH'].eql? 'XMLHttpRequest')
			current['page_struct'] = PageStruct.new(env)
			current['current_timer'] = current['page_struct']['Root']

      start = Time.now 
			status, headers, body = @app.call(env)
			current['page_struct']['Root'].record_time((Time.now - start) * 1000)

			# inject headers, script
			if status == 200
				add_to_timer_cache(current['page_struct'])
				# inject header
				headers['X-MiniProfilerID'] = current['page_struct']["Id"] if headers.is_a? Hash
				# inject script
				if current['inject_js'] \
					&& headers.has_key?('Content-Type') \
					&& !headers['Content-Type'].match(/text\/html/).nil? then
					body = MiniProfiler::BodyAddProxy.new(body, self.get_profile_script(env))
				end
			end
			current = nil
			[status, headers, body]
		end

		# get_profile_script returns script to be injected inside current html page
		# By default, profile_script is appended to the end of all html requests automatically.
		# Calling get_profile_script cancels automatic append for the current page
		# Use it when:
		# * you have disabled auto append behaviour throught :auto_inject => false flag
		# * you do not want script to be automatically appended for the current page. You can also call cancel_auto_inject
		def get_profile_script(env)
			ids = "[\"%s\"]" % current['page_struct']['Id'].to_s
			path = @options[:base_url_path]
			version = MiniProfiler::VERSION
			position = 'left'
			showTrivial = false
			showChildren = false
			maxTracesToShow = 10
			showControls = false
			currentId = current['page_struct']["Id"]
			authorized = true
			# TODO : cache this snippet 
			script = IO.read(::File.expand_path('../html/profile_handler.js', ::File.dirname(__FILE__)))
			# replace the variables
			[:ids, :path, :version, :position, :showTrivial, :showChildren, :maxTracesToShow, :showControls, :currentId, :authorized].each do |v|
				regex = Regexp.new("\\{#{v.to_s}\\}")
				script.gsub!(regex, eval(v.to_s).to_s)
			end
			# replace the '{{' and '}}''
			script.gsub!(/\{\{/, '{').gsub!(/\}\}/, '}')
			current['inject_js'] = false
			script
		end

		# cancels automatic injection of profile script for the current page
		def cancel_auto_inject(env)
		  current['inject_js'] = false
		end

		# perform a profiling step on given block
		def self.step(name)
      if current
        old_timer = current['current_timer']
        new_step = RequestTimerStruct.new(name, current['page_struct'])
        current['current_timer'] = new_step
        new_step['Name'] = name
        start = Time.now
        yield if block_given?
        new_step.record_time((Time.now - start)*1000)
        old_timer.add_child(new_step)
        current['current_timer'] = old_timer
      else
        yield if block_given?
      end
		end

    def self.profile_method(klass, method)
      default_name = klass.to_s + " " + method.to_s
      with_profiling = (method.to_s + "_with_mini_profiler").intern
      without_profiling = (method.to_s + "_without_mini_profiler").intern
      
      klass.send :alias_method, without_profiling, method
      klass.send :define_method, with_profiling do |*args, &orig|
        name = default_name 
        name = yield *args if block_given?
        ::Rack::MiniProfiler.step name do 
          self.send without_profiling, *args, &orig
        end
      end
      klass.send :alias_method, method, with_profiling
    end

		def record_sql(query, elapsed_ms)
			current['current_timer'].add_sql(query, elapsed_ms, current['page_struct']) if (current && current['current_timer'])
		end

	end

end

