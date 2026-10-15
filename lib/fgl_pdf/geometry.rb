# frozen_string_literal: true

module FglPdf
  # Page coordinates are printer dots: x = FGL column (along the feed / ticket length),
  # y = FGL row (across the head), origin top-left, y grows downward.
  #
  # Every rotated drawable has a local frame: u runs along the text "advance" direction and
  # v runs "down" (glyph height, next line). The FGL guide: "facing in the direction of
  # rotation, all characters build down and to the right of their starting points".
  module Geometry
    FRAMES = {
      NR: { advance: [1, 0], down: [0, 1] },
      RR: { advance: [0, 1], down: [-1, 0] },
      RU: { advance: [-1, 0], down: [0, -1] },
      RL: { advance: [0, -1], down: [1, 0] }
    }.freeze

    ROTATIONS = FRAMES.keys.freeze

    # Clockwise rotation in degrees as seen on the printed ticket.
    DEGREES = { NR: 0, RR: 90, RU: 180, RL: 270 }.freeze

    module_function

    def advance(rotation)
      FRAMES.fetch(rotation)[:advance]
    end

    def down(rotation)
      FRAMES.fetch(rotation)[:down]
    end

    # Maps a local (u, v) offset from anchor (x, y) into page dots.
    def to_page(x, y, rotation, u, v)
      ax, ay = advance(rotation)
      dx, dy = down(rotation)
      [x + (u * ax) + (v * dx), y + (u * ay) + (v * dy)]
    end

    # Axis-aligned page bbox [min_x, min_y, max_x, max_y] of a local u×v rectangle.
    def bbox(x, y, rotation, length, height)
      corners = [[0, 0], [length, 0], [0, height], [length, height]].map do |u, v|
        to_page(x, y, rotation, u, v)
      end
      xs = corners.map(&:first)
      ys = corners.map(&:last)
      [xs.min, ys.min, xs.max, ys.max]
    end
  end
end
