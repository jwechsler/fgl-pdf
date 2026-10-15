# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'time'

module FglPdf
  # Output directory of the virtual printer. Every printed copy becomes a numbered file set:
  #
  #   dir/000001.pdf      rendered ticket
  #   dir/000001.fgl      the FGL bytes that produced it (binary, as received)
  #   dir/index.jsonl     one JSON line per copy
  #   dir/.printer/       printer state: seq.lock, counter, logos/
  #
  # Numbering resumes after the highest existing NNNNNN.pdf / NNNNNN.fgl and is safe across
  # threads and processes: allocation, file writes and the index append all happen under an
  # exclusive flock on .printer/seq.lock, and the directory is re-scanned under that lock.
  class Spool
    SEQ_DIGITS = 6
    SEQ_PATTERN = /\A(\d{#{SEQ_DIGITS}})\.(?:pdf|fgl)\z/

    attr_reader :dir

    def initialize(dir)
      @dir = File.expand_path(dir)
      FileUtils.mkdir_p(state_dir)
      FileUtils.mkdir_p(logo_dir)
      @counter = FileCounter.new(File.join(state_dir, 'counter'))
    end

    # Ticket counter shared by every connection (and process) printing into this spool.
    attr_reader :counter

    def state_dir
      File.join(dir, '.printer')
    end

    def logo_dir
      File.join(state_dir, 'logos')
    end

    def index_path
      File.join(dir, 'index.jsonl')
    end

    # Writes one file set per copy of +ticket+ and returns the sequence numbers used.
    # +pdf+ may be nil when rendering failed; pass +error+ to record why. The .fgl file
    # and index line are written either way.
    def write(ticket, pdf, peer: nil, connection: nil, error: nil)
      copies = [Integer(ticket.copies || 1), 1].max
      raw = ticket.raw.to_s.b
      with_lock do
        first = next_seq
        Array.new(copies) do |i|
          seq = first + i
          write_set(seq, pdf, raw)
          meta = { peer: peer, connection: connection, copy: i + 1, copies: copies, error: error }
          append_index(seq, pdf, ticket, **meta)
          seq
        end
      end
    end

    def self.name_for(seq, ext)
      format("%0#{SEQ_DIGITS}d.%s", seq, ext)
    end

    private

    def with_lock(&)
      File.open(File.join(state_dir, 'seq.lock'), File::RDWR | File::CREAT, 0o644) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end

    def next_seq
      max = Dir.children(dir).filter_map { |name| name[SEQ_PATTERN, 1]&.to_i }.max
      (max || 0) + 1
    end

    def write_set(seq, pdf, raw)
      atomic_write(self.class.name_for(seq, 'fgl'), raw)
      atomic_write(self.class.name_for(seq, 'pdf'), pdf.b) if pdf
    end

    # Write to a hidden temp file and rename, so watchers never see a partial PDF.
    def atomic_write(name, data)
      tmp = File.join(dir, ".#{name}.tmp")
      File.binwrite(tmp, data)
      File.rename(tmp, File.join(dir, name))
    end

    def append_index(seq, pdf, ticket, peer:, connection:, copy:, copies:, error:)
      entry = {
        seq: seq,
        file: self.class.name_for(seq, pdf ? 'pdf' : 'fgl'),
        time: Time.now.iso8601,
        peer: peer,
        connection: connection,
        copy: copy,
        copies: copies,
        warnings: Array(ticket.warnings).map(&:to_s)
      }
      entry[:error] = error if error
      File.open(index_path, 'a') { |f| f.write("#{JSON.generate(entry)}\n") }
    end
  end

  # FglPdf::Counter backed by a file, so the ticket counter survives restarts and is shared
  # by every connection and process using the same spool. Each operation takes an flock.
  class FileCounter
    attr_reader :path

    def initialize(path, initial: 1)
      @path = path
      @initial = Integer(initial)
    end

    def value
      locked(File::LOCK_SH) { |f| read(f) }
    end

    def value=(new_value)
      new_value = Integer(new_value)
      locked(File::LOCK_EX) { |f| store(f, new_value) }
    end

    def increment!
      locked(File::LOCK_EX) { |f| store(f, read(f) + 1) }
    end

    # The 7-digit form printed by <PC>.
    def to_s
      format('%07d', value % 10_000_000)
    end

    private

    def locked(mode)
      File.open(path, File::RDWR | File::CREAT, 0o644) do |f|
        f.flock(mode)
        yield f
      end
    end

    def read(file)
      file.rewind
      text = file.read.strip
      text.empty? ? @initial : Integer(text, 10)
    rescue ArgumentError
      @initial
    end

    def store(file, new_value)
      file.rewind
      file.truncate(0)
      file.write("#{new_value}\n")
      file.flush
      new_value
    end
  end
end
