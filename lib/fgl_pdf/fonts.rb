# frozen_string_literal: true

require 'prawn'
require_relative 'config'

module FglPdf
  # Resident Boca font metrics (FGL46/26 Programming Guide, Font Size Supplement), in dots.
  # glyph: the character image; box: the character cell (advance width × line height).
  # OCR-A and OCR-B are drawn with the bundled OCR fonts; the other faces are stand-ins
  # chosen to approximate each Boca bitmap font's look.
  #
  # em: em size of a TrueType face as a multiple of glyph_h, measured against a real Boca
  # print: OCR-A capitals fill glyph_h (cap height 0.78 em), while OCR-B's glyph_h spans the
  # top of the digits to the bottom of the descenders (about 1 em). nil for the stand-ins,
  # whose cap height is scaled to glyph_h.
  module Fonts
    Resident = Struct.new(:id, :name, :glyph_w, :glyph_h, :box_w, :box_h, :face, :em, keyword_init: true)

    OCR_A = File.join(Config::FONT_DIR, 'OCRA.ttf')
    OCR_B = File.join(Config::FONT_DIR, 'OCRB.ttf')
    OCR_A_EM = 1 / 0.78
    OCR_B_EM = 1.0

    RESIDENT = [
      Resident.new(id: 1, name: 'Font1', glyph_w: 5, glyph_h: 7, box_w: 7, box_h: 8, face: 'Helvetica'),
      Resident.new(id: 2, name: 'Font2', glyph_w: 8, glyph_h: 16, box_w: 10, box_h: 18, face: 'Helvetica'),
      Resident.new(id: 3, name: 'OCR-B', glyph_w: 17, glyph_h: 31, box_w: 20, box_h: 33, face: OCR_B, em: OCR_B_EM),
      Resident.new(id: 4, name: 'OCR-A', glyph_w: 5, glyph_h: 9, box_w: 7, box_h: 11, face: OCR_A, em: OCR_A_EM),
      Resident.new(id: 5, name: 'Font5', glyph_w: 5, glyph_h: 11, box_w: 7, box_h: 12, face: 'Helvetica'),
      Resident.new(id: 6, name: 'Large OCR-B', glyph_w: 30, glyph_h: 52, box_w: 34, box_h: 56,
                   face: OCR_B, em: OCR_B_EM),
      Resident.new(id: 7, name: 'OCR-A', glyph_w: 15, glyph_h: 29, box_w: 20, box_h: 31, face: OCR_A, em: OCR_A_EM),
      Resident.new(id: 8, name: 'Courier', glyph_w: 20, glyph_h: 40, box_w: 20, box_h: 33, face: 'Courier'),
      Resident.new(id: 9, name: 'Small OCR-B', glyph_w: 13, glyph_h: 20, box_w: 13, box_h: 22,
                   face: OCR_B, em: OCR_B_EM),
      Resident.new(id: 10, name: 'Prestige', glyph_w: 25, glyph_h: 41, box_w: 28, box_h: 41, face: 'Courier-Bold'),
      Resident.new(id: 11, name: 'Script', glyph_w: 25, glyph_h: 49, box_w: 26, box_h: 49, face: 'Times-Italic'),
      Resident.new(id: 12, name: 'Orator', glyph_w: 46, glyph_h: 91, box_w: 47, box_h: 91, face: 'Courier-Bold'),
      Resident.new(id: 13, name: 'Courier Intl', glyph_w: 20, glyph_h: 40, box_w: 20, box_h: 42, face: 'Courier')
    ].to_h { |f| [f.id, f] }.freeze

    DEFAULT_ID = 3

    # A single measuring document, shared under a lock (the printer server is threaded).
    @metrics_lock = Mutex.new
    @measure_doc = nil

    module_function

    def resident(id)
      RESIDENT[Integer(id)]
    end

    # True when +face+ names a TrueType file rather than a built-in PDF font.
    def ttf_face?(face)
      face.to_s.end_with?('.ttf')
    end

    # Em size as a multiple of glyph_h for a resident TrueType +face+ (see Resident#em).
    def em(face)
      RESIDENT.each_value.find { |f| f.face == face }&.em || 1.0
    end

    # Width in dots of +text+ set in TrueType face +path+ at +size_dots+ (em size in dots).
    def ttf_width(path, text, size_dots)
      with_face(path) { |doc| doc.width_of(text, size: size_dots.to_f) }
    end

    # Ascender/descender as a fraction of em size, independent of size.
    def ttf_em_fractions(path)
      with_face(path) do |doc|
        size = doc.font_size.to_f
        [doc.font.ascender / size, doc.font.descender.abs / size]
      end
    end

    def with_face(path)
      @metrics_lock.synchronize do
        @measure_doc ||= Prawn::Document.new(margin: 0)
        result = nil
        @measure_doc.font(path) { result = yield @measure_doc }
        result
      end
    end
  end
end
