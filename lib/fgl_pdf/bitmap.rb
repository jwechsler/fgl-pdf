# frozen_string_literal: true

require 'chunky_png'

module FglPdf
  # 1-bit image, row-major, true = black (printed dot).
  class Bitmap
    attr_reader :width, :height, :rows

    def initialize(width, height, rows = nil)
      @width = width
      @height = height
      @rows = rows || Array.new(height) { Array.new(width, false) }
    end

    def [](x, y)
      rows[y][x]
    end

    def []=(x, y, value)
      rows[y][x] = value
    end

    # Opaque black on transparent, for placing over the ticket.
    def to_png_blob
      png = ChunkyPNG::Image.new(width, height, ChunkyPNG::Color::TRANSPARENT)
      rows.each_with_index do |row, y|
        row.each_with_index { |on, x| png[x, y] = ChunkyPNG::Color::BLACK if on }
      end
      png.to_blob(:fast_rgba)
    end
  end
end
