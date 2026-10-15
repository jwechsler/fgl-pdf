# frozen_string_literal: true

require 'chunky_png'
require 'fileutils'
require_relative 'bitmap'

module FglPdf
  # Downloaded logos by slot id, shared by all connections (thread-safe). A logo is a
  # Bitmap or a Macro (stored FGL bytes replayed by <LD#>). With +dir+, logos persist as
  # logo_<n>.png / macro_<n>.fgl and are reloaded on start-up, like printer flash memory.
  class LogoStore
    Macro = Struct.new(:bytes)

    FILE_PATTERN = /\A(logo|macro)_(\d+)\.(png|fgl)\z/

    attr_reader :dir

    def initialize(dir: nil)
      @dir = dir
      @logos = {}
      @lock = Mutex.new
      @implicit_id = 1
      return unless dir

      FileUtils.mkdir_p(dir)
      load_dir
    end

    def store(slot, logo)
      slot = Integer(slot)
      raise ArgumentError, "unsupported logo #{logo.class}" unless logo.is_a?(Bitmap) || logo.is_a?(Macro)

      @lock.synchronize do
        @logos[slot] = logo
        persist(slot, logo) if dir
      end
      slot
    end

    def fetch(slot)
      @lock.synchronize { @logos[Integer(slot)] }
    end

    def delete(slot)
      slot = Integer(slot)
      @lock.synchronize do
        remove_files(slot) if dir
        @logos.delete(slot)
      end
    end

    def clear
      @lock.synchronize do
        @logos.each_key { |slot| remove_files(slot) } if dir
        @logos.clear
      end
      self
    end

    def slots
      @lock.synchronize { @logos.keys.sort }
    end

    def size
      @lock.synchronize { @logos.size }
    end

    # Lowest unused slot ≥ 1.
    def next_free_slot
      @lock.synchronize do
        slot = 1
        slot += 1 while @logos.key?(slot)
        slot
      end
    end

    # Slot for a download with no preceding <ID#>. Like a Boca after power-on, this
    # starts at 1 for each new store (it is not persisted) and counts up per download.
    def take_implicit_slot
      @lock.synchronize do
        slot = @implicit_id
        @implicit_id += 1
        slot
      end
    end

    private

    def png_path(slot) = File.join(dir, "logo_#{slot}.png")
    def macro_path(slot) = File.join(dir, "macro_#{slot}.fgl")

    def persist(slot, logo)
      remove_files(slot)
      if logo.is_a?(Bitmap)
        atomic_write(png_path(slot), logo.to_png_blob)
      else
        atomic_write(macro_path(slot), logo.bytes.b)
      end
    end

    def atomic_write(path, data)
      tmp = "#{path}.tmp#{Process.pid}"
      File.binwrite(tmp, data)
      File.rename(tmp, path)
    end

    def remove_files(slot)
      [png_path(slot), macro_path(slot)].each { |p| FileUtils.rm_f(p) }
    end

    def load_dir
      Dir.children(dir).sort.each do |name|
        m = FILE_PATTERN.match(name)
        next unless m && ((m[1] == 'logo') == (m[3] == 'png'))

        path = File.join(dir, name)
        @logos[Integer(m[2], 10)] = m[1] == 'logo' ? load_png(path) : Macro.new(File.binread(path))
      rescue StandardError
        next # unreadable file: skip it rather than refuse to start
      end
    end

    def load_png(path)
      png = ChunkyPNG::Image.from_file(path)
      rows = Array.new(png.height) do |y|
        Array.new(png.width) do |x|
          c = png[x, y]
          ChunkyPNG::Color.a(c) >= 128 &&
            ((0.299 * ChunkyPNG::Color.r(c)) + (0.587 * ChunkyPNG::Color.g(c)) + (0.114 * ChunkyPNG::Color.b(c))) < 128
        end
      end
      Bitmap.new(png.width, png.height, rows)
    end
  end
end
