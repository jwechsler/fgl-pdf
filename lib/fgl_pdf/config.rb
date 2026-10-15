# frozen_string_literal: true

require 'logger'

module FglPdf
  # Printer/stock settings shared by the interpreter, renderer and printer server.
  class Config
    FONT_DIR = File.expand_path('../../fonts', __dir__)

    # Boca resident TrueType font ids used with <RTFn,pt>. Ids 3–6 are commonly the
    # Verdana family; DejaVu Sans is the closest freely redistributable substitute.
    DEFAULT_TTF_FILES = {
      1 => 'DejaVuSans.ttf',
      2 => 'DejaVuSans-Bold.ttf',
      3 => 'DejaVuSans.ttf',
      4 => 'DejaVuSans-Bold.ttf',
      5 => 'DejaVuSans-Oblique.ttf',
      6 => 'DejaVuSans-BoldOblique.ttf'
    }.freeze

    attr_accessor :dpi, :width_in, :length_in, :strict, :annotate, :debug_grid, :logger
    attr_reader :ttf_map

    def initialize(dpi: 300, width_in: 2.0, length_in: 5.5, ttf_map: nil, font_dir: nil,
                   strict: false, annotate: false, debug_grid: false, logger: nil)
      @dpi = Integer(dpi)
      @width_in = Float(width_in)
      @length_in = Float(length_in)
      @strict = strict
      @annotate = annotate
      @debug_grid = debug_grid
      @logger = logger || Logger.new(nil)
      @ttf_map = build_ttf_map(font_dir, ttf_map)
    end

    # Builds a config from FGL_PDF_* environment variables, with keyword overrides.
    def self.from_env(env = ENV, **overrides)
      opts = {}
      opts[:dpi] = env['FGL_PDF_DPI'] if env['FGL_PDF_DPI']
      opts[:width_in] = env['FGL_PDF_WIDTH_IN'] if env['FGL_PDF_WIDTH_IN']
      opts[:length_in] = env['FGL_PDF_LENGTH_IN'] if env['FGL_PDF_LENGTH_IN']
      opts[:font_dir] = env['FGL_PDF_FONT_DIR'] if env['FGL_PDF_FONT_DIR']
      opts[:strict] = truthy?(env['FGL_PDF_STRICT']) if env['FGL_PDF_STRICT']
      opts[:annotate] = truthy?(env['FGL_PDF_ANNOTATE']) if env['FGL_PDF_ANNOTATE']
      opts[:debug_grid] = truthy?(env['FGL_PDF_DEBUG_GRID']) if env['FGL_PDF_DEBUG_GRID']
      new(**opts, **overrides.compact)
    end

    def self.truthy?(value)
      %w[1 true yes on].include?(value.to_s.downcase)
    end

    # Dots across the head (FGL rows).
    def width_dots
      (width_in * dpi).round
    end

    # Dots along the feed direction (FGL columns).
    def length_dots
      (length_in * dpi).round
    end

    # PDF points per printer dot.
    def pt_per_dot
      72.0 / dpi
    end

    # Default narrow-bar width for barcodes (FGL guide: X2 at 200 dpi, X3 at 300+).
    def default_bar_width
      dpi >= 300 ? 3 : 2
    end

    # Path of the TrueType face for resident/downloaded TTF id, or nil when unknown.
    def ttf_path(id)
      ttf_map[Integer(id)]
    end

    private

    # A font_dir may contain Verdana-family files that override the DejaVu defaults:
    # verdana.ttf, verdanab.ttf, verdanai.ttf, verdanaz.ttf (Windows names).
    def build_ttf_map(font_dir, explicit)
      map = DEFAULT_TTF_FILES.transform_values { |f| File.join(FONT_DIR, f) }
      if font_dir
        { 3 => 'verdana.ttf', 4 => 'verdanab.ttf', 5 => 'verdanai.ttf', 6 => 'verdanaz.ttf' }.each do |id, file|
          path = Dir.glob(File.join(font_dir, '*')).find { |p| File.basename(p).casecmp?(file) }
          map[id] = path if path
        end
      end
      map.merge!(explicit.transform_keys { |k| Integer(k) }) if explicit
      map
    end
  end
end
