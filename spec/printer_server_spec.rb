# frozen_string_literal: true

require 'json'
require 'socket'
require 'stringio'
require 'fgl_pdf/printer_server'

module ServerFakes
  # Splits the stream on "<p>"; "<S1>" triggers a status query.
  class FakeInterpreter
    def initialize(on_status:)
      @on_status = on_status
      @buffer = +''.b
    end

    def feed(bytes)
      @buffer << bytes.b
      @on_status&.call('S1') if @buffer.sub!('<S1>', '')
      tickets = []
      while (i = @buffer.index('<p>'))
        raw = @buffer.slice!(0, i + 3)
        copies = raw[/<copies(\d)>/, 1].to_i
        tickets << FglPdf::Ticket.new(width_dots: 600, length_dots: 1650, raw: raw,
                                      copies: copies.positive? ? copies : 1,
                                      warnings: raw.include?('WARN') ? ['a warning'] : [])
      end
      tickets
    end

    def pending? = !@buffer.empty?
    def pending_bytesize = @buffer.bytesize
  end

  # Renders "%PDF-fake <raw>", or raises when the ticket contains BOOM.
  class FakeRenderer
    def render(ticket)
      raise ArgumentError, 'cannot draw' if ticket.raw.include?('BOOM')

      "%PDF-fake #{ticket.raw}"
    end
  end
end

RSpec.describe FglPdf::PrinterServer do
  around do |example|
    Dir.mktmpdir('fgl-server') do |dir|
      @dir = dir
      example.run
    ensure
      @server&.stop
    end
  end

  let(:log) { StringIO.new }
  let(:logger) { Logger.new(log) }
  let(:config) { FglPdf::Config.new }

  def start_server(**opts)
    @server = described_class.new(config: config, out_dir: @dir, host: '127.0.0.1', port: 0, logger: logger,
                                  interpreter_factory: ServerFakes::FakeInterpreter.method(:new), renderer: ServerFakes::FakeRenderer.new,
                                  **opts).start
  end

  def connect = TCPSocket.new('127.0.0.1', @server.port)
  def pdfs = Dir.children(@dir).grep(/\A\d{6}\.pdf\z/).sort
  def index = File.readlines(File.join(@dir, 'index.jsonl')).map { |l| JSON.parse(l) }

  def wait_for(timeout: 5)
    deadline = Time.now + timeout
    sleep 0.02 until yield || Time.now > deadline
    expect(yield).to be_truthy
  end

  it 'binds an ephemeral port when given 0' do
    start_server
    expect(@server.port).to be > 0
    expect(@server).to be_running
  end

  it 'spools tickets from several connections' do
    start_server
    a = connect
    b = connect
    a.write('one<p>tw')
    b.write('three WARN<p>')
    a.write('o<p>')
    a.close
    b.close
    wait_for { pdfs.size == 3 }
    expect(Dir.children(@dir).grep(/\.fgl\z/).size).to eq(3)
    raws = (1..3).map { |n| File.binread(File.join(@dir, format('%06d.fgl', n))) }
    expect(raws).to contain_exactly('one<p>', 'two<p>', 'three WARN<p>')
    expect(index.map { |e| e['connection'] }.uniq.size).to eq(2)
    expect(index.map { |e| e['peer'] }).to all(match(/\A127\.0\.0\.1:\d+\z/))
    wait_for { log.string.include?('(1 warnings) from 127.0.0.1:') }
  end

  it 'writes one file set per copy' do
    start_server
    connect.tap { |s| s.write('x<copies3><p>') }.close
    wait_for { pdfs.size == 3 }
    expect(index.map { |e| e['copy'] }).to eq([1, 2, 3])
  end

  it 'logs and discards data without a print command at EOF' do
    start_server
    connect.tap { |s| s.write('done<p>dangling') }.close
    wait_for { log.string.include?('closed') }
    expect(log.string).to include('discarding 8 bytes without a print command')
    expect(pdfs.size).to eq(1)
  end

  it 'survives a render error, keeping the FGL and an error index line' do
    start_server
    connect.tap { |s| s.write('BOOM<p>') }.close
    wait_for { File.exist?(File.join(@dir, 'index.jsonl')) }
    expect(index.first).to include('file' => '000001.fgl', 'error' => 'ArgumentError: cannot draw')
    expect(File.binread(File.join(@dir, '000001.fgl'))).to eq('BOOM<p>')
    expect(log.string).to include('render failed')

    connect.tap { |s| s.write('fine<p>') }.close
    wait_for { pdfs == ['000002.pdf'] }
  end

  it 'answers status queries only when a status_reply is configured' do
    start_server(status_reply: "\x12")
    sock = connect
    sock.write('<S1>')
    expect(sock.read(1)).to eq("\x12".b)
    sock.close
  end

  it 'stops cleanly and refuses new connections' do
    start_server
    port = @server.port
    open_sock = connect
    @server.stop
    expect(@server).not_to be_running
    expect { TCPSocket.new('127.0.0.1', port) }.to raise_error(SystemCallError)
    open_sock.close
  end

  describe 'with the real interpreter and renderer', :integration do
    before do
      skip 'FglPdf::Interpreter / Renderer::Pdf not loadable yet' unless
        defined?(FglPdf::Interpreter) && defined?(FglPdf::Renderer::Pdf) && defined?(FglPdf::LogoStore)
    end

    def start_real
      @server = described_class.new(config: config, out_dir: @dir, host: '127.0.0.1', port: 0,
                                    logger: logger).start
    end

    it 'spools sample order jobs and resumes numbering after a restart' do
      start_real
      first = connect
      first.write(fixture('logo_download.fgl'))
      first.write(fixture('order_general_admission.fgl'))
      second = connect
      second.write(fixture('order_reserved_seats.fgl'))
      [first, second].each(&:close)
      wait_for(timeout: 30) { pdfs.size == 5 }
      expect(pdfs).to eq((1..5).map { |n| format('%06d.pdf', n) })
      expect(File.binread(File.join(@dir, '000001.pdf'))).to start_with('%PDF')

      @server.stop
      start_real
      connect.tap { |s| s.write(fixture('order_general_admission.fgl')) }.close
      wait_for(timeout: 30) { pdfs.size == 7 }
      expect(pdfs.last(2)).to eq(%w[000006.pdf 000007.pdf])
    end
  end
end
