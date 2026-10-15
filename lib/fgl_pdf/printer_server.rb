# frozen_string_literal: true

require 'socket'
require 'logger'
require_relative 'spool'

module FglPdf
  # A virtual Boca printer: accepts raw FGL on a TCP port (9100 by default, like a
  # JetDirect-style print server) and spools every printed ticket to +out_dir+ as a numbered
  # PDF (see Spool).
  #
  # Each connection gets its own Interpreter, so per-job state (font, rotation, position)
  # never leaks between clients, while downloaded logos (Spool#logo_dir) and the ticket
  # counter (Spool#counter) are shared and persisted, as on a real printer.
  #
  # Status queries (<S1>, <s1>, …): a real Boca answers with status bytes. This server
  # replies nothing unless +status_reply+ is given, in which case those bytes are written
  # back verbatim for every query. This is NOT a byte-accurate emulation of Boca status;
  # it only exists for hosts that block waiting for some answer.
  #
  # +interpreter_factory+ (callable taking on_status:) and +renderer+ (#render(ticket))
  # can be injected for testing.
  class PrinterServer
    READ_SIZE = 64 * 1024
    STOP_GRACE = 2 # seconds to let open connections finish on #stop

    attr_reader :spool, :host, :logger

    def initialize(config:, out_dir:, host: '0.0.0.0', port: 9100, logger: config.logger,
                   status_reply: nil, interpreter_factory: nil, renderer: nil)
      @config = config
      @host = host
      @requested_port = Integer(port)
      @logger = logger || Logger.new(nil)
      @status_reply = status_reply&.b
      @spool = Spool.new(out_dir)
      @interpreter_factory = interpreter_factory || method(:default_interpreter)
      @renderer = renderer
      @render_lock = Mutex.new
      @clients = {}
      @clients_lock = Mutex.new
      @connection_seq = 0
    end

    # Binds and starts accepting in a background thread; returns self.
    def start
      raise Error, 'server already started' if @server

      @server = TCPServer.new(host, @requested_port)
      @stopping = false
      logger.info("fgl-printer listening on #{host}:#{port}, spooling to #{spool.dir}")
      @accept_thread = Thread.new { accept_loop }
      self
    end

    # Starts (unless already started) and blocks until #stop.
    def run
      start unless @server
      @accept_thread.join
    end

    # The bound port (the actual one when 0 was requested).
    def port
      @server ? @server.local_address.ip_port : @requested_port
    end

    def running?
      !@server.nil? && !@stopping
    end

    # Stops accepting, gives open connections STOP_GRACE seconds to finish, then closes them.
    def stop
      return unless @server && !@stopping

      @stopping = true
      @server.close
      @accept_thread&.join
      threads = @clients_lock.synchronize { @clients.keys }
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + STOP_GRACE
      threads.each do |t|
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        next if remaining.positive? && t.join(remaining)

        @clients_lock.synchronize { @clients[t] }&.close
        t.join(1)
      end
      logger.info('fgl-printer stopped')
    end

    private

    def accept_loop
      until @stopping
        socket = @server.accept
        id = (@connection_seq += 1)
        # Register under the lock before #handle can run its ensure (which also locks).
        @clients_lock.synchronize { @clients[Thread.new { handle(socket, id) }] = socket }
      end
    rescue IOError, Errno::EBADF, Errno::EINVAL
      nil # listening socket closed by #stop
    end

    def handle(socket, id)
      peer = peer_name(socket)
      logger.info("connection #{id} from #{peer}")
      interpreter = @interpreter_factory.call(on_status: ->(cmd) { reply_status(socket, cmd, id) })
      received = 0
      consumed = 0
      loop do
        chunk = socket.readpartial(READ_SIZE)
        received += chunk.bytesize
        interpreter.feed(chunk).each do |ticket|
          consumed += ticket.raw.to_s.bytesize
          emit(ticket, peer, id)
        end
      end
    rescue IOError, SystemCallError # EOFError is an IOError
      finish(interpreter, id, received - consumed)
    rescue StandardError => e
      logger.error("connection #{id} from #{peer}: #{e.class}: #{e.message}; closing connection")
      logger.debug(e.full_message(highlight: false))
    ensure
      socket.close unless socket.closed?
      @clients_lock.synchronize { @clients.delete(Thread.current) }
    end

    def finish(interpreter, id, unconsumed)
      if interpreter&.pending?
        bytes = interpreter.respond_to?(:pending_bytesize) ? interpreter.pending_bytesize : [unconsumed, 0].max
        logger.warn("connection #{id}: discarding #{bytes} bytes without a print command")
      end
      logger.info("connection #{id} closed")
    end

    def emit(ticket, peer, id)
      pdf, error = render(ticket)
      seqs = spool.write(ticket, pdf, peer: peer, connection: id, error: error)
      label = seq_label(seqs)
      if error
        logger.error("ticket #{label} from #{peer}: render failed (#{error}); kept FGL only")
      else
        logger.info("ticket #{label} (#{ticket.warnings.size} warnings) from #{peer}")
      end
      ticket.warnings.each { |w| logger.debug("ticket #{label}: #{w}") }
    end

    def render(ticket)
      [@render_lock.synchronize { renderer.render(ticket) }, nil]
    rescue StandardError => e
      logger.debug(e.full_message(highlight: false))
      [nil, "#{e.class}: #{e.message}"]
    end

    def renderer
      @renderer ||= Renderer::Pdf.new(@config)
    end

    def default_interpreter(on_status:)
      Interpreter.new(config: @config, logo_store: logo_store, counter: spool.counter, on_status: on_status)
    end

    def logo_store
      @render_lock.synchronize { @logo_store ||= LogoStore.new(dir: spool.logo_dir) }
    end

    def reply_status(socket, cmd, id)
      logger.debug("connection #{id}: status query <#{cmd}>")
      socket.write(@status_reply) if @status_reply
    rescue IOError, SystemCallError
      nil
    end

    def seq_label(seqs)
      first, last = [seqs.first, seqs.last].map { |n| format("%0#{Spool::SEQ_DIGITS}d", n) }
      seqs.size == 1 ? first : "#{first}-#{last} (#{seqs.size} copies)"
    end

    def peer_name(socket)
      addr = socket.remote_address
      ip = addr.ip_address
      ip = "[#{ip}]" if ip.include?(':')
      "#{ip}:#{addr.ip_port}"
    rescue StandardError
      'unknown'
    end
  end
end
