# frozen_string_literal: true

require 'json'
require 'fgl_pdf/spool'

RSpec.describe FglPdf::Spool do
  around do |example|
    Dir.mktmpdir('fgl-spool') do |dir|
      @dir = dir
      example.run
    end
  end

  let(:spool) { FglPdf::Spool.new(@dir) }

  def ticket(raw: '<F3>HI<p>', copies: 1, warnings: [])
    FglPdf::Ticket.new(width_dots: 600, length_dots: 1650, raw: raw.b, copies: copies, warnings: warnings)
  end

  def pdfs = Dir.children(@dir).grep(/\A\d{6}\.pdf\z/).sort
  def index = File.readlines(File.join(@dir, 'index.jsonl')).map { |l| JSON.parse(l) }

  it 'creates the spool and state directories' do
    expect(File.directory?(File.join(spool.dir, '.printer'))).to be true
    expect(spool.logo_dir).to eq(File.join(@dir, '.printer', 'logos'))
    expect(File.directory?(spool.logo_dir)).to be true
  end

  it 'numbers file sets sequentially and keeps the raw FGL' do
    expect(spool.write(ticket(raw: "A\x00\xFF<p>"), '%PDF-a')).to eq([1])
    expect(spool.write(ticket, '%PDF-b')).to eq([2])
    expect(pdfs).to eq(%w[000001.pdf 000002.pdf])
    expect(File.binread(File.join(@dir, '000001.fgl'))).to eq("A\x00\xFF<p>".b)
    expect(File.binread(File.join(@dir, '000002.pdf'))).to eq('%PDF-b')
  end

  it 'resumes numbering after re-instantiation' do
    spool.write(ticket, '%PDF')
    spool.write(ticket, '%PDF')
    expect(FglPdf::Spool.new(@dir).write(ticket, '%PDF')).to eq([3])
  end

  it 'writes one file set and index line per copy' do
    expect(spool.write(ticket(copies: 3), '%PDF')).to eq([1, 2, 3])
    expect(pdfs.size).to eq(3)
    expect(index.map { |e| [e['seq'], e['copy'], e['copies']] }).to eq([[1, 1, 3], [2, 2, 3], [3, 3, 3]])
  end

  it 'appends valid JSON index lines' do
    spool.write(ticket(warnings: ['unknown command <ZZ>']), '%PDF', peer: '10.0.0.2:5000', connection: 7)
    entry = index.first
    expect(entry).to include('seq' => 1, 'file' => '000001.pdf', 'peer' => '10.0.0.2:5000',
                             'connection' => 7, 'copy' => 1, 'copies' => 1,
                             'warnings' => ['unknown command <ZZ>'])
    expect { Time.iso8601(entry['time']) }.not_to raise_error
    expect(entry).not_to have_key('error')
  end

  it 'records failures without a PDF and does not reuse their number' do
    spool.write(ticket, nil, error: 'RuntimeError: boom')
    expect(index.first).to include('file' => '000001.fgl', 'error' => 'RuntimeError: boom')
    expect(pdfs).to be_empty
    expect(FglPdf::Spool.new(@dir).write(ticket, '%PDF')).to eq([2])
  end

  it 'hands out unique, contiguous numbers to concurrent writers' do
    threads = Array.new(8) do |t|
      Thread.new { Array.new(5) { FglPdf::Spool.new(@dir).write(ticket(raw: "t#{t}"), '%PDF') }.flatten }
    end
    seqs = threads.flat_map(&:value)
    expect(seqs.sort).to eq((1..40).to_a)
    expect(pdfs.size).to eq(40)
    expect(index.map { |e| e['seq'] }.sort).to eq((1..40).to_a)
  end

  it 'hands out unique numbers across processes', skip: !Process.respond_to?(:fork) && 'fork unavailable' do
    pids = Array.new(4) { fork { 5.times { FglPdf::Spool.new(@dir).write(ticket, '%PDF') } } }
    pids.each { |pid| Process.wait(pid) }
    expect(pdfs).to eq((1..20).map { |n| format('%06d.pdf', n) })
  end

  describe FglPdf::FileCounter do
    let(:counter) { spool.counter }

    it 'starts at 1 and behaves like FglPdf::Counter' do
      expect(counter.value).to eq(1)
      expect(counter.increment!).to eq(2)
      counter.value = 41
      expect(counter.to_s).to eq('0000041')
    end

    it 'persists across instances' do
      counter.value = 99
      counter.increment!
      expect(described_class.new(File.join(@dir, '.printer', 'counter')).value).to eq(100)
      expect(FglPdf::Spool.new(@dir).counter.value).to eq(100)
    end

    it 'does not lose increments under concurrency' do
      Array.new(8) { Thread.new { 25.times { FglPdf::Spool.new(@dir).counter.increment! } } }.each(&:join)
      expect(counter.value).to eq(201)
    end
  end
end
