require 'socket'
require 'fileutils'

module TestQueue
  class Worker
    attr_accessor :pid, :status, :output, :stats, :num, :host
    attr_accessor :start_time, :end_time

    def initialize(pid, num)
      @pid = pid
      @num = num
      @start_time = Time.now
      @output = ''
      @stats = {}
    end

    def lines
      @output.split("\n")
    end
  end

  class Runner
    attr_accessor :concurrency

    def initialize(queue, concurrency=nil, socket=nil, relay=nil)
      raise ArgumentError, 'array required' unless Array === queue

      @procline = $0
      @queue = queue

      @workers = {}
      @completed = []

      @concurrency =
        concurrency ||
        (ENV['TEST_QUEUE_WORKERS'] && ENV['TEST_QUEUE_WORKERS'].to_i) ||
        if File.exists?('/proc/cpuinfo')
          File.read('/proc/cpuinfo').split("\n").grep(/processor/).size
        elsif RUBY_PLATFORM =~ /darwin/
          `/usr/sbin/sysctl -n hw.activecpu`.to_i
        else
          2
        end

      @socket =
        socket ||
        ENV['TEST_QUEUE_SOCKET'] ||
        "/tmp/test_queue_#{$$}_#{object_id}.sock"

      @relay =
        relay ||
        ENV['TEST_QUEUE_RELAY']

      if @relay == @socket
        STDERR.puts "*** Detected TEST_QUEUE_RELAY == TEST_QUEUE_SOCKET. Disabling relay mode."
        @relay = nil
      elsif @relay
        # We now use the queue to lookup tests
        # @queue = [] 
      end
    end

    def stats
      @stats ||=
        if File.exists?(file = stats_file)
          Marshal.load(IO.binread(file)) || {}
        else
          {}
        end
    end

    def execute
      $stdout.sync = $stderr.sync = true
      @start_time = Time.now

      @concurrency > 0 ?
        execute_parallel :
        execute_sequential
    ensure
      summarize_internal
    end

    def summarize_internal
      puts
      puts "==> Summary (#{@completed.size} workers in %.4fs)" % (Time.now-@start_time)
      puts

      @failures = ''
      @completed.each do |worker|
        summary, failures = summarize_worker(worker)
        @failures << failures if failures

        puts "    [%2d] %60s      %4d suites in %.4fs      (pid %d exit %d%s)" % [
          worker.num,
          summary,
          worker.stats.size,
          worker.end_time - worker.start_time,
          worker.pid,
          worker.status.exitstatus,
          worker.host && " on #{worker.host.split('.').first}"
        ]
      end

      unless @failures.empty?
        puts
        puts "==> Failures"
        puts
        puts @failures
      end

      puts

      if @stats
        File.open(stats_file, 'wb') do |f|
          f.write Marshal.dump(stats)
        end
      end

      summarize
      exit! @completed.inject(0){ |s, worker| s + worker.status.exitstatus }
    end

    def summarize
    end

    def stats_file
      ENV['TEST_QUEUE_STATS'] ||
      '.test_queue_stats'
    end

    def execute_sequential
      exit! run_worker(@queue)
    end

    def execute_parallel
      start_master
      spawn_workers
      distribute_queue
    ensure
      stop_master

      @workers.each do |pid, worker|
        Process.kill 'KILL', pid
      end

      until @workers.empty?
        cleanup_worker
      end
    end

    def start_master
      if relay?
        begin
          sock = connect_to_relay
          sock.puts("SLAVE #{@concurrency}")
          sock.close
        rescue Errno::ECONNREFUSED
          STDERR.puts "*** Unable to connect to relay #{@relay}. Aborting.."
          exit! 1
        end
      else
        if @socket =~ /^(?:(.+):)?(\d+)$/
          address = $1 || '0.0.0.0'
          port = $2.to_i
          @socket = "#$1:#$2"
          @server = TCPServer.new(address, port)
        else
          FileUtils.rm(@socket) if File.exists?(@socket)
          @server = UNIXServer.new(@socket)
        end
      end

      desc = "test-queue master (#{relay?? "relaying to #{@relay}" : @socket})"
      puts "Starting #{desc}"
      $0 = "#{desc} - #{@procline}"
    end

    def stop_master
      return if relay?

      FileUtils.rm_f(@socket) if @socket && @server.is_a?(UNIXServer)
      @server.close rescue nil if @server
      @socket = @server = nil
    end

    def spawn_workers
      @concurrency.times do |i|
        num = i+1

        pid = fork do
          @server.close if @server

          iterator = Iterator.new((relay? ? @relay : @socket), @queue.dup)
          after_fork_internal(num, iterator)
          exit! run_worker(iterator) || 0
        end

        @workers[pid] = Worker.new(pid, num)
      end
    end

    def after_fork_internal(num, iterator)
      srand

      output = File.open("/tmp/test_queue_worker_#{$$}_output", 'w')

      $stdout.reopen(output)
      $stderr.reopen($stdout)
      $stdout.sync = $stderr.sync = true

      $0 = "test-queue worker [#{num}]"
      puts
      puts "==> Starting #$0 (#{Process.pid}) - iterating over #{iterator.sock}"
      puts

      after_fork(num)
    end

    def after_fork(num)
    end

    def run_worker(iterator)
      iterator.each do |item|
        puts "  #{item.inspect}"
      end

      return 0 # exit status
    end

    def summarize_worker(worker)
      num_tests = ''
      failures = ''

      [ num_tests, failures ]
    end

    def cleanup_worker(blocking=true)
      if pid = Process.waitpid(-1, blocking ? 0 : Process::WNOHANG) and worker = @workers.delete(pid)
        begin
          worker.status = $?
          worker.end_time = Time.now

          if File.exists?(file = "/tmp/test_queue_worker_#{pid}_output")
            worker.output = IO.binread(file)
            FileUtils.rm(file)
          end

          if File.exists?(file = "/tmp/test_queue_worker_#{pid}_stats")
            worker.stats = Marshal.load(IO.binread(file))
            FileUtils.rm(file)
          end
        ensure
          relay_to_master(worker) if relay?
          worker_completed(worker)
        end        
      end
    end

    def worker_completed(worker)
      @completed << worker
      puts worker.output if ENV['TEST_QUEUE_VERBOSE']
    end

    def distribute_queue
      return if relay?
      remote_workers = 0

      until @queue.empty? && remote_workers == 0
        if IO.select([@server], nil, nil, 0.1).nil?
          cleanup_worker(false) # check for worker deaths
        else
          sock = @server.accept
          cmd = sock.gets.strip
          case cmd
          when 'POP'
            item = @queue.shift
            data = Marshal.dump(item.to_s)
            sock.write(data)
          when /^SLAVE (\d+)/
            num = $1.to_i
            remote_workers += num
            STDERR.puts "*** slave connected with additional #{num} workers"
          when /^WORKER (\d+)/
            data = sock.read($1.to_i)
            worker = Marshal.load(data)
            worker_completed(worker)
            remote_workers -= 1
          end
          sock.close
        end
      end
    ensure
      stop_master

      until @workers.empty?
        cleanup_worker
      end
    end

    def relay?
      !!@relay
    end

    def connect_to_relay
      TCPSocket.new(*@relay.split(':'))
    end

    def relay_to_master(worker)
      worker.host = Socket.gethostname
      data = Marshal.dump(worker)

      sock = connect_to_relay
      sock.puts("WORKER #{data.bytesize}")
      sock.write(data)
    ensure
      sock.close if sock
    end
  end
end
