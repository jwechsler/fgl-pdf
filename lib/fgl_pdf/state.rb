# frozen_string_literal: true

require_relative 'fonts'

module FglPdf
  # Interpreter graphics state. Every print command restores the defaults.
  # Cursor (x, y) and the start of the current line (line_x, line_y) are page dots.
  State = Struct.new(:x, :y, :line_x, :line_y, :font_kind, :font_id, :ttf_id, :ttf_pt,
                     :box_w, :box_h, :hw_w, :hw_h, :sd, :rotation, :inverse, :overwrite,
                     :lt, :bar_height, :bar_width, :bi, :image_format, :line_graphics,
                     keyword_init: true) do
    def self.defaults(config)
      font = Fonts.resident(Fonts::DEFAULT_ID)
      new(x: 0, y: 0, line_x: 0, line_y: 0, font_kind: :resident, font_id: font.id, ttf_id: nil,
          ttf_pt: nil, box_w: font.box_w, box_h: font.box_h, hw_w: 1, hw_h: 1, sd: 1, rotation: :NR,
          inverse: false, overwrite: false, lt: 1, bar_height: 4, bar_width: config.default_bar_width,
          bi: false, image_format: nil, line_graphics: false)
    end

    # Moves the cursor and starts a new line there.
    def move_to(new_x, new_y)
      self.x = self.line_x = new_x
      self.y = self.line_y = new_y
      self.line_graphics = false
    end

    def resident_font
      Fonts.resident(font_id)
    end
  end
end
