# fgl-pdf

Render **Boca Systems FGL** (Friendly Ghost Language — the command language of Boca
thermal ticket printers) to PDF, in pure Ruby.

It ships three things:

- **`FglPdf`** — a library: FGL bytes in, one PDF per ticket out.
- **`fgl2pdf`** — a command-line converter for captured FGL files.
- **`fgl-printer`** — a *virtual Boca printer*: a TCP server on port 9100 that accepts the
  same bytes a real printer would and spools each ticket to a numbered PDF. Point a
  ticketing system at it to develop and test without paper.

## Install

From git (not yet on rubygems.org):

```ruby
# Gemfile
gem 'fgl_pdf', git: 'https://github.com/jwechsler/fgl-pdf'
```

or build it yourself:

```sh
git clone https://github.com/jwechsler/fgl-pdf && cd fgl-pdf
gem build fgl_pdf.gemspec && gem install ./fgl_pdf-*.gem
```

Requires Ruby ≥ 3.2. Dependencies (prawn, barby, rqrcode, chunky_png) are pure Ruby.

## Library

```ruby
require 'fgl_pdf'

FglPdf.render(File.binread('order.fgl')).each_with_index do |rendered, i|
  File.binwrite(format('ticket-%03d.pdf', i + 1), rendered.pdf)
  rendered.ticket.warnings.each { |w| warn w }
end
```

`FglPdf.render(bytes, config:, logo_store:, counter:)` returns `RenderedTicket(ticket, pdf)`
structs. A ticket is complete at a print command (`<p>`, `<q>`, `<z>`, FF, …); data after
the last print command is discarded, as on a real printer.

For streaming input or more control, use the parts directly:

```ruby
config      = FglPdf::Config.new(dpi: 300, width_in: 2.0, length_in: 5.5)
interpreter = FglPdf::Interpreter.new(config: config, logo_store: FglPdf::LogoStore.new,
                                      counter: FglPdf::Counter.new)
renderer    = FglPdf::Renderer::Pdf.new(config)

tickets = interpreter.feed(chunk)          # call repeatedly; returns completed tickets
pdf     = renderer.render_many(tickets)    # or renderer.render(ticket) per ticket
interpreter.pending?                       # unprinted data still buffered?
```

`LogoStore.new(dir: path)` persists downloaded logos between runs; `Counter` holds the
ticket counter used by `<PC>`/`<TC>`.

## fgl2pdf

```sh
fgl2pdf INPUT.fgl [-o DIR] [--single] [--dpi N] [--width-in IN] [--length-in IN]
                  [--font-dir DIR] [--debug-grid] [--annotate] [--strict]
```

- Writes `BASENAME-001.pdf`, `BASENAME-002.pdf`, … to `DIR` (default: current directory),
  or a single multi-page `BASENAME.pdf` with `--single`. Written paths go to stdout.
- `INPUT` may be `-` to read stdin (basename `stdin`).
- Warnings go to stderr as `BASENAME-001: <warning>`.
- Exit status: 0 on success, 1 if the input contains no complete ticket, 2 on a read error
  or a `--strict` failure, 64 on bad usage.

Each run starts with an empty logo store and counter, so a job that prints a logo must
contain its logo download (concatenate the files: `cat logo.fgl order.fgl | fgl2pdf -`).

## fgl-printer (virtual printer)

```sh
fgl-printer --out ./tickets [--port 9100] [--host 0.0.0.0] [--verbose] [render options]
```

- Every connection gets its own interpreter (fonts, rotation, position never leak between
  clients); downloaded logos and the ticket counter are shared and persisted in
  `OUT/.printer/`, like a real printer's flash memory, so a logo downloaded once (for example
  at application start-up) is available to later jobs and restarts.
- Logs one line per ticket to stdout, e.g. `ticket 000012 (3 warnings) from 172.18.0.5:51234`;
  `--verbose` adds the warnings themselves and status queries.
- Data left without a print command when a connection closes is discarded and logged.
- A ticket that fails to render does not stop the server: its `.fgl` and an index line with
  an `error` field are still written.
- Status queries (`<S1>` etc.) get no reply. (`FglPdf::PrinterServer` accepts a
  `status_reply:` byte string for hosts that wait for one; it is not a byte-accurate Boca
  status.)
- `SIGINT`/`SIGTERM` stop it gracefully (open connections get 2 s to finish).

### Docker

```sh
docker build -t fgl-printer .
docker run --rm -p 9100:9100 -v "$PWD/tickets:/tickets" fgl-printer
```

Pass options as environment variables (`-e FGL_PDF_DPI=203`) or by overriding the command
(`docker run … fgl-printer fgl-printer --out /tickets --verbose`). Point your application's
printer address at the container's host/IP and port 9100.

### Output layout

```
tickets/
├── 000001.pdf        rendered ticket (one file per copy)
├── 000001.fgl        exact bytes that produced it
├── 000002.pdf
├── 000002.fgl
├── index.jsonl       one JSON line per spooled copy
└── .printer/
    ├── seq.lock      numbering lock
    ├── counter       ticket counter (<PC>)
    └── logos/        downloaded logos
```

