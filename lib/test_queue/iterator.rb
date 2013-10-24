module TestQueue
  class Iterator
    attr_reader :stats, :sock

    def initialize(sock, queue)
      @done = false
      @stats = {}
      @procline = $0
      @sock = sock
      if @sock =~ /^(.+):(\d+)$/
        @tcp_address = $1
        @tcp_port = $2.to_i
      end
      @queue = queue
    end

    def each
      fail 'already used this iterator' if @done

      while true
        client = connect_to_master('POP')
        r, w, e = IO.select([client], nil, [client], nil)
        break if !e.empty?

        if data = client.read(65536)
          client.close
          item = @queue.find {|name| Marshal.load(data) == name.to_s }
          break if item.nil?

          $0 = "#{@procline} - #{item.respond_to?(:description) ? item.description : item}"
          start = Time.now
          yield item          
          @stats[item.to_s] = Time.now - start
        else
          break
        end
      end
    rescue Errno::ENOENT, Errno::ECONNRESET, Errno::ECONNREFUSED
    ensure
      @done = true
      File.open("/tmp/test_queue_worker_#{$$}_stats", "wb") do |f|
        f.write Marshal.dump(@stats)
      end
    end

    def connect_to_master(cmd)
      sock =
        if @tcp_address
          TCPSocket.new(@tcp_address, @tcp_port)
        else
          UNIXSocket.new(@sock)
        end
      sock.puts(cmd)
      sock
    end

    include Enumerable

    def empty?
      false
    end
  end
end
