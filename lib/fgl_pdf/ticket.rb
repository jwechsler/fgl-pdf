# frozen_string_literal: true

require_relative 'geometry'

module FglPdf
  # One printed ticket: a display list of drawables in page dots (see Geometry), plus
  # diagnostics. The interpreter builds these; the renderer only draws them.
  class Ticket
    attr_reader :items, :warnings
    attr_accessor :width_dots, :length_dots, :copies, :raw

    def initialize(width_dots:, length_dots:, items: [], warnings: [], copies: 1, raw: nil)
      @width_dots = width_dots
      @length_dots = length_dots
      @items = items
      @warnings = warnings
      @copies = copies
      @raw = raw
    end

    def <<(item)
      items << item
      self
    end

    def warn(message)
      warnings << message unless warnings.include?(message)
    end

    # Drawables whose bbox extends past the page.
    def off_page_items
      items.select { |i| i.respond_to?(:bbox) && !inside?(i.bbox) }
    end

    def inside?(bbox)
      min_x, min_y, max_x, max_y = bbox
      min_x >= 0 && min_y >= 0 && max_x <= length_dots && max_y <= width_dots
    end
  end

  # Mixin for drawables anchored at the top-left of a rotated local frame.
  module Rotated
    def bbox
      Geometry.bbox(x, y, rotation, length, height)
    end
  end

  # Text run.
  # - font_kind :resident — +face+ is a Prawn built-in font name; each character is drawn
  #   in its own cell: cell origin u = i * cell_w, glyph scaled to glyph_w × glyph_h dots
  #   at the top-left of the cell.
  # - font_kind :ttf — +face+ is a .ttf path; string drawn at em size +size+ dots with the
  #   em-box top at v = 0 (baseline at v = ascender × size). cell_w/glyph_* are unused.
  # +length+ = total advance in dots, +height+ = line height in dots (both precomputed).
  # +inverse+: white text on a black box (padded by +inverse_pad+ dots); +overwrite+: the
  # area is cleared to white before drawing.
  Text = Struct.new(:x, :y, :rotation, :string, :font_kind, :face, :size,
                    :glyph_w, :glyph_h, :cell_w, :length, :height,
                    :inverse, :overwrite, keyword_init: true) do
    include Rotated
  end

  # Axis-aligned filled rectangle in page dots (lines, HX/VX). Not rotated.
  Rect = Struct.new(:x, :y, :w, :h, :overwrite, keyword_init: true) do
    def bbox
      [x, y, x + w, y + h]
    end
  end

  # Box outline (BX): outer rectangle x,y,w,h with stroke +thickness+ growing inward.
  BoxOutline = Struct.new(:x, :y, :w, :h, :thickness, :overwrite, keyword_init: true) do
    def bbox
      [x, y, x + w, y + h]
    end
  end

  # Monochrome image. +bitmap+ is an FglPdf::Bitmap; image column i maps to local u,
  # image row j to local v; each source pixel covers scale_w × scale_h dots.
  Image = Struct.new(:x, :y, :rotation, :bitmap, :scale_w, :scale_h, :overwrite, keyword_init: true) do
    include Rotated

    def length = bitmap.width * scale_w
    def height = bitmap.height * scale_h
  end

  # Linear barcode. +modules+ is a String of '1'/'0' (bar/space) at +module_w+ dots each,
  # drawn along u; bars are +bar_height+ dots along v. +human_text+ (or nil) is printed in
  # Font1 starting 2 dots below the bars, left-aligned.
  Barcode = Struct.new(:x, :y, :rotation, :symbology, :data, :modules, :module_w, :bar_height,
                       :human_text, keyword_init: true) do
    include Rotated

    def length = modules.length * module_w
    def height = bar_height + (human_text ? 10 : 0)
  end

  # 2D matrix code (QR). +matrix+ is an Array of Arrays of booleans (true = dark), drawn
  # with square modules of +module_size+ dots; includes no quiet zone.
  Matrix2D = Struct.new(:x, :y, :rotation, :symbology, :data, :matrix, :module_size, keyword_init: true) do
    include Rotated

    def length = matrix.first.length * module_size
    def height = matrix.length * module_size
  end

  # Outlined box with a small label, for symbologies we cannot render (PDF417, DataMatrix,
  # Aztec, unknown logos).
  Placeholder = Struct.new(:x, :y, :rotation, :length, :height, :label, keyword_init: true) do
    include Rotated
  end
end
