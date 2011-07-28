require 'socket'
require 'thread'

module FakeFtp
  class Server

    attr_accessor :port, :passive_port
    attr_reader :mode

    CMDS = %w[acct cwd cdup list nlst pass pasv port pwd quit stor retr type user]
    LNBK = "\r\n"

    def initialize(control_port = 21, data_port = nil, options = { :BindAddress => '127.0.0.1', :Use220First => false })

      self.port = control_port
      self.passive_port = data_port
      raise(Errno::EADDRINUSE, "#{port}") if is_running?
      raise(Errno::EADDRINUSE, "#{passive_port}") if passive_port && is_running?(passive_port)
      @connection = nil
      @options = options
      @files = []
      @mode = :active
      @thread = nil
      @client = nil
      @server = nil
      @started = false
      @active_connection = nil
    end

    def files
      @files.map(&:name)
    end

    def file(name)
      @files.detect { |file| file.name == name }
    end

    def add_file(filename, data)
      @files << FakeFtp::File.new(::File.basename(filename.to_s), data, @mode)
    end

    def start
      @started = true
      @server = ::TCPServer.new(@options[:BindAddress], port)
      @thread = Thread.new do
        while @started && !@server.nil? && !@server.closed?
          begin
            @client = @server.accept_nonblock
            if @options[:Use220First]
              respond_with('220 FakeFtp')
            else
              respond_with('200 Can has FTP?')
            end
            @connection = Thread.new(@client) do |socket|
              while @started && !socket.nil? && !socket.closed?
                respond_with parse(socket.gets)
              end
              socket.close unless socket.closed?
              socket = nil
            end
          rescue Errno::EAGAIN, Errno::EWOULDBLOCK, Errno::ECONNABORTED, Errno::EPROTO, Errno::EINTR
          end
        end
        @server.close
        @server = nil
      end

      if passive_port
        @data_server = ::TCPServer.new(@options[:BindAddress], passive_port)
      end
    end

    def stop
      @started = false
      @thread.join()
      @client.close if @client != nil and !@client.closed?
      @server.close if @server != nil and !@server.closed?
      @data_server.close if @data_server
    end

    def is_running?(tcp_port = nil)
      service = `lsof -w -n -i tcp:#{tcp_port || port}`
      !service.nil? && service != ''
    end

    private

    def respond_with(stuff)
      @client.print stuff << LNBK unless stuff.nil? or @client.nil? or @client.closed?
    end

    def parse(request)
      return if request.nil?
      puts request if @options[:debug]
      command = request[0, 4].downcase.strip
      contents = request.split
      message = contents[1..contents.length]
      case command
        when *CMDS
          __send__ "_#{command}", *message
        else
          '500 Unknown command'
      end
    end

    ## FTP commands
    #
    #  Methods are prefixed with an underscore to avoid conflicts with internal server
    #  methods. Methods map 1:1 to FTP command words.
    #
    def _acct(*args)
      '230 WHATEVER!'
    end

    def _cwd(*args)
      '250 OK!'
    end
    alias :_cdup :_cwd

    def _list(*args)
      respond_with('425 Ain\'t no data port!') && return if active? && @active_connection.nil?

      respond_with('150 Listing status ok, about to open data connection')
      data_client = active? ? @active_connection : @data_server.accept

      data_client.write(@files.map do |f|
        "-rw-r--r--\t1\towner\tgroup\t#{f.bytes}\t#{f.created.strftime('%b %d %H:%M')}\t#{f.name}"
      end.join("\n"))
      data_client.close
      @active_connection = nil

      '226 List information transferred'
    end

    def _nlst(*args)
      respond_with('425 Ain\'t no data port!') && return if active? && @active_connection.nil?

      respond_with('150 Listing status ok, about to open data connection')
      data_client = active? ? @active_connection : @data_server.accept

      data_client.write(files.join("\n"))
      data_client.close
      @active_connection = nil

      '226 List information transferred'
    end

    def _pass(*args)
      '230 logged in'
    end

    def _pasv(*args)
      if passive_port
        @mode = :passive
        p1 = (passive_port / 256).to_i
        p2 = passive_port % 256
        if @options.has_key? :ExternalAddress
          "227 Entering Passive Mode (#{@options[:ExternalAddress].gsub(".", ",")},#{p1},#{p2})"
        else
          "227 Entering Passive Mode (#{@options[:BindAddress].gsub(".", ",")},#{p1},#{p2})"
        end
      else
        '502 Aww hell no, use Active'
      end
    end

    def _port(remote = '')
      remote = remote.split(',')
      remote_port = remote[4].to_i * 256 + remote[5].to_i
      unless @active_connection.nil?
        @active_connection.close
        @active_connection = nil
      end
      @mode = :active
      addr = "#{remote[0]}.#{remote[1]}.#{remote[2]}.#{remote[3]}"
      @active_connection = ::TCPSocket.open(addr, remote_port)
      '200 Okay'
    end

    def _pwd(*args)
      "257 \"/pub\" is current directory"
    end

    def _quit(*args)
      respond_with '221 OMG bye!'
      @client.close if @client
      @client = nil
    end

    def _retr(filename = '')
      respond_with('501 No filename given') if filename.empty?

      file = file(::File.basename(filename.to_s))
      return respond_with('550 File not found') if file.nil?

      respond_with('425 Ain\'t no data port!') && return if active? && @active_connection.nil?

      respond_with('150 File status ok, about to open data connection')
      data_client = active? ? @active_connection : @data_server.accept

      data_client.write(file.data)

      data_client.close
      @active_connection = nil
      '226 File transferred'
    end

    def _stor(filename = '')
      respond_with('425 Ain\'t no data port!') && return if active? && @active_connection.nil?

      respond_with('125 Do it!')
      data_client = active? ? @active_connection : @data_server.accept

      data = data_client.recv(1024)
      file = FakeFtp::File.new(::File.basename(filename.to_s), data, @mode)
      @files << file

      data_client.close
      @active_connection = nil
      '226 Did it!'
    end

    def _type(type = 'A')
      case type.to_s
        when 'A'
          '200 Type set to A.'
        when 'I'
          '200 Type set to I.'
        else
          '504 We don\'t allow those'
      end
    end

    def _user(name = '')
      (name.to_s == 'anonymous') ? '230 logged in' : '331 send your password'
    end

    def active?
      @mode == :active
    end
  end
end