Numbers are six-digit, sequential, and resume after the highest existing file when the
server restarts. Several servers (or processes) may share one directory: numbering and the
counter are protected with `flock`. An index line looks like:

```json
{"seq":12,"file":"000012.pdf","time":"2025-10-15T14:30:22-05:00","peer":"172.18.0.5:51234",
 "connection":3,"copy":1,"copies":1,"warnings":["<ZZ>: unknown command ignored"]}
```

(`file` is the `.fgl` and an `"error"` key is present when rendering failed.)

## Configuration

| Flag              | Environment          | Default     | Meaning |
|-------------------|----------------------|-------------|---------|
| `--dpi N`         | `FGL_PDF_DPI`        | `300`       | Printer resolution (dots per inch) |
| `--width-in IN`   | `FGL_PDF_WIDTH_IN`   | `2.0`       | Stock width across the print head |
| `--length-in IN`  | `FGL_PDF_LENGTH_IN`  | `5.5`       | Stock length (feed direction) |
| `--font-dir DIR`  | `FGL_PDF_FONT_DIR`   | —           | Verdana overrides for TrueType fonts 3–6: `verdana.ttf`, `verdanab.ttf`, `verdanai.ttf`, `verdanaz.ttf` (case-insensitive) |
| `--strict`        | `FGL_PDF_STRICT`     | off         | Raise on unknown/malformed commands instead of warning |
| `--annotate`      | `FGL_PDF_ANNOTATE`   | off         | Add diagnostics (warnings) to the PDF |
| `--debug-grid`    | `FGL_PDF_DEBUG_GRID` | off         | Overlay a dot-coordinate grid |
| `--port N`        | `FGL_PDF_PORT`       | `9100`      | `fgl-printer` listen port |
| `--host ADDR`     | —                    | `0.0.0.0`   | `fgl-printer` bind address |
| `--out DIR`       | `FGL_PDF_OUT`        | (required)  | `fgl-printer` spool directory |
| `--verbose`       | —                    | off         | `fgl-printer` debug logging |

Boolean variables accept `1`, `true`, `yes`, `on`. Flags override the environment.

Without `--font-dir`, TrueType fonts 1–6 use the bundled DejaVu Sans family (the closest
freely redistributable match to Verdana), so text widths differ slightly from a printer
with Verdana loaded.

## Supported FGL

| Area | Commands |
|------|----------|
| Positioning | `<RCrow,col>`, `<SPcol,row>` |
| Rotation | `<NR>` `<RR>` `<RU>` `<RL>` |
| Resident fonts | `<F1>` … `<F13>`, `<HWh,w>` (height/width multipliers), `<SDn>`, `<BSn>` |
| TrueType | `<RTFn,pt>` resident, `<TTFn,pt>` downloaded ids |
| Justification | `<CTRn>` centre and `<RTJn>` right-justify within n dots; `~…~` fields |
| Effects | `<EI>`/`<DI>` inverse, `<OWE>`/`<OWD>` overwrite |
| Lines & boxes | `<BXr,c>`, `<HXn>`, `<VXn>`, `<LTn>` |
| Logos | ESC-delimited downloads, `<IDn>`, `<LDn>`, `<DF…>` |
| Graphics | BMP, PCX, `<G…>` raw bitmaps |
| Counter | `<PC>` print, `<TCn>` set |
| Barcodes | common linear symbologies with human-readable text; QR |
| Placeholders | PDF417, DataMatrix, Aztec (outlined box + label, with a warning) |
| Job control | `<p>` `<q>` `<z>` `<h>` `<r>`, `<REn>` copies, `<CB>`, `<PL>`, FF |

Anything else is ignored with a warning (or raises with `--strict`).

## Fidelity notes

The goal is **faithful output plus warnings**: what we cannot reproduce exactly is drawn as
closely as possible and reported, never silently dropped.

- **Coordinates.** FGL addresses dots on the ticket as printed: `x` is the column along
  the ticket length (feed direction), `y` the row across the head. The PDF page is
  landscape, `length_in × width_in`, so it reads like the physical ticket.
- **Assumptions** where the Boca documentation is ambiguous:
  - TrueType text is anchored at the top of the em box at the current position.
  - A QR module is `pt` dots square (the point-size argument is the module size).
  - A BMP downloaded without a preceding `<IDn>` goes to the next free logo slot from 1.
  - Fractional arguments (e.g. `<RC10,230.0>`) are rounded to whole dots.

## License

GPL-3.0-or-later (see `LICENSE`). The bundled DejaVu fonts are under the DejaVu/Bitstream
Vera license (`fonts/DejaVu-LICENSE`).

## Development

```sh
bundle install        # or install the gems from Gemfile system-wide
rspec                 # specs; :integration examples need the full pipeline
rubocop
```

Test fixtures in `spec/fixtures/` are sample jobs: a logo download (a synthetic 1-bit BMP)
and ticket-plus-receipt orders for general admission, reserved seating and a reprint.
